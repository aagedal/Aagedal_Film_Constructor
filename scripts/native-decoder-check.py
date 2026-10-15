#!/usr/bin/env python3
"""Reproduce direct C decoder correctness/rejection checks under ASan and UBSan.

Requires explicit FFmpeg/pkg-config executables, an existing barcode render-plan
fixture, a local C compiler and FFmpeg development libraries. The generated ALAC
matrix covers only 16/24-bit mono/stereo at 44.1/48 kHz. No installation,
network access, helper copying or app distribution is performed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import struct
import subprocess
import wave


def digest(path):
    hasher = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            hasher.update(block)
    return hasher.hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ffmpeg', type=Path)
    parser.add_argument('pkg_config', type=Path)
    parser.add_argument('fixture', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--clang', type=Path, default=Path('/usr/bin/clang'))
    args = parser.parse_args()
    for executable in (args.ffmpeg, args.pkg_config, args.clang):
        if not executable.is_absolute() or not os.access(executable, os.X_OK):
            parser.error('Supply absolute executable paths for FFmpeg, pkg-config and clang')
    if not args.fixture.is_absolute() or not (args.fixture / 'result.json').is_file():
        parser.error('Fixture must be an absolute existing render-plan proof directory')
    fixture_result = json.loads((args.fixture / 'result.json').read_text())
    if (fixture_result.get('decodedVideoFrames'), fixture_result.get('audioSamplesPerChannel'),
        fixture_result.get('frameRate'), fixture_result.get('audioActiveSamples')) != (
            180, 288288, '30000/1001', [48048, 240240]):
        parser.error('Fixture must be the completed 180-frame barcode render-plan proof')
    source = args.fixture / 'a.mov'
    if not source.is_file():
        parser.error('Fixture must include its original a.mov barcode/multistream source')
    if not args.output.is_absolute() or args.output.exists():
        parser.error('Output must be a new absolute directory')
    args.output.mkdir(parents=True)
    root = args.output
    repo = Path(__file__).resolve().parent.parent
    bridge = repo / 'Packages/NativePlaybackProof/Sources/CNativeDecoder'
    commands = []
    result = {'passed': False, 'sanitizers': ['address', 'undefined'], 'limitations': [
        'Development local dylibs; no bundled/signed shipping dependency qualification',
        'Direct decoded frames/samples, not live display/CoreAudio synchronization or latency',
        'A finite fixture/rejection matrix does not qualify arbitrary media or malformed files',
        'ALAC admission is limited to 16/24-bit mono/stereo at 44100/48000 Hz, zero-origin contiguous samples, and no delay/padding'
    ]}
    env = os.environ.copy()
    env['ASAN_OPTIONS'] = 'halt_on_error=1'
    env['UBSAN_OPTIONS'] = 'halt_on_error=1:print_stacktrace=1'

    def run(command, log, capture=False, timeout=300):
        command = [str(item) for item in command]
        commands.append(command)
        if capture:
            completed = subprocess.run(command, env=env, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, timeout=timeout, check=False)
            (root / log).write_bytes(completed.stdout + completed.stderr)
            completed.check_returncode()
            return completed.stdout.decode().strip()
        with (root / log).open('wb') as stream:
            subprocess.run(command, env=env, stdout=stream, stderr=subprocess.STDOUT,
                timeout=timeout, check=True)

    def ff(arguments, log):
        run([args.ffmpeg, '-hide_banner', '-nostdin', '-n', *arguments], log)

    try:
        identities = {}
        for name, executable, flag in [('ffmpeg', args.ffmpeg, '-version'),
                                      ('pkgConfig', args.pkg_config, '--version'),
                                      ('clang', args.clang, '--version')]:
            identities[name] = {'path': str(executable), 'sha256': digest(executable),
                'version': run([executable, flag], name + '-version.txt', capture=True)}
        libraries = ['libavformat', 'libavcodec', 'libavutil', 'libswscale', 'libswresample']
        result['libraryVersions'] = run([args.pkg_config, '--modversion', *libraries],
            'library-versions.txt', capture=True).splitlines()
        cflags = shlex.split(run([args.pkg_config, '--cflags', *libraries], 'cflags.txt', capture=True))
        ldflags = shlex.split(run([args.pkg_config, '--libs', *libraries], 'ldflags.txt', capture=True))
        for library in libraries:
            libdir = Path(run([args.pkg_config, '--variable=libdir', library],
                library + '-libdir.txt', capture=True))
            dylib = libdir / (library + '.dylib')
            identities[library] = {'path': str(dylib.resolve()), 'sha256': digest(dylib)}
        write_json(root / 'identities.json', identities)
        source_files = [repo / 'scripts/native-decoder-check.py', repo / 'scripts/native-decoder-check.c',
                        bridge / 'NativeDecoder.c', bridge / 'include/CNativeDecoder.h']
        write_json(root / 'source-manifest.json', {
            str(path.relative_to(repo)): digest(path) for path in source_files})
        write_json(root / 'fixture-identities.json', {
            str(path): digest(path) for path in [source, args.fixture / 'project.json',
                args.fixture / 'command.json', args.fixture / 'result.json']})
        run(['git', '-C', repo, 'status', '--short'], 'git-status.txt')

        # Produce independent references using the explicitly supplied helper.
        ff(['-i', source, '-map', '0:0', '-fps_mode', 'passthrough', '-pix_fmt', 'rgb24',
            '-f', 'rawvideo', root / 'reference.rgb'], 'reference-video.log')
        ff(['-i', source, '-map', '0:2', '-f', 'f32le', root / 'reference.f32'], 'reference-audio.log')
        rgb = (root / 'reference.rgb').read_bytes()
        frame_bytes = 160 * 90 * 3
        assert len(rgb) == 300 * frame_bytes, 'Source reference must contain exactly 300 frames'
        assert (root / 'reference.f32').stat().st_size == 480480 * 4, 'PCM reference sample count'
        barcode_errors = []
        for frame in range(300):
            row = b''.join(bytes([32 + 192 * ((frame >> bit) & 1)]) * (16 * 3) for bit in range(10))
            expected = row * 90
            actual = rgb[frame * frame_bytes:(frame + 1) * frame_bytes]
            mean_error = sum(abs(a - b) for a, b in zip(actual, expected)) / frame_bytes
            assert mean_error < 4, (frame, 'Barcode source identity mismatch', mean_error)
            barcode_errors.append(mean_error)
        result['sourceBarcodeFrames'] = 300
        result['sourceBarcodeMaximumMeanRGBError'] = max(barcode_errors)

        controls = {
            'plain.mov': ['-f', 'lavfi', '-i', 'testsrc=size=32x24:rate=25:duration=0.4', '-c:v', 'qtrle'],
            'vfr.mov': ['-f', 'lavfi', '-i', 'testsrc=size=32x24:rate=25:duration=0.4',
                '-vf', 'select=not(eq(n\\,4))', '-fps_mode', 'passthrough', '-c:v', 'qtrle'],
            'offset.mov': ['-f', 'lavfi', '-i', 'testsrc=size=32x24:rate=25:duration=0.4',
                '-c:v', 'qtrle', '-output_ts_offset', '1'],
            'sar.mov': ['-f', 'lavfi', '-i', 'testsrc=size=32x24:rate=25:duration=0.4',
                '-vf', 'setsar=2', '-c:v', 'qtrle'],
            'aac.m4a': ['-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=0.4', '-c:a', 'aac'],
            'mp3.mp3': ['-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=0.4', '-c:a', 'libmp3lame', '-write_xing', '0'],
            'alac-rate.m4a': ['-f', 'lavfi', '-i', 'anullsrc=r=32000:cl=mono', '-t', '0.4', '-c:a', 'alac'],
            'alac-channels.m4a': ['-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=quad', '-t', '0.4', '-c:a', 'alac'],
            'pcm.wav': ['-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=0.4', '-c:a', 'pcm_s16le'],
            'audio-gap.nut': ['-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=0.1',
                '-af', 'aselect=not(eq(n\\,1))', '-c:a', 'pcm_s16le', '-f', 'nut'],
            'raw.h264': ['-f', 'lavfi', '-i', 'testsrc2=size=32x24:rate=25:duration=0.4',
                '-c:v', 'libx264', '-bf', '2', '-f', 'h264'],
        }
        for name, arguments in controls.items():
            ff([*arguments, root / name], name + '.log')
        ff(['-display_rotation', '90', '-i', root / 'plain.mov', '-c', 'copy',
            root / 'rotation.mov'], 'rotation.log')
        # Every channel has a distinct exact PCM pattern, including EOF samples.
        with wave.open(str(root / 'four-channel.wav'), 'wb') as output:
            output.setparams((4, 2, 48000, 512, 'NONE', 'not compressed'))
            output.writeframes(b''.join(struct.pack('<4h', *[
                ((sample * (channel + 1) * 257 + channel * 7919) % 65536) - 32768
                for channel in range(4)]) for sample in range(512)))

        # Every decoded ALAC sample is checked against independent mathematical
        # source data, including distinct stereo channels and the partial EOF packet.
        matrix = []
        for rate in (44100, 48000):
            for channels in (1, 2):
                for bits in (16, 24):
                    stem = f'alac-{rate}-{channels}-{bits}'
                    wav_path = root / (stem + '.wav')
                    alac_path = root / (stem + '.m4a')
                    values = [
                        ((sample * (channel + 1) * (257 if bits == 16 else 65537) +
                          channel * (7919 if bits == 16 else 1789123)) % (1 << bits)) - (1 << (bits - 1))
                        for sample in range(20037) for channel in range(channels)
                    ]
                    with wave.open(str(wav_path), 'wb') as output:
                        output.setparams((channels, bits // 8, rate, 20037, 'NONE', 'not compressed'))
                        output.writeframes(b''.join(value.to_bytes(bits // 8, 'little', signed=True) for value in values))
                    ff(['-i', wav_path, '-c:a', 'alac', alac_path], stem + '-encode.log')
                    reference = root / (stem + '.f32')
                    ff(['-i', alac_path, '-f', 'f32le', reference], stem + '-reference.log')
                    expected = b''.join(struct.pack('<f', value / float(1 << (bits - 1))) for value in values)
                    assert reference.read_bytes() == expected, (stem, 'ALAC whole-file lossless sample identity')
                    packet_log = stem + '-packets.log'
                    packet_text = run([args.ffmpeg, '-hide_banner', '-nostdin', '-i', alac_path,
                        '-map', '0:a:0', '-c:a', 'copy', '-f', 'framecrc', '-'], packet_log, capture=True)
                    packets = [[int(field.strip()) for field in line.split(',')[:4]]
                        for line in packet_text.splitlines() if line and not line.startswith('#')]
                    assert f'#tb 0: 1/{rate}' in packet_text
                    assert [(packet[1], packet[2], packet[3]) for packet in packets] == [
                        (sample, sample, min(4096, 20037 - sample)) for sample in range(0, 20037, 4096)
                    ], (stem, 'ALAC fixture packet boundaries changed', packets)
                    matrix.append({'rate': rate, 'channels': channels, 'bits': bits,
                        'samplesPerChannel': 20037, 'packetStarts': [packet[2] for packet in packets],
                        'wholeFileLosslessIdentity': True, 'sourceSHA256': digest(wav_path),
                        'alacSHA256': digest(alac_path), 'floatSHA256': digest(reference)})
        result['qualifiedAlacMatrix'] = matrix
        ff(['-i', root / 'alac-48000-1-16.m4a', '-c:a', 'copy', '-output_ts_offset', '1',
            root / 'alac-offset.m4a'], 'alac-offset.log')
        ff(['-i', root / 'alac-48000-1-16.wav',
            '-af', 'asetnsamples=n=4096:p=0,aselect=not(eq(n\\,2))', '-c:a', 'alac',
            root / 'alac-gap.m4a'], 'alac-gap.log')

        executable = root / 'native-decoder-check'
        run([args.clang, '-std=c11', '-Wall', '-Wextra', '-Werror', '-g',
            '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
            '-I' + str(bridge / 'include'), *cflags,
            repo / 'scripts/native-decoder-check.c', bridge / 'NativeDecoder.c',
            *ldflags, '-o', executable], 'build.log')
        identities['checkExecutable'] = {'path': str(executable), 'sha256': digest(executable)}
        write_json(root / 'identities.json', identities)
        check_result = json.loads(run([executable, source, root / 'reference.rgb',
            root / 'reference.f32', root], 'checks.log', capture=True))
        assert check_result['passed'] is True
        assert check_result['checkCount'] == len(check_result['checks'])
        assert all(check['passed'] is True for check in check_result['checks'])
        assert sum('rejection' in check for check in check_result['checks']) >= 20
        result.update(check_result)
        write_json(root / 'artifact-identities.json', {
            str(path.relative_to(root)): digest(path)
            for path in sorted(root.iterdir()) if path.suffix in ('.mov', '.m4a', '.mp3', '.nut', '.h264', '.wav', '.rgb', '.f32')})
    except Exception as error:
        result['passed'] = False
        result['failure'] = f'{type(error).__name__}: {error}'
        raise
    finally:
        write_json(root / 'commands.json', commands)
        write_json(root / 'result.json', result)
        print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
