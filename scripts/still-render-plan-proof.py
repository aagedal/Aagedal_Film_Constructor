#!/usr/bin/env python3
"""Qualify first-frame PNG/JPEG export, alpha, scaling and sample-aligned audio ends."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
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

def run(command, log):
    with (root / log).open('wb') as stream:
        subprocess.run([str(x) for x in command], stdout=stream, stderr=subprocess.STDOUT, check=True, env=env)

env = os.environ.copy()
env['CLANG_MODULE_CACHE_PATH'] = str(root / 'module-cache')
env['SWIFTPM_MODULECACHE_OVERRIDE'] = str(root / 'module-cache')
swift = ['swift', 'run', '--package-path', repo / 'Packages/EditorCore', '--scratch-path', root / 'build',
         '--cache-path', root / 'cache', '--disable-sandbox', 'RenderPlanProof']
for name, executable in [('ffmpeg', args.ffmpeg), ('ffprobe', args.ffprobe)]:
    run([executable, '-version'], name + '-version.txt')
    (root / (name + '.sha256')).write_text(hashlib.sha256(executable.read_bytes()).hexdigest() + '\n')
run([*swift, root], 'fixture.log')
project = json.loads((root / 'project.json').read_text())
# Alpha red portrait over opaque blue landscape. All sources are independent fixtures.
(root / 'red.rgba').write_bytes(bytes([255, 0, 0, 128]) * 80 * 90)
run([args.ffmpeg, '-v', 'error', '-n', '-f', 'rawvideo', '-pix_fmt', 'rgba', '-s', '80x90',
     '-i', root / 'red.rgba', '-frames:v', '1', root / 'red.png'], 'png.log')
run([args.ffmpeg, '-v', 'error', '-n', '-f', 'lavfi', '-i', 'color=blue:s=160x90',
     '-frames:v', '1', root / 'blue.jpg'], 'jpeg.log')
project['tracks'] = project['tracks'][:2]
project['families'] = project['families'][:1]
for index, track in enumerate(project['tracks']):
    asset = project['assets'][1 - index]
    asset['streams'] = []  # App image-import semantics.
    asset['originalURL'] = (root / ('red.png' if index == 0 else 'blue.jpg')).as_uri()
    track['clips'][0]['selection'] = {'still': {}}
    # Synthetic source in-points deliberately remain nonzero from baseline fixture.
checks = []
for mode in ('fit', 'fill', 'none'):
    project['tracks'][0]['clips'][0]['scalingMode'] = mode
    path = root / (mode + '-project.json')
    path.write_text(json.dumps(project))
    run([*swift, 'compile-render', path, root / (mode + '.mov'), root / (mode + '-command.json')], mode + '-compile.log')
    command = json.loads((root / (mode + '-command.json')).read_text())
    run([args.ffmpeg, *command['arguments']], mode + '-render.log')
    run([args.ffmpeg, '-v', 'error', '-n', '-i', root / (mode + '.mov'), '-map', '0:v:0',
         '-fps_mode', 'passthrough', '-pix_fmt', 'rgb24', '-f', 'rawvideo', root / (mode + '.rgb')], mode + '-decode.log')
    data = (root / (mode + '.rgb')).read_bytes()
    size = 160 * 90 * 3
    assert len(data) == size * command['videoFrames'] == size * 180
    for frame in (0, 2, 3, 119, 120, 179):
        active = 3 <= frame < 120
        for x in (10, 80, 150):
            offset = frame * size + (45 * 160 + x) * 3
            rgb = list(data[offset:offset + 3])
            blended = active and (mode == 'fill' or 40 <= x < 120)
            expected = (128, 0, 127) if blended else (0, 0, 255)
            assert max(abs(a-b) for a, b in zip(rgb, expected)) < 12, (mode, frame, x, rgb, expected)
            checks.append({'scaling': mode, 'frame': frame, 'x': x, 'rgb': rgb})
# Audio sequence end falls one sample after 1s: 25 video frames at 24fps, 48001 PCM samples.
audio = json.loads((root / 'project.json').read_text())
audio['tracks'] = audio['tracks'][2:]
audio['assets'] = audio['assets'][:1]
audio['settings']['frameRate']['value'] = {'numerator': 24, 'denominator': 1}
audio['settings']['startTimecode'] = {'frameCount': 0, 'mode': 'nonDropFrame'}
clip = audio['tracks'][0]['clips'][0]
clip['timelineStart'] = clip['sourceRange']['start'] = {'numerator': 0, 'denominator': 1}
clip['sourceRange']['duration'] = {'numerator': 48001, 'denominator': 48000}
run([args.ffmpeg, '-v', 'error', '-n', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=2',
     '-map', '0:a', '-map', '0:a', '-c:a', 'pcm_s16le', root / 'audio.mov'], 'audio-source.log')
audio['assets'][0]['originalURL'] = (root / 'audio.mov').as_uri()
audio['assets'][0]['streams'] = [dict(s, index=i) for i, s in enumerate(audio['assets'][0]['streams'][1:])]
clip['selection']['audio']['_0']['channels'] = [{'streamIndex': 0, 'channelIndex': 0}, {'streamIndex': 1, 'channelIndex': 0}]
(root / 'audio-project.json').write_text(json.dumps(audio))
run([*swift, 'compile-render', root / 'audio-project.json', root / 'audio-output.mov', root / 'audio-command.json'], 'audio-compile.log')
command = json.loads((root / 'audio-command.json').read_text())
run([args.ffmpeg, *command['arguments']], 'audio-render.log')
run([args.ffmpeg, '-v', 'error', '-n', '-i', root / 'audio-output.mov', '-map', '0:a:0',
     '-c:a', 'pcm_s16le', '-f', 's16le', root / 'audio.pcm'], 'audio-decode.log')
run([args.ffprobe, '-v', 'error', '-count_frames', '-show_streams', '-of', 'json', root / 'audio-output.mov'], 'audio-probe.json')
probe = json.loads((root / 'audio-probe.json').read_text())
video = next(s for s in probe['streams'] if s['codec_type'] == 'video')
assert int(video['nb_read_frames']) == command['videoFrames'] == 25
assert (root / 'audio.pcm').stat().st_size // 4 == command['audioSamples'] == 48001
result = {'stillFrames': 180, 'alphaScalingCutChecks': checks, 'sampleAlignedEnd': {'videoFrames': 25, 'audioSamples': 48001},
          'mpvParityTested': False, 'sourceGeometryColorRotationVFRQualified': False}
(root / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({'stillFrames': 180, 'alphaScalingCutChecks': len(checks), 'sampleAlignedEnd': result['sampleAlignedEnd']}))
