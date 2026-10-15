#!/usr/bin/env python3
"""Offline MPVKit/static FFmpeg and native/dynamic FFmpeg coexistence proof.

Builds a private MPV dylib exporting only proof entry points. Builds and loads
NativePlaybackRuntime, exercising its CNativeDecoder in both load orders, concurrent decoded video/
audio and MPV lifecycle/seek capture. Does not integrate or package the app.
"""
import argparse
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import shlex
import subprocess

spec = importlib.util.spec_from_file_location('mpv_source', Path(__file__).with_name('mpv-source-proof.py'))
source = importlib.util.module_from_spec(spec)
spec.loader.exec_module(source)

LIBRARIES = ('avformat', 'avcodec', 'avutil', 'swresample', 'swscale')
MPV_EXPORTS = {'_afc_mpv_source_main', '_afc_mpv_dependencies'}


def exported_symbols(output):
    """nm -gjU emits exactly one externally defined symbol per line."""
    return {line.strip() for line in output.splitlines() if line.strip()}


def validate_bindings(report, mpv_image, native_versions):
    if report.get('passed') is not True or report.get('nativeIterations', 0) < 120:
        raise ValueError('Host did not complete decoded native checks')
    native = report.get('native', [])
    if [item['library'] for item in native] != list(LIBRARIES):
        raise ValueError('Incomplete native dependency binding set')
    for item in native:
        # Addresses must resolve to actual dylibs, never the statically bundled
        # copy or a linker stub in one of the proof bridges.
        if not Path(item['image']).name.startswith('lib' + item['library'] + '.') or not item['image'].endswith('.dylib'):
            raise ValueError('Native dependency bound to an unexpected image')
        if item['version'] != native_versions[item['library']]:
            raise ValueError('Native dependency version differs from selected pkg-config')
    if 'mpv' in report:
        overlap = report.get('nativeCompletionsDuringMPV', 0)
        if not 0 < overlap <= report['nativeIterations']:
            raise ValueError('No decoded native work completed during MPV execution')
        if report.get('hiddenAPIs') is not True or [item['library'] for item in report['mpv']] != list(LIBRARIES):
            raise ValueError('MPV API isolation failed')
        for item in report['mpv']:
            if Path(item['image']).resolve() != mpv_image.resolve():
                raise ValueError('MPV dependency escaped its private image')
        if all(m['version'] == n['version'] for m, n in zip(report['mpv'], native)):
            raise ValueError('This proof requires distinct FFmpeg dependency versions')


def version_integer(value):
    parts = value.strip().split('.')
    if len(parts) != 3 or any(not part.isdecimal() or not 0 <= int(part) <= 255 for part in parts):
        raise ValueError('Unexpected FFmpeg library version: ' + value)
    major, minor, micro = map(int, parts)
    return major << 16 | minor << 8 | micro


