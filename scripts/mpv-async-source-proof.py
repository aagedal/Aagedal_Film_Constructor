#!/usr/bin/env python3
"""Qualify a private asynchronous MPV bridge from a Swift main-actor client.

Offline, explicit cached dependencies only. Null sinks; no app integration.
"""
import argparse
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import subprocess
import sys

spec = importlib.util.spec_from_file_location('source', Path(__file__).with_name('mpv-source-proof.py'))
source = importlib.util.module_from_spec(spec)
spec.loader.exec_module(source)

EXPORTS = {'_afc_mpv_bridge_' + name for name in
           ('create', 'open', 'seek', 'set_paused', 'poll', 'position', 'screenshot_rgb', 'close', 'destroy')}


def validate_report(report):
    if report.get('passed') is not True:
        raise ValueError('Swift client did not finish successfully')
    for key, minimum in {'cycles': 12, 'seeks': 60, 'rapidCommands': 36,
                         'rejections': 7, 'pendingCloses': 12, 'boundedReplies': 64,
                         'eofRecoveries': 1, 'disabledTypes': 2}.items():
        if not isinstance(report.get(key), int) or report[key] < minimum:
            raise ValueError('Incomplete Swift lifecycle coverage: ' + key)
    captures = report.get('captures', [])
    if len(captures) != report['seeks']:
        raise ValueError('Missing decoded seek captures')
    for capture in captures:
        target, actual = capture['target'], capture['position']
        if not math.isfinite(target) or not math.isfinite(actual) or abs(actual - target) > 1 / 24:
            raise ValueError('Seek position exceeds one frame')
        if capture['width'] != 320 or capture['height'] != 180:
            raise ValueError('Unexpected capture shape')


