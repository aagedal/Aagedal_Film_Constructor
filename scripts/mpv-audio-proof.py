#!/usr/bin/env python3
"""Offline MPV decoded-audio proof using explicit cached MPVKit dependencies.

PCM file output qualifies decoded samples, not CoreAudio, clocks or app playback.
Exact sample counts and fixed errors are required; no offset fitting or padding.
"""
import argparse
import array
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import random
import struct
import subprocess
import sys

spec = importlib.util.spec_from_file_location('source', Path(__file__).with_name('mpv-source-proof.py'))
source = importlib.util.module_from_spec(spec)
spec.loader.exec_module(source)

MEAN_LIMIT = 1e-6
PEAK_LIMIT = 1e-5


def compare_audio(actual, expected, channels):
    if channels not in (1, 2) or not expected or len(expected) % (4 * channels):
        raise ValueError('Reference is not complete mono/stereo float32 audio')
    if not actual or len(actual) % (4 * channels):
        raise ValueError('Capture is not complete mono/stereo float32 audio')
    result = {'actualSamplesPerChannel': len(actual) // (4 * channels),
              'expectedSamplesPerChannel': len(expected) // (4 * channels),
              'passed': False}
    if len(actual) != len(expected):
        result['error'] = 'Exact sample count differs'
        return result
    a, b = array.array('f'), array.array('f')
    a.frombytes(actual)
    b.frombytes(expected)
    if sys.byteorder != 'little':
        a.byteswap()
        b.byteswap()
    if not all(math.isfinite(v) for v in a) or not all(math.isfinite(v) for v in b):
        raise ValueError('Nonfinite audio sample')
    errors = [abs(x - y) for x, y in zip(a, b)]
    peak_index = errors.index(max(errors))
    means = [sum(errors[c::channels]) / (len(errors) // channels) for c in range(channels)]
    result.update({'channelMeanErrors': means, 'maximumError': max(errors),
                   'peakSample': peak_index // channels, 'peakChannel': peak_index % channels,
                   'passed': max(means) <= MEAN_LIMIT and max(errors) <= PEAK_LIMIT})
    return result


def write_pattern(path, rate, channels, stream):
    """Independent deterministic channels; nonperiodic content exposes wrong cuts."""
    rng = random.Random(2718 + stream)
    with path.open('wb') as output:
        for sample in range(rate * 3):
            for channel in range(channels):
                value = rng.randrange(-6000, 6001) + ((sample * (17 + channel * 12 + stream * 4)) % 4001 - 2000)
                output.write(struct.pack('<h', value))


def run_proof(args):
    root = args.output
    root.mkdir(parents=True)
    result = {'passed': False, 'decodedAudioTested': False, 'coreAudioTested': False,
              'applicationIntegrated': False, 'commands': [], 'cases': [], 'rejections': [],
              'meanAmplitudeTolerance': MEAN_LIMIT, 'peakAmplitudeTolerance': PEAK_LIMIT,
              'comparisonPolicy': 'Exact interleaved sample count, per-channel mean and all-sample peak; no alignment, padding or edge masking',
              'limitations': ['Offline PCM sink; no CoreAudio or hardware synchronization',
                              'Natural playback and start/end loading ranges, not asynchronous in-place seeks or proxy composition',
                              'Generated same-rate mono/stereo subset; no resampling or distribution qualification']}

    def run(command, name, timeout=180, allow_failure=False):
        command = list(map(str, command))
        result['commands'].append({'name': name, 'argv': command})
        try:
            completed = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
        except subprocess.TimeoutExpired as error:
            (root / (name + '.log')).write_bytes((error.stdout or b'') + (error.stderr or b''))
            raise
        (root / (name + '.log')).write_bytes(completed.stdout + completed.stderr)
        if not allow_failure:
            completed.check_returncode()
        return completed

    try:
        result['candidate'] = source.pinned_checkout(args.checkout)
        architecture = platform.machine()
        frameworks = [source.framework_slice(args.artifacts / name, architecture) for name in source.ARTIFACTS]
        result['frameworks'] = [{'artifact': name, 'binary': str(binary), 'sha256': source.digest(binary)}
                                for name, (_, binary) in zip(source.ARTIFACTS, frameworks)]
        snapshot = root / 'sources'
        snapshot.mkdir()
        for name in ('mpv-audio-proof.c', 'mpv-audio-proof.py', 'mpv-source-proof.py'):
            (snapshot / name).write_bytes(Path(__file__).with_name(name).read_bytes())
        result['sourceHashes'] = {p.name: source.digest(p) for p in snapshot.iterdir()}
        swiftc = Path(run(['/usr/bin/xcrun', '--find', 'swiftc'], 'swiftc-path').stdout.decode().strip())
        executable = root / 'mpv-audio-proof'
        command = ['/usr/bin/clang', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2',
                   '-arch', architecture, '-mmacosx-version-min=27.0',
                   '-L', swiftc.parent.parent / 'lib/swift/macosx',
                   '-I', frameworks[0][0] / 'Headers', snapshot / 'mpv-audio-proof.c']
        if args.sanitize_address:
            command.extend(['-fsanitize=address', '-fno-omit-frame-pointer'])
        command.extend(binary for _, binary in frameworks)
        for name in source.FRAMEWORKS:
            command.extend(['-framework', name])
        command.extend('-l' + name for name in source.LIBRARIES)
        command.extend(['-o', executable])
        run(command, 'compile')
        result['addressSanitizer'] = args.sanitize_address
        result['executableSHA256'] = source.digest(executable)
        result['ffmpegSHA256'] = source.digest(args.ffmpeg)
        run([args.ffmpeg, '-version'], 'ffmpeg-version')
        run(['/usr/bin/otool', '-L', executable], 'linked-libraries')
        for rate, channels in ((44100, 1), (48000, 2)):
            patterns = [root / f'pattern-{rate}-{stream}.s16' for stream in range(2)]
            for stream, path in enumerate(patterns):
                write_pattern(path, rate, channels, stream)
            for codec, container in (('pcm_s16le', 'mov'), ('alac', 'mov'), ('aac', 'mov'), ('libmp3lame', 'mkv')):
                name = f'{codec}-{rate}-{channels}'
                fixture = root / f'{name}.{container}'
                command = [args.ffmpeg, '-v', 'error', '-nostdin', '-n', '-f', 'lavfi', '-i',
                           'color=black:size=16x16:rate=24:duration=3']
                for path in patterns:
                    command.extend(['-f', 's16le', '-ar', str(rate), '-ac', str(channels), '-i', path])
                # Deliberately put audio before video; ff-index 2 must resolve to
                # MPV audio ID 2, rather than treating container index as ID.
                command.extend(['-map', '1:a', '-map', '0:v', '-map', '2:a',
                                '-c:v', 'libx264', '-c:a', codec, fixture])
                run(command, 'generate-' + name)
                for rejected_index in (1, 99):
                    reject_name = f'reject-{name}-{rejected_index}'
                    reject_output = root / (reject_name + '.f32')
                    completed = run([executable, fixture, rejected_index, reject_output,
                                     'natural', '3', rate], reject_name, timeout=25, allow_failure=True)
                    rejected = (completed.returncode == 3
                                and json.loads(completed.stdout) == {'rejected': True, 'ffIndex': rejected_index}
                                and (not reject_output.exists() or reject_output.stat().st_size == 0))
                    result['rejections'].append({'name': reject_name, 'ffIndex': rejected_index, 'passed': rejected})
                    if not rejected:
                        raise ValueError('Missing or wrong-kind audio stream was not rejected before output')
                for stream, ff_index in enumerate((0, 2)):
                    reference = root / f'{name}-stream-{stream}.f32'
                    run([args.ffmpeg, '-v', 'error', '-nostdin', '-n', '-i', fixture,
                         '-map', f'0:{ff_index}', '-c:a', 'pcm_f32le', '-f', 'f32le', reference],
                        f'decode-{name}-{stream}')
                    reference_bytes = reference.read_bytes()
                    for label, start, count in (('natural', 0, len(reference_bytes) // (channels * 4)),
                                                ('whole', 0, rate * 3), ('sample-1023', 1023, 4097),
                                                ('sample-1024', 1024, 4097),
                                                ('sample-1025', 1025, 4097), ('tail', rate * 3 - 4097, 4097)):
                        case_name = f'{name}-{stream}-{label}'
                        output = root / (case_name + '.f32')
                        completed = run([executable, fixture, ff_index, output,
                                         'natural' if label == 'natural' else format(start / rate, '.17g'),
                                         format((start + count) / rate, '.17g'), rate],
                                        case_name, timeout=25, allow_failure=True)
                        case = {'name': case_name, 'codec': codec, 'rate': rate, 'channels': channels,
                                'ffIndex': ff_index, 'startSample': start, 'requestedSamples': count,
                                'fixtureSHA256': source.digest(fixture), 'passed': False}
                        if completed.returncode:
                            case['error'] = 'MPV client failed; see log'
                        else:
                            case['selection'] = json.loads(completed.stdout)
                            if case['selection'].get('passed') is not True or case['selection'].get('ffIndex') != ff_index or case['selection'].get('audioTrackID') != stream + 1:
                                raise ValueError('Runtime track identity did not match requested audio stream')
                            expected = reference_bytes[start * channels * 4:(start + count) * channels * 4]
                            if len(expected) != count * channels * 4:
                                raise ValueError('Reference does not cover requested nominal source range')
                            case.update(compare_audio(output.read_bytes(), expected, channels))
                        result['cases'].append(case)
                        result['decodedAudioTested'] = True
        result['summary'] = {codec: {'passed': sum(c['passed'] for c in result['cases'] if c['codec'] == codec),
                                     'total': sum(c['codec'] == codec for c in result['cases'])}
                             for codec in ('pcm_s16le', 'alac', 'aac', 'libmp3lame')}
        result['passed'] = (len(result['cases']) == 96 and all(c['passed'] for c in result['cases'])
                            and len(result['rejections']) == 16 and all(c['passed'] for c in result['rejections']))
        if not result['passed']:
            result['error'] = 'One or more decoded-audio cases failed; inspect per-case evidence'
    except Exception as error:
        result['error'] = str(error)
    finally:
        (root / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'passed': result['passed'], 'cases': len(result['cases']),
                      'result': str(root / 'result.json'), 'error': result.get('error')}))
    return 0 if result['passed'] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sanitize-address', action='store_true')
    for name in ('checkout', 'artifacts', 'ffmpeg', 'output'):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    for name in ('checkout', 'artifacts', 'ffmpeg', 'output'):
        if not getattr(args, name).is_absolute():
            parser.error(name + ' must be absolute')
    if not os.access(args.ffmpeg, os.X_OK) or args.output.exists():
        parser.error('ffmpeg must be executable and output must not exist')
    return run_proof(args)


if __name__ == '__main__':
    sys.exit(main())
