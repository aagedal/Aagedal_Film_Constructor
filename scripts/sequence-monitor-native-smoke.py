#!/usr/bin/env python3
"""Opt-in app-controller qualification with explicitly selected development FFmpeg libraries.
Does not package libraries or establish acoustic/display timing acceptance.
"""
import argparse
import os
import plistlib
from pathlib import Path
import shlex
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--pkg-config', type=Path, required=True)
parser.add_argument('--ffmpeg', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--build-workspace', action='store_true', help='Also compile an isolated unsigned development app with enabled native sequence UI')
args = parser.parse_args()
for tool in [args.pkg_config, args.ffmpeg]:
    if not tool.is_absolute() or not os.access(tool, os.X_OK):
        parser.error('Supply explicit absolute executable paths')
root = args.output.absolute()
root.mkdir(parents=True, exist_ok=False)
repo = Path(__file__).resolve().parent.parent
env = os.environ.copy()
env['CLANG_MODULE_CACHE_PATH'] = str(root / 'module-cache')
env['SWIFTPM_MODULECACHE_OVERRIDE'] = str(root / 'module-cache')
env['PATH'] = str(args.pkg_config.parent) + os.pathsep + env.get('PATH', '')
flags = []
for option, forwarded in [('--cflags', '-Xcc'), ('--libs', '-Xlinker')]:
    for flag in shlex.split(subprocess.check_output([str(args.pkg_config), option, 'libavformat', 'libavcodec', 'libavutil', 'libswscale', 'libswresample'], text=True)):
        flags += [forwarded, flag]
build = root / 'build'
subprocess.run(['swift', 'build', '--package-path', str(repo / 'Packages/NativePlaybackProof'),
    '--scratch-path', str(build), '--cache-path', str(root / 'cache'), '--disable-sandbox',
    '--product', 'NativePlaybackRuntime', *flags], env=env, check=True)
binary = build / 'debug'
modulemap = root / 'native.modulemap'
header = repo / 'Packages/NativePlaybackProof/Sources/CNativeDecoder/include/CNativeDecoder.h'
modulemap.write_text('module CNativeDecoder { header "' + str(header) + '" export * }\n')
subprocess.run(['swiftc', '-swift-version', '6', '-default-isolation', 'MainActor',
    '-parse-as-library', '-module-cache-path', str(root / 'module-cache'),
    '-I', str(binary / 'Modules'), '-I', str(binary), '-I', str(repo / 'Packages/NativePlaybackProof/Sources/CNativeDecoder/include'),
    '-I', str(repo / 'Packages/NativePlaybackProof/Sources/CFFmpeg'),
    '-Xcc', '-fmodule-map-file=' + str(modulemap),
    '-L', str(binary), '-lNativePlaybackRuntime',
    str(repo / 'Aagedal Film Constructor/SequencePlaybackController.swift'),
    str(repo / 'scripts/sequence-monitor-native-smoke.swift'),
    '-o', str(root / 'smoke'), *flags], env=env, check=True)
fixture = root / 'fixture.nut'
subprocess.run([str(args.ffmpeg), '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=80x48:rate=24:duration=2',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=2',
    '-c:v', 'ffv1', '-pix_fmt', 'yuv420p', '-c:a', 'pcm_f32le', '-ac', '2', str(fixture)], check=True)
for seconds, name in [('0.5', 'seek.rgb'), ('1', 'edited.rgb')]:
    subprocess.run([str(args.ffmpeg), '-v', 'error', '-ss', seconds, '-i', str(fixture),
        '-frames:v', '1', '-an', '-sws_flags', 'bilinear', '-pix_fmt', 'rgb24', '-f', 'rawvideo', str(root / name)], check=True)
env['DYLD_LIBRARY_PATH'] = str(binary)
subprocess.run([str(root / 'smoke'), str(fixture)], env=env, check=True, timeout=60)

if args.build_workspace:
    app = root / 'Native Sequence Workspace.app'
    contents = app / 'Contents'
    macos = contents / 'MacOS'
    macos.mkdir(parents=True)
    executable = macos / 'NativeSequenceWorkspace'
    subprocess.run(['swiftc', '-swift-version', '5', '-default-isolation', 'MainActor',
        '-parse-as-library', '-module-cache-path', str(root / 'module-cache'),
        '-I', str(binary / 'Modules'), '-I', str(binary),
        '-Xcc', '-fmodule-map-file=' + str(modulemap),
        '-I', str(repo / 'Packages/NativePlaybackProof/Sources/CFFmpeg'),
        '-L', str(binary), '-lNativePlaybackRuntime',
        '-Xlinker', '-rpath', '-Xlinker', str(binary),
        *[str(p) for p in sorted((repo / 'Aagedal Film Constructor').glob('*.swift'))],
        '-o', str(executable), *flags], env=env, check=True)
    with (repo / 'Configuration/Info.plist').open('rb') as handle:
        info = plistlib.load(handle)
    info.update(CFBundleIdentifier='com.aagedal.filmconstructor.native-development',
        CFBundleExecutable=executable.name, CFBundleName='Native Sequence Workspace',
        CFBundlePackageType='APPL', CFBundleVersion='1', CFBundleShortVersionString='0.1',
        NSPrincipalClass='NSApplication')
    with (contents / 'Info.plist').open('wb') as handle:
        plistlib.dump(info, handle)
    print('Unsigned local development app only; runtime libraries remain at explicitly selected local paths.')
    print('Launch:', shlex.join(['open', '-n', '-a', str(app), str(root / 'fixture.afcproject')]))
    print('Select Sequence in the monitor; play/seek/edit controls use the production native adapter.')
