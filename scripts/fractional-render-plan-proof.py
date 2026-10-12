#!/usr/bin/env python3
"""Decode a CFR export matrix compiled from persisted EditorCore projects.

Development evidence only: does not qualify native import, VFR, MPV parity or
arbitrary source codecs. Keep output outside the repository (large media).
"""
import argparse
import copy
from fractions import Fraction
import hashlib
import json
import math
import os
from pathlib import Path
import struct
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('ffmpeg', type=Path)
parser.add_argument('ffprobe', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
for executable in (args.ffmpeg, args.ffprobe):
    if not executable.is_absolute() or not os.access(executable, os.X_OK):
        parser.error('Supply explicit absolute FFmpeg and FFprobe executable paths')
if not args.output.is_absolute() or args.output.exists():
    parser.error('Output must be a new absolute directory')
root = args.output
root.mkdir(parents=True)
repo = Path(__file__).resolve().parent.parent
env = os.environ.copy()
env['CLANG_MODULE_CACHE_PATH'] = str(root / 'module-cache')
env['SWIFTPM_MODULECACHE_OVERRIDE'] = str(root / 'module-cache')


def run(command, log):
    with log.open('wb') as stream:
        subprocess.run([str(x) for x in command], stdout=stream,
                       stderr=subprocess.STDOUT, check=True, env=env)


def ff(arguments, log):
    run([args.ffmpeg, '-hide_banner', '-nostdin', '-n', *arguments], log)


def rational(value):
    return {'numerator': value.numerator, 'denominator': value.denominator}


fingerprints = {}
for name, executable in [('ffmpeg', args.ffmpeg), ('ffprobe', args.ffprobe)]:
    run([executable, '-version'], root / (name + '-version.txt'))
    fingerprints[name] = {'version': (root / (name + '-version.txt')).read_text().splitlines()[0],
                          'sha256': hashlib.sha256(executable.read_bytes()).hexdigest()}
run(['swift', 'run', '--package-path', repo / 'Packages/EditorCore', '--scratch-path', root / 'build',
     '--cache-path', root / 'cache', '--disable-sandbox', 'RenderPlanProof', root], root / 'compiler.log')
compiler = root / 'build/debug/RenderPlanProof'
baseline = json.loads((root / 'project.json').read_text())
results = []
# DF cases begin immediately before the first skipped-label minute boundary.
cases = [('24-ndf', 24, 1, 86400, '01:00:00:00', 'nonDropFrame'),
         ('23976-ndf', 24000, 1001, 86398, '00:59:59:22', 'nonDropFrame'),
         ('2997-df', 30000, 1001, 1798, '00:00:59;28', 'dropFrame'),
         ('5994-df', 60000, 1001, 3596, '00:00:59;56', 'dropFrame')]
for name, numerator, denominator, start_count, label, mode in cases:
    case = root / name
    case.mkdir()
    rate = Fraction(numerator, denominator)
    frame_time = 1 / rate

    def barcode(offset):
        value = f"32+192*mod(floor((N+{offset})/pow(2,floor(X/16))),2)"
        return f"testsrc=size=160x90:rate={rate}:duration=13,geq=r='{value}':g='{value}':b='{value}'"

    ff(['-f', 'lavfi', '-i', barcode(0), '-f', 'lavfi', '-i',
        'sine=frequency=440:sample_rate=48000:duration=13', '-f', 'lavfi', '-i',
        'sine=frequency=880:sample_rate=48000:duration=13', '-map', '0:v', '-map', '1:a',
        '-map', '2:a', '-frames:v', '300', '-c:v', 'qtrle', '-c:a', 'pcm_s16le', case / 'a.mov'], case / 'a-source.log')
    ff(['-f', 'lavfi', '-i', barcode(512), '-frames:v', '300', '-c:v', 'qtrle',
        case / 'b.mov'], case / 'b-source.log')
    project = copy.deepcopy(baseline)
    project['settings']['frameRate']['value'] = rational(rate)
    project['settings']['startTimecode'] = {'frameCount': start_count, 'mode': mode}
    for asset, source in zip(project['assets'], ['a', 'b']):
        asset['originalURL'] = (case / (source + '.mov')).as_uri()
        asset['duration'] = rational(300 * frame_time)
    # The baseline uses exact 30000/1001 frame ranges. Preserve frame numbers.
    for track in project['tracks']:
        for clip in track['clips']:
            for container, key in [(clip, 'timelineStart'), (clip['sourceRange'], 'start'),
                                   (clip['sourceRange'], 'duration')]:
                old = container[key]
                frames = Fraction(old['numerator'], old['denominator']) * Fraction(30000, 1001)
                assert frames.denominator == 1
                container[key] = rational(frames * frame_time)
    (case / 'project.json').write_text(json.dumps(project, indent=2) + '\n')
    run([compiler, 'compile-render', case / 'project.json', case / 'render.mov',
         case / 'command.json'], case / 'compile.log')
    command = json.loads((case / 'command.json').read_text())
    ff(command['arguments'], case / 'render.log')
    run([args.ffprobe, '-v', 'error', '-count_frames', '-show_streams', '-show_format', '-of',
         'json', case / 'render.mov'], case / 'probe.json')
    probe = json.loads((case / 'probe.json').read_text())
    video = next(s for s in probe['streams'] if s['codec_type'] == 'video')
    audio = next(s for s in probe['streams'] if s['codec_type'] == 'audio')
    assert int(video['nb_read_frames']) == command['videoFrames'] == 180
    assert Fraction(video['avg_frame_rate']) == rate
    assert (video['width'], video['height']) == (160, 90)
    assert video['sample_aspect_ratio'] == '1:1'
    assert video['codec_name'] == 'prores' and video['profile'] == 'HQ'
    assert audio['codec_name'] == 'pcm_s24le'
    assert int(audio['sample_rate']) == 48000 and audio['channels'] == 2
    timecodes = [s.get('tags', {}).get('timecode') for s in probe['streams']]
    assert label in timecodes, timecodes
    # Inspect the actual MOV timecode packet, independently of the display tag.
    timecode_stream = next(s for s in probe['streams'] if s.get('codec_tag_string') == 'tmcd')
    run([args.ffprobe, '-v', 'error', '-select_streams', str(timecode_stream['index']),
         '-show_packets', '-of', 'json', case / 'render.mov'], case / 'timecode-packets.json')
    packets = json.loads((case / 'timecode-packets.json').read_text())['packets']
    assert len(packets) == 1 and int(packets[0]['size']) == 4
    with (case / 'render.mov').open('rb') as media:
        media.seek(int(packets[0]['pos']))
        packet_count = int.from_bytes(media.read(4), 'big')
    assert packet_count == start_count
    assert int(packets[0]['duration']) * Fraction(timecode_stream['time_base']) == 180 * frame_time
    run([args.ffprobe, '-v', 'error', '-select_streams', 'v:0', '-show_frames',
         '-show_entries', 'frame=pts', '-of', 'json', case / 'render.mov'], case / 'timestamps.json')
    timestamps = json.loads((case / 'timestamps.json').read_text())['frames']
    assert len(timestamps) == 180
    for n, frame in enumerate(timestamps):
        assert int(frame['pts']) * Fraction(video['time_base']) == n * frame_time
    ff(['-i', case / 'render.mov', '-map', '0:v:0', '-fps_mode', 'passthrough',
        '-pix_fmt', 'rgb24', '-f', 'rawvideo', case / 'render.rgb'], case / 'video-decode.log')
    pixels = (case / 'render.rgb').read_bytes()
    size = 160 * 90 * 3
    assert len(pixels) == size * 180
    # Decode stripe IDs directly, independently of source decoding or compiler metadata.
    for n in range(180):
        expected = n + 57 + 512 if 3 <= n < 120 else n + 30
        actual = 0
        for bit in range(10):
            offset = n * size + (45 * 160 + bit * 16 + 8) * 3
            values = pixels[offset:offset + 3]
            level = 224 if expected & (1 << bit) else 32
            assert max(abs(v - level) for v in values) < 12, (name, n, bit, list(values), level)
            actual |= (sum(values) > 3 * 128) << bit
        assert actual == expected
    ff(['-i', case / 'render.mov', '-map', '0:a:0', '-c:a', 'pcm_s16le', '-f',
        's16le', case / 'audio.pcm'], case / 'audio-decode.log')
    pcm = (case / 'audio.pcm').read_bytes()
    sample_count = 180 * frame_time * 48000
    active_start, active_end = 30 * frame_time * 48000, 150 * frame_time * 48000
    assert all(x.denominator == 1 for x in [sample_count, active_start, active_end])
    sample_count, active_start, active_end = map(int, [sample_count, active_start, active_end])
    assert len(pcm) == sample_count * 4 and command['audioSamples'] == sample_count
    assert not any(pcm[:active_start * 4]) and not any(pcm[active_end * 4:])

    def amplitude(start, channel, frequency):
        count = 4800
        values = [struct.unpack_from('<h', pcm, 4 * (start + i) + channel * 2)[0] for i in range(count)]
        real = sum(v * math.cos(2 * math.pi * frequency * i / 48000) for i, v in enumerate(values))
        imag = sum(v * math.sin(2 * math.pi * frequency * i / 48000) for i, v in enumerate(values))
        return 2 * math.hypot(real, imag) / count

    channel_checks = []
    for start in [active_start, (active_start + active_end) // 2, active_end - 4800]:
        for channel, frequency in [(0, 880), (1, 440)]:
            measured = amplitude(start, channel, frequency)
            leakage = amplitude(start, channel, 440 if frequency == 880 else 880)
            assert abs(measured - 2047.5) < 20 and leakage < 20
            # Phase checks qualify the source in-point and output placement in
            # addition to channel identity. FFmpeg's s16 sine is quantized.
            max_phase_error = max(abs(struct.unpack_from('<h', pcm, 4 * (start + i) + channel * 2)[0]
                                      - 2047.5 * math.sin(2 * math.pi * frequency * (start + i) / 48000))
                                  for i in range(480))
            assert max_phase_error < 4, (name, start, channel, max_phase_error)
            channel_checks.append({'sample': start, 'channel': channel, 'frequency': frequency,
                                   'amplitude': measured, 'otherChannelFrequencyLeakage': leakage,
                                   'maxPhaseSampleError': max_phase_error})
    results.append({'case': name, 'frameRate': str(rate), 'decodedVideoFrames': 180,
                    'decodedBarcodeFramesChecked': 180, 'exactVideoTimestampsChecked': 180,
                    'raster': [160, 90], 'sampleAspectRatio': '1:1', 'startFrameCount': start_count,
                    'timecodePacketFrameCount': packet_count,
                    'readBackTimecode': label, 'audioSamplesPerChannel': sample_count,
                    'audioActiveSamples': [active_start, active_end], 'channelChecks': channel_checks})
    print(f'{name}: 180 barcode frames and timestamps, {sample_count} samples/channel, {label}', flush=True)
result = {'toolFingerprints': fingerprints, 'cases': results, 'nativeReceiverQualified': False,
          'mpvParityTested': False, 'sourceGeometryColorRotationVFRQualified': False}
(root / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