def run_proof(args):
    root = args.output
    root.mkdir(parents=True)
    result = {'passed': False, 'applicationIntegrated': False, 'coreAudioTested': False,
              'nativeDisplayTested': False, 'callbacksTested': False,
              'commands': [], 'comparisons': [],
              'limitations': ['Bounded polling on a Swift main actor; no foreign callbacks installed',
                              'Null sinks; color, decoded MPV audio, GPU, hardware sync and sandbox grants remain open',
                              'Private development bridge; no distribution or application backend selection']}

    def run(command, name, timeout=180):
        command = list(map(str, command))
        result['commands'].append({'name': name, 'argv': command})
        completed = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
        (root / (name + '.log')).write_bytes(completed.stdout)
        completed.check_returncode()
        return completed.stdout.decode()

    try:
        result['candidate'] = source.pinned_checkout(args.checkout)
        architecture = platform.machine()
        frameworks = [source.framework_slice(args.artifacts / name, architecture) for name in source.ARTIFACTS]
        result['frameworks'] = [{'artifact': name, 'binary': str(binary), 'sha256': source.digest(binary)}
                                for name, (_, binary) in zip(source.ARTIFACTS, frameworks)]
        scripts = Path(__file__).parent
        snapshot = root / 'sources'
        snapshot.mkdir()
        for name in ('mpv-source-bridge.h', 'mpv-source-bridge.c', 'mpv-async-source-proof.swift',
                     'mpv-async-source-proof.py', 'mpv-source-proof.py'):
            (snapshot / name).write_bytes((scripts / name).read_bytes())
        result['sourceHashes'] = {p.name: source.digest(p) for p in snapshot.iterdir()}
        exports = root / 'exports.txt'
        exports.write_text('\n'.join(sorted(EXPORTS)) + '\n')
        private = root / 'libAFCMPVSourceBridge.dylib'
        swiftc = Path(run(['/usr/bin/xcrun', '--find', 'swiftc'], 'swiftc-path').strip())
        sdk = run(['/usr/bin/xcrun', '--show-sdk-path'], 'sdk-path').strip()
        command = ['/usr/bin/clang', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2',
                   '-arch', architecture, '-mmacosx-version-min=27.0', '-dynamiclib',
                   '-Wl,-install_name,' + str(private), '-Wl,-exported_symbols_list,' + str(exports),
                   '-L', swiftc.parent.parent / 'lib/swift/macosx',
                   '-I', frameworks[0][0] / 'Headers', snapshot / 'mpv-source-bridge.c']
        if args.sanitize_address:
            command.extend(['-fsanitize=address', '-fno-omit-frame-pointer'])
        command.extend(binary for _, binary in frameworks)
        for name in source.FRAMEWORKS:
            command.extend(['-framework', name])
        command.extend('-l' + name for name in source.LIBRARIES)
        command.extend(['-o', private])
        run(command, 'compile-bridge')
        actual_exports = set(run(['/usr/bin/nm', '-gjU', private], 'exports').splitlines())
        if actual_exports != EXPORTS:
            raise ValueError('Private bridge exports unexpected symbols')
        result['exports'] = sorted(actual_exports)
        host = root / 'swift-source-client'
        swift_command = [swiftc, '-swift-version', '6', '-strict-concurrency=complete', '-parse-as-library',
             '-sdk', sdk,
             '-target', architecture + '-apple-macosx27.0', '-module-cache-path', root / 'module-cache',
             '-import-objc-header', snapshot / 'mpv-source-bridge.h',
             snapshot / 'mpv-async-source-proof.swift', private, '-o', host]
        if args.sanitize_address:
            swift_command.extend(['-sanitize=address'])
        result['addressSanitizer'] = args.sanitize_address
        run(swift_command, 'compile-swift')
        result['bridgeSHA256'] = source.digest(private)
        result['hostSHA256'] = source.digest(host)
        result['ffmpegSHA256'] = source.digest(args.ffmpeg)
        run(['/usr/bin/otool', '-L', private], 'bridge-linked-libraries')
        run([args.ffmpeg, '-version'], 'ffmpeg-version')
        fixture = root / 'source.mov'
        run([args.ffmpeg, '-hide_banner', '-nostdin', '-n', '-f', 'lavfi', '-i',
             'testsrc2=size=320x180:rate=24:duration=3,hue=s=0', '-f', 'lavfi', '-i',
             'sine=frequency=440:sample_rate=48000:duration=3', '-f', 'lavfi', '-i',
             'sine=frequency=880:sample_rate=48000:duration=3', '-map', '0:v', '-map', '1:a', '-map', '2:a',
             '-c:v', 'prores_ks', '-profile:v', '3', '-pix_fmt', 'yuv422p10le', '-c:a', 'pcm_s16le', fixture], 'generate')
        reordered = root / 'reordered.mkv'
        run([args.ffmpeg, '-v', 'error', '-nostdin', '-n', '-i', fixture, '-map', '0:1',
             '-map', '0:0', '-map', '0:2', '-c', 'copy', reordered], 'reorder')
        result['fixtureHashes'] = {p.name: source.digest(p) for p in (fixture, reordered)}
        run([host, fixture, reordered, root], 'swift-client')
        report = json.loads((root / 'swift-report.json').read_text())
        validate_report(report)
        result['swift'] = report
        references = {}
        for frame in (0, 36, 6, 48, 12):
            path = root / f'reference-{frame}.rgb'
            run([args.ffmpeg, '-v', 'error', '-nostdin', '-n', '-i', fixture, '-map', '0:0',
                 '-vf', f'select=eq(n\\,{frame})', '-frames:v', '1', '-pix_fmt', 'rgb24',
                 '-f', 'rawvideo', path], f'reference-{frame}')
            references[frame] = path.read_bytes()
        for capture in report['captures']:
            path = root / capture['file']
            if not path.resolve().is_relative_to(root.resolve()):
                raise ValueError('Capture escaped output root')
            comparison = source.compare_rgb(path.read_bytes(), references[round(capture['target'] * 24)], width=320)
            comparison['file'] = capture['file']
            result['comparisons'].append(comparison)
        if not all(c['passed'] for c in result['comparisons']):
            raise ValueError('Decoded async seek capture exceeded unchanged 3/32 RGB bounds')
        result['passed'] = True
    except Exception as error:
        result['error'] = str(error)
    finally:
        (root / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'passed': result['passed'], 'result': str(root / 'result.json'), 'error': result.get('error')}))
    return 0 if result['passed'] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sanitize-address', action='store_true',
                        help='Instrument the bridge and Swift client; cached dependency archives remain uninstrumented')
    for name in ('checkout', 'artifacts', 'ffmpeg', 'output'):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    for name in ('checkout', 'artifacts', 'ffmpeg', 'output'):
        if not getattr(args, name).is_absolute():
            parser.error(name + ' must be absolute')
    if not os.access(args.ffmpeg, os.X_OK):
        parser.error('ffmpeg must be an explicit executable')
    if args.output.exists() or any(args.output.resolve().is_relative_to(p.resolve()) for p in (args.checkout, args.artifacts)):
        parser.error('output must be a new directory outside dependency roots')
    return run_proof(args)


if __name__ == '__main__':
    sys.exit(main())