def run_proof(args):
    root = args.output
    root.mkdir(parents=True)
    result = {'passed': False, 'applicationIntegrated': False, 'coreAudioTested': False,
              'nativeDisplayTested': False, 'shippingRuntimeQualified': False,
              'commands': [], 'runs': [], 'limitations': [
                  'Private dylib experiment; app integration, GPU presentation and asynchronous callback lifetime remain open',
                  'Native audio is decoded PCM; MPV audio output uses a null sink',
                  'Local dependency bytes and bindings are recorded; redistribution, signing and sandbox grants remain open']}

    def run(command, name, timeout=180, env=None):
        command = [str(item) for item in command]
        result['commands'].append({'name': name, 'argv': command})
        completed = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, env=env)
        (root / (name + '.log')).write_bytes(completed.stdout + completed.stderr)
        completed.check_returncode()
        return completed.stdout.decode()

    try:
        result['candidate'] = source.pinned_checkout(args.checkout)
        architecture = platform.machine()
        frameworks = [source.framework_slice(args.artifacts / name, architecture) for name in source.ARTIFACTS]
        result['architecture'] = architecture
        result['frameworks'] = [{'artifact': name, 'binary': str(binary), 'sha256': source.digest(binary)}
                                for name, (_, binary) in zip(source.ARTIFACTS, frameworks)]
        repo = Path(__file__).resolve().parent.parent
        files = [Path(__file__), Path(__file__).with_suffix('.c'),
                 Path(__file__).with_name('mpv-coexistence-dependencies.c'),
                 Path(source.__file__), Path(source.__file__).with_suffix('.c')]
        for package in ('EditorCore', 'NativePlaybackProof'):
            package_root = repo / 'Packages' / package
            files += [package_root / 'Package.swift', *sorted(p for p in (package_root / 'Sources').rglob('*') if p.is_file())]
            files += sorted(p for p in (package_root / 'Tests').rglob('*') if p.is_file())
        result['sourceHashes'] = {}
        # Snapshot the exact source bytes used for this experiment.
        for path in files:
            target = root / 'sources' / path.relative_to(repo)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(path.read_bytes())
            result['sourceHashes'][str(path.relative_to(repo))] = source.digest(target)
        snapshot_scripts = root / 'sources/scripts'
        snapshot_bridge = root / 'sources/Packages/NativePlaybackProof/Sources/CNativeDecoder'
        dependency_probe = snapshot_scripts / 'mpv-coexistence-dependencies.c'
        private = root / 'libAFCMPVProof.dylib'
        exports = root / 'mpv-exports.txt'
        exports.write_text('\n'.join(sorted(MPV_EXPORTS)) + '\n')
        swiftc = Path(run(['/usr/bin/xcrun', '--find', 'swiftc'], 'swiftc-path').strip())
        command = ['/usr/bin/clang', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2',
                   '-arch', architecture, '-mmacosx-version-min=27.0', '-dynamiclib',
                   '-Wl,-install_name,' + str(private), '-Wl,-exported_symbols_list,' + str(exports),
                   '-L', swiftc.parent.parent / 'lib/swift/macosx',
                   '-I', frameworks[0][0] / 'Headers', '-Dmain=afc_mpv_source_main',
                   '-DAFC_PROBE_NAME=afc_mpv_dependencies',
                   snapshot_scripts / 'mpv-source-proof.c', dependency_probe]
        command.extend(binary for _, binary in frameworks)
        for name in source.FRAMEWORKS:
            command.extend(['-framework', name])
        command.extend('-l' + name for name in source.LIBRARIES)
        command.extend(['-o', private])
        run(command, 'compile-mpv')
        symbols = exported_symbols(run(['/usr/bin/nm', '-gjU', private], 'mpv-exports'))
        result['mpvExports'] = sorted(symbols)
        if symbols != MPV_EXPORTS:
            raise ValueError('Private MPV dylib exports unexpected or missing symbols')
        native = root / 'libAFCNativeProof.dylib'
        packages = ['lib' + name for name in LIBRARIES]
        cflags = shlex.split(run([args.pkg_config, '--cflags', *packages], 'native-cflags'))
        ldflags = shlex.split(run([args.pkg_config, '--libs', *packages], 'native-libs'))
        versions = run([args.pkg_config, '--modversion', *packages], 'native-versions').splitlines()
        if len(versions) != len(LIBRARIES):
            raise ValueError('Missing pkg-config versions')
        native_versions = dict(zip(LIBRARIES, map(version_integer, versions)))
        result['nativeVersions'] = native_versions
        build_env = os.environ.copy()
        build_env['PATH'] = str(args.pkg_config.parent) + os.pathsep + build_env.get('PATH', '')
        build_env['PKG_CONFIG'] = str(args.pkg_config)
        build_env['CLANG_MODULE_CACHE_PATH'] = str(root / 'module-cache')
        build_env['SWIFTPM_MODULECACHE_OVERRIDE'] = str(root / 'module-cache')
        flags = [value for flag in cflags for value in ('-Xcc', flag)]
        flags += [value for flag in ldflags for value in ('-Xlinker', flag)]
        build_command = [swiftc.with_name('swift'), 'build', '--package-path', snapshot_bridge.parent.parent,
                         '--scratch-path', root / 'native-build', '--cache-path', root / 'native-cache',
                         '--disable-sandbox', '--triple', architecture + '-apple-macosx27.0',
                         '--product', 'NativePlaybackRuntime', *flags]
        run(build_command, 'build-native-runtime', timeout=300, env=build_env)
        products = Path(run([*build_command, '--show-bin-path'], 'native-bin-path', env=build_env).strip())
        runtime = products / 'libNativePlaybackRuntime.dylib'
        result['nativeRuntimeSHA256'] = source.digest(runtime)
        run(['/usr/bin/otool', '-L', runtime], 'native-runtime-linked-libraries')
        run(['/usr/bin/clang', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2',
             '-arch', architecture, '-mmacosx-version-min=27.0', '-dynamiclib',
             '-Wl,-install_name,' + str(native), '-Wl,-rpath,' + str(products),
             '-DAFC_PROBE_NAME=afc_native_dependencies',
             '-I', snapshot_bridge / 'include', *cflags,
             dependency_probe, runtime, *ldflags, '-o', native], 'compile-native')
        host = root / 'coexistence-host'
        run(['/usr/bin/clang', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2',
             '-arch', architecture, '-mmacosx-version-min=27.0', '-I', snapshot_bridge / 'include',
             snapshot_scripts / 'mpv-coexistence-proof.c', '-o', host], 'compile-host')
        for name, binary in [('mpv', private), ('native', native), ('host', host)]:
            result[name + 'SHA256'] = source.digest(binary)
            run(['/usr/bin/otool', '-L', binary], name + '-linked-libraries')
        result['helperHashes'] = {name: source.digest(getattr(args, name)) for name in ('ffmpeg', 'pkg_config')}
        run([args.ffmpeg, '-version'], 'ffmpeg-version')
        fixture = root / 'source.mov'
        run([args.ffmpeg, '-hide_banner', '-nostdin', '-n', '-f', 'lavfi', '-i',
             'testsrc2=size=320x180:rate=24:duration=3,hue=s=0', '-f', 'lavfi', '-i',
             'sine=frequency=440:sample_rate=48000:duration=3', '-f', 'lavfi', '-i',
             'sine=frequency=880:sample_rate=48000:duration=3', '-map', '0:v', '-map', '1:a', '-map', '2:a',
             '-c:v', 'prores_ks', '-profile:v', '3', '-pix_fmt', 'yuv422p10le', '-c:a', 'pcm_s16le', fixture], 'generate')
        result['fixtureSHA256'] = source.digest(fixture)
        # Independently decode native outputs. RGB compares byte-for-byte to
        # native-only; sample output also compares exactly to external FFmpeg.
        audio_reference = root / 'reference.f32'
        run([args.ffmpeg, '-v', 'error', '-nostdin', '-n', '-i', fixture, '-map', '0:2',
             '-f', 'f32le', '-acodec', 'pcm_f32le', audio_reference], 'reference-audio')
        reference_frames = {}
        for frame in (0, 36, 6, 48, 12):
            path = root / f'reference-{frame}.rgb'
            run([args.ffmpeg, '-v', 'error', '-nostdin', '-n', '-i', fixture, '-map', '0:0',
                 '-vf', f'select=eq(n\\,{frame})', '-frames:v', '1', '-pix_fmt', 'rgb24', '-f', 'rawvideo', path],
                f'reference-video-{frame}')
            reference_frames[frame] = path.read_bytes()
        audio_bytes = audio_reference.read_bytes()
        expected_audio = b''.join(audio_bytes[frame * 2000 * 4:(frame * 2000 + 1024) * 4]
                                  for frame in (0, 36, 6, 48, 12)) * 24
        if len(expected_audio) != 120 * 1024 * 4:
            raise ValueError('Incomplete independent audio reference')
        baseline = None
        for mode in ('native-only', 'mpv-first', 'native-first'):
            output = root / mode
            output.mkdir()
            run([host, private, native, fixture, output, mode], mode)
            report = json.loads((output / 'bindings.json').read_text())
            validate_bindings(report, private, native_versions)
            item = {'mode': mode, 'bindings': report}
            result['runs'].append(item)
            picture, sound = (output / 'native.rgb').read_bytes(), (output / 'native.f32').read_bytes()
            if len(picture) != 120 * 320 * 180 * 3 or sound != expected_audio:
                raise ValueError('Native output length/audio samples differ from independent reference')
            if baseline is None:
                baseline = picture
                item['referenceVideoComparisons'] = [source.compare_rgb(
                    picture[i * 320 * 180 * 3:(i + 1) * 320 * 180 * 3], reference_frames[frame])
                    for i, frame in enumerate((0, 36, 6, 48, 12))]
                if not all(c['passed'] for c in item['referenceVideoComparisons']):
                    raise ValueError('Standalone native video differs from independent reference')
            elif picture != baseline:
                raise ValueError('Concurrent native video differs from standalone bytes')
            item['nativeVideoSHA256'] = source.digest(output / 'native.rgb')
            item['nativeAudioSHA256'] = source.digest(output / 'native.f32')
            # Record the bytes actually supplying the dynamic native APIs.
            item['nativeDependencyHashes'] = {b['image']: source.digest(Path(b['image'])) for b in report['native']}
            if mode == 'native-only':
                continue
            playback = json.loads((output / 'mpv/report.json').read_text())
            item['mpvReport'] = playback
            item['mpvComparisons'] = []
            if playback.get('passed') is not True or len(playback['cycles']) != 4:
                raise ValueError('MPV lifecycle failed during native decoding')
            for cycle in playback['cycles']:
                if [c['targetSeconds'] for c in cycle['captures']] != [0, 1.5, 0.25, 2, 0.5]:
                    raise ValueError('MPV capture set is incomplete')
                for capture in cycle['captures']:
                    target = capture['targetSeconds']
                    if not math.isfinite(capture['timePosition']) or abs(target - capture['timePosition']) > 1 / 24:
                        raise ValueError('Concurrent MPV seek differs by more than one frame')
                    path = output / 'mpv' / capture['file']
                    if not path.resolve().is_relative_to((output / 'mpv').resolve()):
                        raise ValueError('Capture escaped output directory')
                    comparison = source.compare_rgb(path.read_bytes(), reference_frames[round(target * 24)])
                    item['mpvComparisons'].append(comparison)
            if not all(c['passed'] for c in item['mpvComparisons']):
                raise ValueError('Concurrent MPV capture exceeded unchanged 3/32 RGB bounds')
        result['passed'] = True
    except Exception as error:
        result['error'] = str(error)
    finally:
        (root / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'passed': result['passed'], 'result': str(root / 'result.json'), 'error': result.get('error')}))
    return 0 if result['passed'] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('checkout', 'artifacts', 'ffmpeg', 'pkg_config', 'output'):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    for name in ('checkout', 'artifacts', 'ffmpeg', 'pkg_config', 'output'):
        if not getattr(args, name).is_absolute():
            parser.error(name + ' must be absolute')
    for name in ('ffmpeg', 'pkg_config'):
        if not os.access(getattr(args, name), os.X_OK):
            parser.error(name + ' must be an explicit executable')
    if args.output.exists():
        parser.error('Output must be a new directory')
    return run_proof(args)


if __name__ == '__main__':
    raise SystemExit(main())
