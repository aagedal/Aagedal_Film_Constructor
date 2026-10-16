#!/usr/bin/env python3
"""Offline qualification of private asynchronous MPV with Swift native sessions."""
import argparse
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import shlex
import subprocess

spec = importlib.util.spec_from_file_location('async_source', Path(__file__).with_name('mpv-async-source-proof.py'))
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)
source = bridge.source


def validate_report(report, concurrent):
    if report.get('passed') is not True or report.get('closedAdmissionRejected') is not True:
        raise ValueError('Swift coordination did not complete')
    for key, count in [('cycles', 12), ('replacements', 12), ('oldEpochRejections', 11)]:
        if report.get(key) != count:
            raise ValueError('Incomplete coordination coverage: ' + key)
    native = report.get('native', [])
    expected = [frame + (6 if cycle % 2 else 0) for cycle in range(12)
                for frame in [0, 36, 6, 48, 12] * 2]
    if [row['sourceFrame'] for row in native] != expected:
        raise ValueError('Incomplete native frame/audio requests')
    if len({row['file'] for row in native}) != 120:
        raise ValueError('Duplicate native output')
    if any(not math.isfinite(row['completed']) for row in native):
        raise ValueError('Invalid native completion timestamp')
    if not concurrent:
        if report.get('captures') or report.get('windows'):
            raise ValueError('Native baseline unexpectedly ran MPV')
        return
    captures, windows = report.get('captures', []), report.get('windows', [])
    if len(windows) != 12 or len(captures) != 60 or len({c['file'] for c in captures}) != 60:
        raise ValueError('Incomplete concurrent MPV coverage')
    if [c['target'] for c in captures] != [0, 1.5, .25, 2, .5] * 12:
        raise ValueError('Incomplete MPV seek coordinates')
    for capture in captures:
        if not math.isfinite(capture['position']) or abs(capture['position'] - capture['target']) > 1 / 24:
            raise ValueError('MPV seek position exceeds one frame')
    for cycle, window in enumerate(windows):
        start, end = window['start'], window['end']
        if not math.isfinite(start) or not math.isfinite(end) or end <= start:
            raise ValueError('Invalid MPV execution window')
        if not any(start <= row['completed'] <= end for row in native[cycle * 10:(cycle + 1) * 10]):
            raise ValueError('Native requests did not complete during MPV execution')


