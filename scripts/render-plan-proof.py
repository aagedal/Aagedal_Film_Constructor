#!/usr/bin/env python3
"""Development-only integration proof of the EditorCore-generated FFmpeg graph."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import struct
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('ffmpeg', type=Path)
parser.add_argument('ffprobe', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
for executable in (args.ffmpeg, args.ffprobe):
    if not executable.is_absolute() or not os.access(executable, os.X_OK):
        parser.error('Supply explicit absolute executable paths for FFmpeg and FFprobe')
if args.output.exists() or not args.output.is_absolute():
    parser.error('Output must be a new absolute directory')
args.output.mkdir(parents=True)
root = args.output
repo = Path(__file__).resolve().parent.parent

def run(command, log):
    with (root / log).open('wb') as stream:
        subprocess.run([str(x) for x in command], stdout=stream, stderr=subprocess.STDOUT, check=True)

def ff(arguments, log):
    run([args.ffmpeg, '-hide_banner', '-nostdin', '-n', *arguments], log)

for name, executable in [('ffmpeg', args.ffmpeg), ('ffprobe', args.ffprobe)]:
    run([executable, '-version'], name + '-version.txt')
    (root / (name + '.sha256')).write_text(hashlib.sha256(executable.read_bytes()).hexdigest() + '\n')
# Ten full-height binary stripes encode a 9-bit frame number plus a source bit.
# A one-bit mismatch changes whole-frame mean RGB by 19.2, above tolerance 12.
# This avoids collisions between an RGB color ramp and its inverted source.
def barcode(offset):
    value = f"32+192*mod(floor((N+{offset})/pow(2,floor(X/16))),2)"
    return f"testsrc=size=160x90:rate=30000/1001:duration=10.01,geq=r='{value}':g='{value}':b='{value}'"

ff(['-f', 'lavfi', '-i', barcode(0),
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=10.01',
    '-f', 'lavfi', '-i', 'sine=frequency=880:sample_rate=48000:duration=10.01',
    '-map', '0:v', '-map', '1:a', '-map', '2:a', '-c:v', 'qtrle', '-c:a', 'pcm_s16le', root / 'a.mov'], 'source-a.log')
ff(['-f', 'lavfi', '-i', barcode(512),
    '-c:v', 'qtrle', root / 'b.mov'], 'source-b.log')
env = os.environ.copy()
env['CLANG_MODULE_CACHE_PATH'] = str(root / 'module-cache')
env['SWIFTPM_MODULECACHE_OVERRIDE'] = str(root / 'module-cache')
with (root / 'compiler.log').open('wb') as stream:
    subprocess.run(['swift', 'run', '--package-path', str(repo / 'Packages/EditorCore'),
                    '--scratch-path', str(root / 'build'), '--cache-path', str(root / 'cache'),
                    '--disable-sandbox', 'RenderPlanProof', str(root)], env=env,
                   stdout=stream, stderr=subprocess.STDOUT, check=True)
command = json.loads((root / 'command.json').read_text())
ff(command['arguments'], 'render.log')
with (root / 'probe.json').open('wb') as stream:
    subprocess.run([str(args.ffprobe), '-v', 'error', '-count_frames', '-show_streams',
                    '-show_format', '-of', 'json', str(root / 'render.mov')], stdout=stream, check=True)
probe = json.loads((root / 'probe.json').read_text())
video = next(s for s in probe['streams'] if s['codec_type'] == 'video')
audio = next(s for s in probe['streams'] if s['codec_type'] == 'audio')
assert int(video['nb_read_frames']) == command['videoFrames'] == 180
assert video['avg_frame_rate'] == '30000/1001'
assert (video['width'], video['height']) == (160, 90)
assert any(s.get('tags', {}).get('timecode') == '01:00:00;00' for s in probe['streams'])
assert int(audio['sample_rate']) == 48000 and audio['channels'] == 2
for name in ('a', 'b', 'render'):
    ff(['-i', root / (name + '.mov'), '-map', '0:v:0', '-fps_mode', 'passthrough',
        '-pix_fmt', 'rgb24', '-f', 'rawvideo', root / (name + '.rgb')], name + '-decode.log')
ff(['-i', root / 'render.mov', '-map', '0:a:0', '-c:a', 'pcm_s16le',
    '-f', 's16le', root / 'audio.pcm'], 'audio-decode.log')
frames = {name: (root / (name + '.rgb')).read_bytes() for name in ('a', 'b', 'render')}
size = 160 * 90 * 3
assert len(frames['render']) == size * 180
checks = []
# Qualify exact cuts, upper layer priority, source in-points and frame identity.
for n in (0, 2, 3, 15, 59, 60, 75, 119, 120, 150, 179):
    source, frame = ('b', n + 57) if 3 <= n < 120 else ('a', n + 30)
    actual = frames['render'][n * size:(n + 1) * size]
    expected = frames[source][frame * size:(frame + 1) * size]
    error = sum(abs(a - b) for a, b in zip(actual, expected)) / size
    assert error < 12, (n, source, frame, error)
    checks.append({'sequenceFrame': n, 'source': source, 'sourceFrame': frame, 'meanRGBError': error})
pcm = (root / 'audio.pcm').read_bytes()
assert len(pcm) // 4 == command['audioSamples'] == 288288

def amplitude(time, channel, frequency):
    start, count = round(time * 48000), 4800
    values = [struct.unpack_from('<h', pcm, 4 * (start + i) + 2 * channel)[0] for i in range(count)]
    real = sum(v * math.cos(2 * math.pi * frequency * i / 48000) for i, v in enumerate(values))
    imag = sum(v * math.sin(2 * math.pi * frequency * i / 48000) for i, v in enumerate(values))
    return 2 * math.hypot(real, imag) / count

for time in (0.5, 1.5, 3.0, 5.5):
    active = 1.001 <= time < 5.005
    for channel, frequency in ((0, 880), (1, 440)):
        measured = amplitude(time, channel, frequency)
        assert abs(measured - (2047.5 if active else 0)) < 20, (time, channel, measured)
        assert amplitude(time, channel, 440 if frequency == 880 else 880) < 20
# Exact sample boundaries, including silence outside the component.
start, end = 48048, 240240
assert all(value == 0 for value in pcm[:start * 4])
assert all(value == 0 for value in pcm[end * 4:])
result = {'decodedVideoFrames': 180, 'audioSamplesPerChannel': 288288,
          'frameRate': '30000/1001', 'timecode': '01:00:00;00', 'videoChecks': checks,
          'sourceStreamMap': {'left': 2, 'right': 1}, 'staticGain': 0.5,
          'audioActiveSamples': [start, end], 'mpvParityTested': False}
(root / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
