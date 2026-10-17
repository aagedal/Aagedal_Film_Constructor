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
import re
import struct
import subprocess
import sys

spec = importlib.util.spec_from_file_location('source', Path(__file__).with_name('mpv-source-proof.py'))
source = importlib.util.module_from_spec(spec)
spec.loader.exec_module(source)

MEAN_LIMIT = 1e-6
PEAK_LIMIT = 1e-5


def validate_mp3_remux(original, remuxed, rate, channels):
    """Require identical ordered packets; timing/skip metadata may change on remux."""
    evidence = []
    for index, kind in ((0, 'audio'), (1, 'video'), (2, 'audio')):
        streams = []
        packets = []
        for probe in (original, remuxed):
            matches = [s for s in probe['streams'] if s['index'] == index]
            if len(matches) != 1 or matches[0]['codec_type'] != kind:
                raise ValueError('Remux changed stream identity')
            stream = matches[0]
            if kind == 'audio' and (stream.get('codec_name') != 'mp3'
                    or stream.get('sample_rate') != str(rate) or stream.get('channels') != channels):
                raise ValueError('Remux changed MP3 audio format')
            selected = [p for p in probe['packets'] if p['stream_index'] == index]
            if not selected or any(not re.fullmatch(r'SHA256:[0-9a-f]{64}', p.get('data_hash', ''))
                                   or int(p.get('size', 0)) <= 0 for p in selected):
                raise ValueError('Missing packet payload identity')
            streams.append(stream)
            packets.append(selected)
        identities = [[(p['size'], p['data_hash']) for p in group] for group in packets]
        if identities[0] != identities[1]:
            raise ValueError('Remux changed ordered packet payloads')
        evidence.append({'ffIndex': index, 'kind': kind, 'packetCount': len(packets[0]),
                         'orderedPayloadsIdentical': True,
                         'originalTimeBase': streams[0]['time_base'],
                         'remuxedTimeBase': streams[1]['time_base'],
                         'originalFirstPacket': packets[0][0], 'originalLastPacket': packets[0][-1],
                         'remuxedFirstPacket': packets[1][0], 'remuxedLastPacket': packets[1][-1]})
    if len(original['streams']) != 3 or len(remuxed['streams']) != 3:
        raise ValueError('Remux changed stream count')
    return evidence


def audio_encoder_arguments(codec, aac_pns):
    """Vary fixture encoding only; non-AAC media and default commands stay intact."""
    if aac_pns not in ('default', 'on', 'off'):
        raise ValueError('Unknown AAC PNS fixture control')
    arguments = ['-c:a', codec]
    if codec == 'aac' and aac_pns != 'default':
        arguments.extend(['-aac_pns', '1' if aac_pns == 'on' else '0'])
    return arguments


def selected_decoder(log, requested='auto'):
    """A forced decoder must actually open; silent fallback is not evidence."""
    names = re.findall(r'\[ad/v\] Selected decoder: ([A-Za-z0-9_]+) - ', log)
    if len(names) != 1 or (requested != 'auto' and names[0] != requested):
        raise ValueError('Missing, ambiguous or unexpected selected audio decoder')
    return names[0]


def validate_embedded_metadata(metadata, data, index, rate, channels, mode):
    """A successful control must identify the requested stream and exact output."""
    if mode not in ('unseeked', 'seek-zero', 'seek-first-packet', 'seek-first-packet-duration'):
        raise ValueError('Unknown embedded reference control')
    if (metadata.get('passed') is not True or metadata.get('decoder') != 'aac'
            or metadata.get('seekZero') is not (mode == 'seek-zero')
            or metadata.get('seekFirstPacket') is not (mode in ('seek-first-packet', 'seek-first-packet-duration'))
            or metadata.get('useFrameDuration') is not (mode == 'seek-first-packet-duration')
            or metadata.get('ffIndex') != index or metadata.get('sampleRate') != rate
            or metadata.get('channels') != channels
            or type(metadata.get('samplesPerChannel')) is not int
            or metadata['samplesPerChannel'] <= 0
            or metadata['samplesPerChannel'] * channels * 4 != len(data)):
        raise ValueError('Embedded reference metadata does not match requested stream/output/control')
    if mode in ('seek-first-packet', 'seek-first-packet-duration') and (
            type(metadata.get('seekTarget')) is not int
            or metadata['seekTarget'] != metadata.get('firstPacketPTS')):
        raise ValueError('First-packet seek did not return the observed target timestamp')


