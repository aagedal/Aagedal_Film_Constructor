#!/usr/bin/env python3
"""FFmpeg import probe qualification with the pinned MPVKit runtime.

Compares MediaImporter.inspectNative with AVFoundation inspect on media both read,
checks exact probe values and unconverted-import admission on media only FFmpeg reads
(falling back to conversion otherwise), then plays and exports unconverted originals.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--ffmpeg', type=Path, default=Path('/opt/homebrew/bin/ffmpeg'))
parser.add_argument('--ffprobe', type=Path, default=Path('/opt/homebrew/bin/ffprobe'))
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
for tool in (args.ffmpeg, args.ffprobe):
    if not tool.is_absolute() or not os.access(tool, os.X_OK):
        parser.error(f'{tool} must be an explicit absolute executable')
root = args.output.absolute()
root.mkdir(parents=True, exist_ok=False)
repo = Path(__file__).resolve().parent.parent
env = os.environ.copy()
env['CLANG_MODULE_CACHE_PATH'] = str(root / 'module-cache')
env['SWIFTPM_MODULECACHE_OVERRIDE'] = str(root / 'module-cache')
fixtures = root / 'fixtures'
fixtures.mkdir()

video = lambda rate, size='320x180', seconds=2: ['-f', 'lavfi', '-i', f'testsrc2=size={size}:rate={rate}:duration={seconds}']
sine = lambda seconds=2, rate=48000: ['-f', 'lavfi', '-i', f'sine=frequency=440:sample_rate={rate}:duration={seconds}']
FIXTURES = {
    # Both AVFoundation and FFmpeg read these.
    'h264-24-pcm.mov': video(24) + sine() + ['-c:v', 'libx264', '-c:a', 'pcm_s16le', '-ac', '2'],
    'prores-23976-aac51-tc.mov': video('24000/1001', seconds=1) + sine(1) + ['-c:v', 'prores_ks', '-c:a', 'aac', '-ac', '6', '-timecode', '01:00:00:00'],
    'h264-2997-aac-tc.mp4': video('30000/1001', seconds=1) + sine(1, 44100) + ['-c:v', 'libx264', '-c:a', 'aac', '-timecode', '00:59:59:28'],
    'h264-2997-df-tc.mov': video('30000/1001', seconds=1) + sine(1) + ['-c:v', 'libx264', '-c:a', 'pcm_s16le', '-timecode', '00:59:59;28'],
    'ffv1-pcm51.mov': video(24, seconds=1) + sine(1) + ['-c:v', 'ffv1', '-c:a', 'pcm_s16le', '-ac', '6'],
    'dnxhr-50.mov': video(50, seconds=1) + ['-c:v', 'dnxhd', '-profile:v', 'dnxhr_lb', '-pix_fmt', 'yuv422p'],
    'mono.wav': sine(1.5) + ['-c:a', 'pcm_s16le'],
    'stereo.flac': sine(1.5) + ['-c:a', 'flac', '-ac', '2'],
    'offset-audio.mov': video(25) + ['-itsoffset', '0.5'] + sine(1) + ['-map', '0', '-map', '1', '-c:v', 'libx264', '-c:a', 'pcm_s24le'],
    'stereo.m4a': sine(1.5) + ['-c:a', 'aac', '-ac', '2'],
    'mono.opus': sine(1.5) + ['-c:a', 'libopus'],
    # Only FFmpeg reads these.
    'ffv1-pcm.nut': video(24) + sine() + ['-c:v', 'ffv1', '-c:a', 'pcm_s16le', '-ac', '2'],
    'utvideo-pcm6.nut': video(25) + sine() + ['-c:v', 'utvideo', '-c:a', 'pcm_s24le', '-ac', '6'],
    'dnxhr-tc.mxf': video(25, '640x360') + sine() + ['-c:v', 'dnxhd', '-profile:v', 'dnxhr_lb', '-pix_fmt', 'yuv422p',
                                                     '-c:a', 'pcm_s16le', '-timecode', '10:00:00:00'],
    'ffv1-25-pcm.mkv': video(25) + sine() + ['-c:v', 'ffv1', '-c:a', 'pcm_s16le'],
    'ffv1-24.mkv': video(24) + ['-c:v', 'ffv1'],
    'ffv1-offset-audio.nut': video(24) + ['-itsoffset', '0.5'] + sine(1) + ['-map', '0', '-map', '1', '-c:v', 'ffv1', '-c:a', 'pcm_s16le'],
    'ffv1-opus.mkv': video(24) + sine() + ['-c:v', 'ffv1', '-c:a', 'libopus'],
}
for name, arguments in FIXTURES.items():
    subprocess.run([str(args.ffmpeg), '-hide_banner', '-loglevel', 'error', *arguments, str(fixtures / name)], check=True)
# The listing prepare-media-helpers.py bundles as Helpers/decoders.txt.
(fixtures / 'helper-decoders.txt').write_text(subprocess.check_output([str(args.ffmpeg), '-hide_banner', '-decoders'], text=True))

# Xcode's toolchain and SDK for both the package and the harness, never another swift on PATH.
xcrun = lambda *arguments: subprocess.check_output(['/usr/bin/xcrun', *arguments], text=True).strip()
swift, swiftc, sdk = xcrun('--find', 'swift'), xcrun('--find', 'swiftc'), xcrun('--show-sdk-path')
env['SDKROOT'] = sdk
build = root / 'build'
subprocess.run([swift, 'build', '--sdk', sdk, '--package-path', str(repo / 'Packages/NativePlaybackProof'),
    '--scratch-path', str(build), '--cache-path', str(root / 'cache'), '--disable-sandbox',
    '--product', 'NativePlaybackRuntime'], env=env, check=True)
binary = build / 'debug'
modulemap = root / 'native.modulemap'
header = repo / 'Packages/NativePlaybackProof/Sources/CNativeDecoder/include/CNativeDecoder.h'
modulemap.write_text('module CNativeDecoder { header "' + str(header) + '" export * }\n')
app = repo / 'Aagedal Film Constructor'
subprocess.run([swiftc, '-sdk', sdk, '-swift-version', '6', '-default-isolation', 'MainActor',
    '-parse-as-library', '-module-cache-path', str(root / 'module-cache'),
    '-I', str(binary / 'Modules'), '-I', str(binary), '-Xcc', '-fmodule-map-file=' + str(modulemap),
    '-L', str(binary), '-lNativePlaybackRuntime',
    str(app / 'MediaImporter.swift'), str(app / 'MediaConversionService.swift'), str(app / 'SequenceExportService.swift'),
    str(repo / 'scripts/native-import-probe-smoke.swift'), '-o', str(root / 'smoke')], env=env, check=True)
env['DYLD_LIBRARY_PATH'] = str(binary)
subprocess.run([str(root / 'smoke'), str(fixtures), str(args.ffmpeg), str(args.ffprobe)], env=env, check=True, timeout=300)
shutil.rmtree(build, ignore_errors=True)
shutil.rmtree(root / 'cache', ignore_errors=True)
