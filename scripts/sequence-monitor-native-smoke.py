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
parser.add_argument('--package-runtime-notices', type=Path, help='Opt in to self-contained ad-hoc development packaging with explicit notices')
parser.add_argument('--package-runtime-provenance', type=Path, help='Explicit provenance required with --package-runtime-notices')
args = parser.parse_args()
if bool(args.package_runtime_notices) != bool(args.package_runtime_provenance):
    parser.error('Supply both packaging notices and provenance')
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
    str(repo / 'Aagedal Film Constructor/AVFoundationSequenceBackend.swift'),
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
proxy = root / 'proxy.nut'
# Distinct lossless picture makes accidental original decoding observable.
subprocess.run([str(args.ffmpeg), '-v', 'error', '-i', str(fixture), '-an',
    '-vf', 'negate', '-c:v', 'ffv1', '-pix_fmt', 'yuv420p', str(proxy)], check=True)
subprocess.run([str(args.ffmpeg), '-v', 'error', '-ss', '0.5', '-i', str(proxy),
    '-frames:v', '1', '-an', '-sws_flags', 'bilinear', '-pix_fmt', 'rgb24', '-f', 'rawvideo',
    str(root / 'proxy-seek.rgb')], check=True)
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

if args.package_runtime_notices:
    def package_app(source, destination):
        subprocess.run(['python3', str(repo / 'scripts/package-native-runtime.py'),
            '--app', str(source), '--output', str(destination), '--library-dir', str(binary),
            '--notices', str(args.package_runtime_notices), '--provenance', str(args.package_runtime_provenance)], check=True)

    # Exercise the production controller again from a bundle with every native
    # dependency relocated. Loader environment overrides are forbidden here.
    harness = root / 'Native Packaging Smoke.app'
    (harness / 'Contents/MacOS').mkdir(parents=True)
    import shutil
    shutil.copyfile(root / 'smoke', harness / 'Contents/MacOS/smoke')
    (harness / 'Contents/MacOS/smoke').chmod(0o755)
    with (harness / 'Contents/Info.plist').open('wb') as handle:
        plistlib.dump(dict(CFBundleExecutable='smoke', CFBundleIdentifier='com.aagedal.native-packaging-smoke',
            CFBundlePackageType='APPL', CFBundleVersion='1'), handle)
    packaged = root / 'Packaged Native Smoke.app'
    package_app(harness, packaged)
    clean_env = {key: value for key, value in os.environ.items() if not key.startswith('DYLD_')}
    clean_env['DYLD_PRINT_LIBRARIES'] = '1'
    with (root / 'packaged-smoke.log').open('w') as log:
        subprocess.run([str(packaged / 'Contents/MacOS/smoke'), str(fixture)],
            env=clean_env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60)
    loaded = (root / 'packaged-smoke.log').read_text()
    for line in loaded.splitlines():
        if line.startswith('dyld[') and (str(binary) in line or '/opt/homebrew/' in line or '/usr/local/' in line):
            raise RuntimeError('Packaged controller loaded a developer dependency: ' + line)
    if not any(line.startswith('dyld[') and '/Contents/Frameworks/libNativePlaybackRuntime.dylib' in line for line in loaded.splitlines()):
        raise RuntimeError('Missing actual bundled native-runtime loader observation')
    if 'Native app controller original/proxy frame parity/nonzero switching/exact seek/play/sample-clock/pause/edit/replay/deactivation smoke passed' not in loaded:
        raise RuntimeError('Missing packaged controller success observation')
    if args.build_workspace:
        package_app(app, root / 'Packaged Native Workspace.app')
    print('Self-contained native controller smoke passed with developer loader paths cleared.')