def run_proof(args):
    root = args.output
    root.mkdir(parents=True)
    result = {'passed': False, 'applicationIntegrated': False, 'coreAudioTested': False,
              'nativeDisplayTested': False, 'commands': [], 'runs': [],
              'limitations': ['Null MPV sinks; no decoded MPV audio, GPU, hardware sync or color qualification',
                              'Development dependency selection; no release signing, redistribution or sandbox qualification',
                              'Finite concurrent session exercise; earlier C proof covers dependency load orders']}

    def run(command, name, timeout=180, env=None):
        command = list(map(str, command))
        result['commands'].append({'name': name, 'argv': command})
        completed = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   timeout=timeout, env=env)
        (root / (name + '.log')).write_bytes(completed.stdout)
        completed.check_returncode()
        return completed.stdout.decode()

    try:
        # Rebuild and qualify the exact bridge rather than borrowing old binaries.
        nested = argparse.Namespace(**vars(args))
        nested.output = root / 'bridge'
        if bridge.run_proof(nested):
            raise ValueError('Asynchronous bridge prerequisite failed')
        result['bridgeResult'] = json.loads((nested.output / 'result.json').read_text())
        repo = Path(__file__).resolve().parent.parent
        snapshot = root / 'sources'
        files = [Path(__file__), Path(__file__).with_suffix('.swift'),
                 Path(__file__).with_name('mpv-async-source-proof.swift')]
        for package in ('EditorCore', 'NativePlaybackProof'):
            package_root = repo / 'Packages' / package
            files += [package_root / 'Package.swift',
                      *sorted(p for p in (package_root / 'Sources').rglob('*') if p.is_file()),
                      *sorted(p for p in (package_root / 'Tests').rglob('*') if p.is_file())]
        for path in files:
            target = snapshot / path.relative_to(repo)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(path.read_bytes())
        result['sourceHashes'] = {str(p.relative_to(snapshot)): source.digest(p)
                                  for p in snapshot.rglob('*') if p.is_file()}
        swiftc = Path(run(['/usr/bin/xcrun', '--find', 'swiftc'], 'swiftc-path').strip())
        sdk = run(['/usr/bin/xcrun', '--show-sdk-path'], 'sdk-path').strip()
        architecture = platform.machine()
        libraries = ['lib' + name for name in ('avformat', 'avcodec', 'avutil', 'swresample', 'swscale')]
        cflags = shlex.split(run([args.pkg_config, '--cflags', *libraries], 'native-cflags'))
        ldflags = shlex.split(run([args.pkg_config, '--libs', *libraries], 'native-libs'))
        run([args.pkg_config, '--modversion', *libraries], 'native-versions')
        env = os.environ.copy()
        env['PATH'] = str(args.pkg_config.parent) + os.pathsep + env.get('PATH', '')
        env['PKG_CONFIG'] = str(args.pkg_config)
        env['CLANG_MODULE_CACHE_PATH'] = str(root / 'module-cache')
        env['SWIFTPM_MODULECACHE_OVERRIDE'] = str(root / 'module-cache')
        flags = [v for flag in cflags for v in ('-Xcc', flag)]
        flags += [v for flag in ldflags for v in ('-Xlinker', flag)]
        build = [swiftc.with_name('swift'), 'build', '--package-path', snapshot / 'Packages/NativePlaybackProof',
                 '--scratch-path', root / 'native-build', '--cache-path', root / 'native-cache',
                 '--disable-sandbox', '--triple', architecture + '-apple-macosx27.0',
                 '--product', 'NativePlaybackRuntime', *flags]
        if args.sanitize_address:
            build += ['--sanitize', 'address']
        run(build, 'build-native', timeout=300, env=env)
        products = Path(run([*build, '--show-bin-path'], 'native-bin-path', env=env).strip().splitlines()[-1])
        runtime = products / 'libNativePlaybackRuntime.dylib'
        private = nested.output / 'libAFCMPVSourceBridge.dylib'
        host = root / 'swift-coexistence-client'
        command = [swiftc, '-swift-version', '6', '-strict-concurrency=complete', '-parse-as-library',
                   '-D', 'AFC_NATIVE_COEXISTENCE', '-sdk', sdk, '-target', architecture + '-apple-macosx27.0',
                   '-module-cache-path', root / 'module-cache', '-I', products, '-I', products / 'Modules',
                   '-I', root / 'native-build/out/Intermediates.noindex/GeneratedModuleMaps',
                   '-I', products / 'CNativeDecoder.build',
                   '-I', snapshot / 'Packages/NativePlaybackProof/Sources/CFFmpeg',
                   '-import-objc-header', nested.output / 'sources/mpv-source-bridge.h',
                   snapshot / 'scripts/mpv-async-source-proof.swift',
                   snapshot / 'scripts/mpv-swift-coexistence-proof.swift',
                   private, runtime, '-Xlinker', '-rpath', '-Xlinker', products, *flags, '-o', host]
        generated_map = root / 'native-build/out/Intermediates.noindex/GeneratedModuleMaps/CNativeDecoder.modulemap'
        if generated_map.is_file():
            command += ['-Xcc', '-fmodule-map-file=' + str(generated_map)]
        if args.sanitize_address:
            command += ['-sanitize=address']
        run(command, 'compile-host')
        result['addressSanitizer'] = args.sanitize_address
        result['runtimeSHA256'] = source.digest(runtime)
        result['hostSHA256'] = source.digest(host)
        result['pkgConfigSHA256'] = source.digest(args.pkg_config)
        linked = run(['/usr/bin/otool', '-L', runtime], 'runtime-linked-libraries')
        dependencies = [Path(line.strip().split(' (')[0]) for line in linked.splitlines()[1:]]
        result['nativeDependencyHashes'] = {str(p): source.digest(p) for p in dependencies
                                             if p.name.startswith(('libav', 'libsw')) and p.is_file()}
        run(['/usr/bin/otool', '-L', host], 'host-linked-libraries')
        fixture = nested.output / 'source.mov'
        audio = root / 'reference.f32'
        run([args.ffmpeg, '-v', 'error', '-nostdin', '-n', '-i', fixture, '-map', '0:2',
             '-f', 'f32le', '-acodec', 'pcm_f32le', audio], 'reference-audio')
        audio_bytes = audio.read_bytes()
        references = {}
        for frame in (0, 6, 12, 18, 36, 42, 48, 54):
            path = root / f'reference-{frame}.rgb'
            run([args.ffmpeg, '-v', 'error', '-nostdin', '-n', '-i', fixture, '-map', '0:0',
                 '-vf', f'select=eq(n\\,{frame})', '-frames:v', '1', '-pix_fmt', 'rgb24',
                 '-f', 'rawvideo', path], f'reference-{frame}')
            references[frame] = path.read_bytes()
        baseline = {}
        for mode in ('native-only', 'concurrent'):
            output = root / mode
            output.mkdir()
            run([host, fixture, output, mode], mode)
            report = json.loads((output / 'report.json').read_text())
            validate_report(report, mode == 'concurrent')
            item = {'mode': mode, 'report': report, 'nativeComparisons': [], 'mpvComparisons': []}
            result['runs'].append(item)
            for row in report['native']:
                frame = row['sourceFrame']
                for suffix in ('.rgb', '.f32'):
                    path = output / (row['file'] + suffix)
                    if not path.resolve().is_relative_to(output.resolve()):
                        raise ValueError('Native output escaped root')
                    data = path.read_bytes()
                    if suffix == '.f32':
                        if data != audio_bytes[frame * 2000 * 4:(frame * 2000 + 1024) * 4]:
                            raise ValueError('Native samples differ from independent FFmpeg')
                    else:
                        comparison = source.compare_rgb(data, references[frame])
                        item['nativeComparisons'].append(comparison)
                        if not comparison['passed']:
                            raise ValueError('Native picture exceeded unchanged RGB bounds')
                    key = row['file'] + suffix
                    if mode == 'native-only':
                        baseline[key] = data
                    elif data != baseline[key]:
                        raise ValueError('Concurrent native output differs from standalone Swift session')
            for capture in report['captures']:
                path = output / capture['file']
                if not path.resolve().is_relative_to(output.resolve()):
                    raise ValueError('MPV output escaped root')
                comparison = source.compare_rgb(path.read_bytes(), references[round(capture['target'] * 24)])
                item['mpvComparisons'].append(comparison)
                if not comparison['passed']:
                    raise ValueError('Concurrent MPV picture exceeded unchanged RGB bounds')
        result['passed'] = True
    except Exception as error:
        result['error'] = str(error)
    finally:
        (root / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'passed': result['passed'], 'result': str(root / 'result.json'), 'error': result.get('error')}))
    return 0 if result['passed'] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sanitize-address', action='store_true')
    for name in ('checkout', 'artifacts', 'ffmpeg', 'pkg_config', 'output'):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    for name in ('checkout', 'artifacts', 'ffmpeg', 'pkg_config', 'output'):
        if not getattr(args, name).is_absolute():
            parser.error(name + ' must be absolute')
    for name in ('ffmpeg', 'pkg_config'):
        if not os.access(getattr(args, name), os.X_OK):
            parser.error(name + ' must be an explicit executable')
    if args.output.exists() or any(args.output.resolve().is_relative_to(p.resolve()) for p in (args.checkout, args.artifacts)):
        parser.error('output must be a new directory outside dependency roots')
    return run_proof(args)


if __name__ == '__main__':
    raise SystemExit(main())
