#!/usr/bin/env python3
"""Qualify system sequence seeks with decoded barcodes; keep generated media outside the repo."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('ffmpeg', type=Path)
parser.add_argument('output', type=Path)
parser.add_argument('--include-open-gop', action='store_true', help='Also exercise the known unqualified open-GOP HEVC case')
args = parser.parse_args()
if not args.ffmpeg.is_absolute() or not os.access(args.ffmpeg, os.X_OK):
    parser.error('Supply an absolute FFmpeg executable')
if not args.output.is_absolute() or args.output.exists():
    parser.error('Supply a new absolute output directory')
root = args.output
root.mkdir(parents=True)
repo = Path(__file__).resolve().parent.parent
sources = repo / 'Aagedal Film Constructor'
env = dict(os.environ, DYLD_LIBRARY_PATH=str(root), NSUnbufferedIO='YES')

def run(command, log):
    with (root / log).open('wb') as stream:
        subprocess.run(list(map(str, command)), env=env, stdout=stream, stderr=subprocess.STDOUT, check=True, timeout=240)

run([args.ffmpeg, '-version'], 'ffmpeg-version.txt')
common = ['swiftc', '-swift-version', '6', '-default-isolation', 'MainActor', '-module-cache-path', root / 'module-cache']
run([*common, '-emit-library', '-emit-module', '-module-name', 'EditorCore',
     *sorted((repo / 'Packages/EditorCore/Sources/EditorCore').glob('*.swift')),
     '-emit-module-path', root / 'EditorCore.swiftmodule', '-o', root / 'libEditorCore.dylib'], 'core-build.log')
run([*common, '-parse-as-library', '-I', root, '-L', root, '-lEditorCore',
     sources / 'AVFoundationSequenceBackend.swift', sources / 'SystemStillPreview.swift', sources / 'SequencePlaybackController.swift',
     repo / 'scripts/system-sequence-matrix.swift', '-o', root / 'matrix'], 'matrix-build.log')
codecs = [
    ('prores-pcm', ['-c:v', 'prores_ks', '-profile:v', '0', '-pix_fmt', 'yuv422p10le', '-c:a', 'pcm_s16le']),
    ('h264-aac', ['-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-g', '24', '-bf', '3', '-c:a', 'aac']),
    ('hevc-closed-gop-aac', ['-c:v', 'libx265', '-pix_fmt', 'yuv420p', '-tag:v', 'hvc1', '-x265-params', 'pools=1:keyint=24:bframes=3:open-gop=0', '-c:a', 'aac'])]
if args.include_open_gop:
    codecs.append(('hevc-open-gop-aac', ['-c:v', 'libx265', '-pix_fmt', 'yuv420p', '-tag:v', 'hvc1',
        '-x265-params', 'pools=1:keyint=24:bframes=3:open-gop=1', '-c:a', 'aac']))
results = []
for numerator, denominator in [(24, 1), (24000, 1001), (30000, 1001), (60000, 1001)]:
    for codec, options in codecs:
        name = f'{codec}-{numerator}-{denominator}'
        fixture = root / f'{name}.mov'
        value = '32+192*mod(floor(N/pow(2,floor(X/16))),2)'
        run([args.ffmpeg, '-v', 'error', '-nostdin', '-n', '-f', 'lavfi', '-i',
             f'testsrc=size=128x64:rate={numerator}/{denominator},geq=r=\'{value}\':g=\'{value}\':b=\'{value}\'',
             '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=5',
             '-map', '0:v', '-map', '1:a', '-frames:v', '96', '-ac', '2', *options, fixture], name + '-generate.log')
        passed = True
        try:
            run([root / 'matrix', fixture, numerator, denominator], name + '-preview.log')
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            passed = False
        message = (root / (name + '-preview.log')).read_text().strip()
        print(message, flush=True)
        results.append({'case': name, 'passed': passed, 'decodedSeeks': 112 if passed else None,
                        'endClamp': passed, 'liveTransport': passed, 'observation': message,
                        'fixtureSHA256': hashlib.sha256(fixture.read_bytes()).hexdigest()})
        (root / 'results.json').write_text(json.dumps({'system': platform.platform(),
            'ffmpeg': (root / 'ffmpeg-version.txt').read_text().splitlines()[0], 'cases': results}, indent=2) + '\n')

if any(not result['passed'] for result in results):
    raise SystemExit('Preview qualification failed; inspect results.json and per-case logs')
