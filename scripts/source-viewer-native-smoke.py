#!/usr/bin/env python3
"""Source viewer with the pinned MPVKit runtime, through the app's EditorStore.

Imports AVFoundation-playable and FFmpeg-only fixtures, then checks backend selection,
frame-exact scrubbing/stepping/marks on FFmpeg's frame grid, playback, reverse, asset
switching, and proxy picture with the original's sound via libmpv.
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

# Luma encodes FFmpeg's frame index: Y = 16 + 4n.
indexed = lambda rate, size, seconds: ['-f', 'lavfi', '-i', f"nullsrc=s={size}:r={rate}:d={seconds},geq=lum='16+4*N':cb=128:cr=128"]
sine = lambda seconds: ['-f', 'lavfi', '-i', f'sine=frequency=440:sample_rate=48000:duration={seconds}']
FIXTURES = {
    'h264.mov': ['-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=25:duration=2'] + sine(2) + ['-c:v', 'libx264', '-c:a', 'pcm_s16le'],
    'ffv1-pcm.nut': indexed(25, '320x180', 2) + sine(2) + ['-c:v', 'ffv1', '-c:a', 'pcm_s16le', '-ac', '2'],
    'dnxhr-pcm.mxf': indexed(25, '640x360', 2) + sine(2) + ['-vf', 'format=yuv422p', '-c:v', 'dnxhd', '-profile:v', 'dnxhr_lb',
                                                             '-c:a', 'pcm_s16le'],
    'ffv1-2398.nut': indexed('24000/1001', '320x180', 2) + sine(2) + ['-c:v', 'ffv1', '-c:a', 'pcm_s24le'],
}
for name, arguments in FIXTURES.items():
    subprocess.run([str(args.ffmpeg), '-hide_banner', '-loglevel', 'error', *arguments, str(fixtures / name)], check=True)

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
# The same app sources as the store smokes (scripts/app-file-smoke.sh).
SOURCES = ['ProjectDocument', 'MediaImporter', 'MediaConversionService', 'SourcePlaybackBackend', 'EditorStore',
           'TitleRenderer', 'StabilisationService', 'StabilizationAnalyzer', 'NoiseReductionService',
           'AVFoundationSequenceBackend', 'CoreImageCompositor', 'AudioMeters', 'SystemStillPreview',
           'SequencePlaybackController', 'EditorExport', 'EditorQuickEdit', 'EditorProxy', 'EditorProxyQueue',
           'ProxyGenerationService', 'SequenceExportService', 'ShortcutBinding', 'EditorCommandRegistry']
subprocess.run([swiftc, '-sdk', sdk, '-parse-as-library', '-module-cache-path', str(root / 'module-cache'),
    '-I', str(binary / 'Modules'), '-I', str(binary), '-Xcc', '-fmodule-map-file=' + str(modulemap),
    '-L', str(binary), '-lNativePlaybackRuntime',
    *[str(app / f'{name}.swift') for name in SOURCES],
    str(repo / 'scripts/source-viewer-native-smoke.swift'), '-o', str(root / 'smoke')], env=env, check=True)
env['DYLD_LIBRARY_PATH'] = str(binary)
subprocess.run([str(root / 'smoke'), str(fixtures), str(args.ffmpeg), str(args.ffprobe)], env=env, check=True, timeout=300)
shutil.rmtree(build, ignore_errors=True)
shutil.rmtree(root / 'cache', ignore_errors=True)