def validate_seek_offset(observed, requested):
    # MPV stores this option as a C float, while property readback uses double.
    expected = struct.unpack('f', struct.pack('f', requested))[0]
    if (type(observed) not in (int, float) or not math.isfinite(observed)
            or observed != expected):
        raise ValueError('Runtime seek offset does not match the requested float option')


def range_arguments(label, start, count, rate, mode):
    """Only change runtime trimming; reference and capture comparisons stay exact."""
    if mode not in ('timestamp', 'sample-filter', 'pts-filter') or start < 0 or count <= 0 or rate <= 0:
        raise ValueError('Invalid range strategy or sample coordinates')
    if label == 'natural':
        return ['natural', format((start + count) / rate, '.17g')]
    if mode in ('sample-filter', 'pts-filter'):
        return [str(start), str(start + count)]
    return [format(start / rate, '.17g'), format((start + count) / rate, '.17g')]


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
              'rangeMode': args.range_mode, 'demuxer': args.demuxer,
              'aacDecoder': args.aac_decoder,
              'aacPNS': args.aac_pns,
              'mp3Container': args.mp3_container, 'mp3Remuxes': [],
              'movEditList': args.mov_edit_list, 'seekOffset': args.seek_offset,
              'filterPreroll': args.filter_preroll,
              'embeddedReferences': [],
              'meanAmplitudeTolerance': MEAN_LIMIT, 'peakAmplitudeTolerance': PEAK_LIMIT,
              'comparisonPolicy': 'Exact interleaved sample count, per-channel mean and all-sample peak; no alignment, padding or edge masking',
              'limitations': ['Offline PCM sink; no CoreAudio or hardware synchronization',
                              'Natural playback and start/end loading ranges, not asynchronous in-place seeks or proxy composition',
                              'Generated same-rate mono/stereo subset; no resampling or distribution qualification']}
    if args.seek_offset is not None:
        result['limitations'].append('Explicit high-resolution demuxer seek preroll; loading ranges only, not asynchronous in-place seeks')
    if args.range_mode == 'sample-filter':
        result['limitations'].append('Integer atrim decodes every preceding sample from source zero; not a random-access seek solution')
    if args.range_mode == 'pts-filter':
        result['limitations'].append('Absolute sample-timebase atrim after an earlier loading seek; no in-place seek, full-duration efficiency or arbitrary timestamp qualification')
    if args.mov_edit_list == 'basic':
        result['limitations'].append('Explicit lavf advanced_editlist=0 control; generated single-edit MOV only, not complex edit-list qualification')
    if args.aac_pns != 'default':
        result['limitations'].append('AAC encoder PNS fixture control only; does not disable noise substitution in arbitrary source media or qualify general AAC seeking')
    if args.mp3_container == 'mov-remux':
        result['limitations'].append('Same-packet Matroska to MOV remux changes container timing and may change gapless metadata; not a pure timebase isolation or source repair')

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
        source_names = ['mpv-audio-proof.c', 'mpv-audio-proof.py', 'mpv-source-proof.py']
        if args.embedded_reference:
            source_names.append('mpv-audio-reference.c')
        for name in source_names:
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
        embedded_executable = root / 'embedded-audio-reference'
        if args.embedded_reference:
            headers = root / 'headers'
            headers.mkdir()
            for name, (framework, _) in zip(source.ARTIFACTS, frameworks):
                if name.startswith(('Libav', 'Libsw')):
                    (headers / name.split('-')[0].lower()).symlink_to(framework / 'Headers')
            embedded_command = [str(item) for item in command]
            embedded_command[embedded_command.index(str(snapshot / 'mpv-audio-proof.c'))] = str(snapshot / 'mpv-audio-reference.c')
            embedded_command[-1] = str(embedded_executable)
            embedded_command.extend(['-I', str(headers), '-framework', 'Security'])
            run(embedded_command, 'compile-embedded-reference')
            result['embeddedExecutableSHA256'] = source.digest(embedded_executable)
            run(['/usr/bin/otool', '-L', embedded_executable], 'embedded-linked-libraries')
            result['limitations'].append('Direct embedded AAC baseline applies explicit decoder skip/discard metadata; separate first-packet/frame-duration controls test priming and explicit frame extent, never repair MPV captures')
        result['addressSanitizer'] = args.sanitize_address
        result['executableSHA256'] = source.digest(executable)
        result['ffmpegSHA256'] = source.digest(args.ffmpeg)
        run([args.ffmpeg, '-version'], 'ffmpeg-version')
        if args.ffprobe is not None:
            result['ffprobeSHA256'] = source.digest(args.ffprobe)
            run([args.ffprobe, '-version'], 'ffprobe-version')
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
                                '-c:v', 'libx264', *audio_encoder_arguments(codec, args.aac_pns), fixture])
                run(command, 'generate-' + name)
                original_fixture = fixture
                if codec == 'libmp3lame' and args.mp3_container == 'mov-remux':
                    fixture = root / f'{name}.mov'
                    run([args.ffmpeg, '-v', 'error', '-nostdin', '-n', '-i', original_fixture,
                         '-map', '0', '-c', 'copy', fixture], 'remux-' + name)
                    probes = []
                    for label, media in (('original', original_fixture), ('remuxed', fixture)):
                        probe = run([args.ffprobe, '-v', 'error', '-show_streams', '-show_packets',
                                     '-show_data_hash', 'sha256', '-of', 'json', media],
                                    f'probe-{name}-{label}')
                        probes.append(json.loads(probe.stdout))
                    result['mp3Remuxes'].append({'name': name,
                        'originalFixtureSHA256': source.digest(original_fixture),
                        'remuxedFixtureSHA256': source.digest(fixture),
                        'streams': validate_mp3_remux(*probes, rate, channels), 'references': []})
                for rejected_index in (1, 99):
                    reject_name = f'reject-{name}-{rejected_index}'
                    reject_output = root / (reject_name + '.f32')
                    completed = run([executable, fixture, rejected_index, reject_output,
                                     'natural', '3', rate, args.range_mode, args.demuxer,
                                     'auto', args.mov_edit_list,
                                     'default' if args.seek_offset is None else format(args.seek_offset, '.17g'),
                                     'default' if args.filter_preroll is None else format(args.filter_preroll, '.17g')],
                                    reject_name, timeout=25, allow_failure=True)
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
                    if codec == 'libmp3lame' and args.mp3_container == 'mov-remux':
                        original_reference = root / f'{name}-stream-{stream}-original.f32'
                        run([args.ffmpeg, '-v', 'error', '-nostdin', '-n', '-i', original_fixture,
                             '-map', f'0:{ff_index}', '-c:a', 'pcm_f32le', '-f', 'f32le', original_reference],
                            f'decode-original-{name}-{stream}')
                        result['mp3Remuxes'][-1]['references'].append({'ffIndex': ff_index,
                            'originalSHA256': source.digest(original_reference),
                            'remuxedSHA256': source.digest(reference),
                            'remuxedVsOriginal': compare_audio(reference_bytes, original_reference.read_bytes(), channels)})
                    embedded_bytes = None
                    seek_zero_bytes = None
                    if args.embedded_reference and codec == 'aac':
                        controls = {}
                        entry = {'name': f'{name}-{stream}', 'fixtureSHA256': source.digest(fixture)}
                        for mode in ('unseeked', 'seek-zero', 'seek-first-packet', 'seek-first-packet-duration'):
                            embedded_output = root / f'{name}-stream-{stream}-{mode}.f32'
                            completed = run([embedded_executable, fixture, ff_index, embedded_output, 'aac',
                                             *(['seek-first-packet', 'frame-duration'] if mode == 'seek-first-packet-duration'
                                                else [] if mode == 'unseeked' else [mode])],
                                            f'{mode}-{name}-{stream}')
                            metadata = json.loads(completed.stdout)
                            data = embedded_output.read_bytes()
                            validate_embedded_metadata(metadata, data, ff_index, rate, channels, mode)
                            controls[mode] = data
                            control = {'metadata': metadata, 'outputSHA256': source.digest(embedded_output),
                                       'naturalVsExternal': compare_audio(data, reference_bytes, channels)}
                            if mode == 'unseeked':
                                entry.update(control)
                            else:
                                entry[{'seek-zero': 'seekZero', 'seek-first-packet': 'seekFirstPacket',
                                       'seek-first-packet-duration': 'seekFirstPacketDuration'}[mode]] = control
                        embedded_bytes = controls['unseeked']
                        seek_zero_bytes = controls['seek-zero']
                        first_packet_bytes = controls['seek-first-packet']
                        duration_bytes = controls['seek-first-packet-duration']
                        entry['firstPacketVsUnseeked'] = compare_audio(first_packet_bytes, embedded_bytes, channels)
                        result['embeddedReferences'].append(entry)
                    for label, start, count in (('natural', 0, len(reference_bytes) // (channels * 4)),
                                                ('whole', 0, rate * 3), ('sample-1023', 1023, 4097),
                                                ('sample-1024', 1024, 4097),
                                                ('sample-1025', 1025, 4097), ('tail', rate * 3 - 4097, 4097)):
                        case_name = f'{name}-{stream}-{label}'
                        output = root / (case_name + '.f32')
                        completed = run([executable, fixture, ff_index, output,
                                         *range_arguments(label, start, count, rate, args.range_mode),
                                         rate, args.range_mode, args.demuxer,
                                         args.aac_decoder if codec == 'aac' else 'auto',
                                         args.mov_edit_list,
                                         'default' if args.seek_offset is None else format(args.seek_offset, '.17g'),
                                         'default' if args.filter_preroll is None else format(args.filter_preroll, '.17g')],
                                        case_name, timeout=25, allow_failure=True)
                        case = {'name': case_name, 'codec': codec, 'rate': rate, 'channels': channels,
                                'ffIndex': ff_index, 'startSample': start, 'requestedSamples': count,
                                'fixtureSHA256': source.digest(fixture), 'passed': False}
                        if completed.returncode:
                            case['error'] = 'MPV client failed; see log'
                        else:
                            case['selectedDecoder'] = selected_decoder(completed.stderr.decode(),
                                                                      args.aac_decoder if codec == 'aac' else 'auto')
                            case['selection'] = json.loads(completed.stdout)
                            if (case['selection'].get('passed') is not True
                                    or case['selection'].get('ffIndex') != ff_index
                                    or case['selection'].get('audioTrackID') != stream + 1
                                    or case['selection'].get('movEditList') != args.mov_edit_list):
                                raise ValueError('Runtime track identity did not match requested audio stream')
                            if args.filter_preroll is not None and (
                                    case['selection'].get('filterPreroll') != args.filter_preroll):
                                raise ValueError('Runtime filter preroll does not match requested control')
                            if args.seek_offset is not None:
                                validate_seek_offset(case['selection'].get('seekOffset'), args.seek_offset)
                            expected = reference_bytes[start * channels * 4:(start + count) * channels * 4]
                            if len(expected) != count * channels * 4:
                                raise ValueError('Reference does not cover requested nominal source range')
                            case.update(compare_audio(output.read_bytes(), expected, channels))
                            if embedded_bytes is not None:
                                embedded_expected = (embedded_bytes if label == 'natural' else
                                    embedded_bytes[start * channels * 4:(start + count) * channels * 4])
                                if label != 'natural' and len(embedded_expected) != len(expected):
                                    raise ValueError('Embedded reference does not cover requested range')
                                case['captureVsEmbedded'] = compare_audio(output.read_bytes(), embedded_expected, channels)
                                seek_expected = (seek_zero_bytes if label == 'natural' else
                                    seek_zero_bytes[start * channels * 4:(start + count) * channels * 4])
                                if label != 'natural' and len(seek_expected) != len(expected):
                                    raise ValueError('Seek-zero reference does not cover requested range')
                                case['captureVsSeekZero'] = compare_audio(output.read_bytes(), seek_expected, channels)
                                first_expected = (first_packet_bytes if label == 'natural' else
                                    first_packet_bytes[start * channels * 4:(start + count) * channels * 4])
                                if label != 'natural' and len(first_expected) != len(expected):
                                    raise ValueError('First-packet reference does not cover requested range')
                                duration_expected = (duration_bytes if label == 'natural' else
                                    duration_bytes[start * channels * 4:(start + count) * channels * 4])
                                case['firstPacketDurationRangeVsExternal'] = compare_audio(duration_expected, expected, channels)
                                case['firstPacketRangeVsExternal'] = compare_audio(first_expected, expected, channels)
                                if label != 'natural':
                                    case['embeddedRangeVsExternal'] = compare_audio(embedded_expected, expected, channels)
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
    parser.add_argument('--range-mode', choices=('timestamp', 'sample-filter', 'pts-filter'), default='timestamp',
                        help='sample-filter decodes from zero; pts-filter preserves timestamps after a preroll loading seek')
    parser.add_argument('--demuxer', choices=('auto', 'lavf'), default='auto')
    parser.add_argument('--mov-edit-list', choices=('default', 'basic'), default='default',
                        help='Basic passes advanced_editlist=0 to forced lavf; does not disable edit lists')
    parser.add_argument('--seek-offset', type=float,
                        help='Explicit hr-seek demuxer preroll in seconds; timestamp mode only')
    parser.add_argument('--filter-preroll', type=float,
                        help='PTS filter only: start playback this many seconds before the requested integer cut')
    parser.add_argument('--aac-decoder', choices=('auto', 'aac', 'aac_fixed', 'aac_at'), default='auto',
                        help='AAC-only decoder control; forced names disable fallback and require observed selection')
    parser.add_argument('--aac-pns', choices=('default', 'on', 'off'), default='default',
                        help='Fixture encoder control for AAC perceptual noise substitution; does not change MPV decoding')
    parser.add_argument('--mp3-container', choices=('matroska', 'mov-remux'), default='matroska',
                        help='MP3-only same-packet container control; MOV remux may change gapless metadata')
    parser.add_argument('--ffprobe', type=Path, help='Required for MOV remux packet identity and timing evidence')
    parser.add_argument('--embedded-reference', action='store_true',
                        help='Also decode AAC directly with the same embedded libraries, bypassing MPV')
    for name in ('checkout', 'artifacts', 'ffmpeg', 'output'):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    if args.mp3_container == 'mov-remux' and args.ffprobe is None:
        parser.error('--mp3-container mov-remux requires --ffprobe')
    if args.ffprobe is not None and (not args.ffprobe.is_absolute() or not os.access(args.ffprobe, os.X_OK)):
        parser.error('ffprobe must be absolute and executable')
    if args.mov_edit_list == 'basic' and args.demuxer != 'lavf':
        parser.error('--mov-edit-list basic requires --demuxer lavf')
    if args.seek_offset is not None and (not math.isfinite(args.seek_offset)
            or not 0 <= args.seek_offset <= 3.4028234663852886e38 or args.range_mode != 'timestamp'):
        parser.error('--seek-offset requires finite nonnegative seconds and --range-mode timestamp')
    if ((args.range_mode == 'pts-filter') != (args.filter_preroll is not None)
            or (args.filter_preroll is not None and (not math.isfinite(args.filter_preroll)
                or not 0 <= args.filter_preroll <= 3600))):
        parser.error('--range-mode pts-filter requires --filter-preroll with finite seconds from 0 to 3600; other modes forbid it')
    for name in ('checkout', 'artifacts', 'ffmpeg', 'output'):
        if not getattr(args, name).is_absolute():
            parser.error(name + ' must be absolute')
    if not os.access(args.ffmpeg, os.X_OK) or args.output.exists():
        parser.error('ffmpeg must be executable and output must not exist')
    return run_proof(args)


if __name__ == '__main__':
    sys.exit(main())
