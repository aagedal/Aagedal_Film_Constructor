#!/usr/bin/env python3
"""Qualify ALAC through the native sequence runtime, actor cache and audio engine.

This optional development proof requires an existing passing render-plan barcode
fixture and explicit FFmpeg/pkg-config paths. It installs or bundles nothing.
The direct native-decoder-check.py matrix independently covers 44.1/48 kHz,
mono/stereo, 16/24-bit samples and exact ALAC packet-boundary seeks; this sequence
proof covers two mono ALAC source streams at 48 kHz in both qualified depths.
"""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
from urllib.parse import unquote, urlparse

from native_parity import compare_float_audio, compare_rgb, mpvkit_pin


# A fresh cache downloads every MPVKit binary artifact before building.
SWIFTPM_TIMEOUT = 1800


def digest(path):
    hasher = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            hasher.update(block)
    return hasher.hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('ffmpeg', 'fixture', 'output'):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    if not args.ffmpeg.is_absolute() or not os.access(args.ffmpeg, os.X_OK):
        parser.error('Supply an explicit absolute FFmpeg path')
    if not args.fixture.is_absolute() or not (args.fixture / 'result.json').is_file():
        parser.error('Fixture must be an absolute existing render-plan proof directory')
    proof = json.loads((args.fixture / 'result.json').read_text())
    if (proof.get('decodedVideoFrames'), proof.get('audioSamplesPerChannel'),
        proof.get('frameRate'), proof.get('audioActiveSamples')) != (180, 288288, '30000/1001', [48048, 240240]):
        parser.error('Fixture must be the completed 180-frame barcode render-plan proof')
    if not args.output.is_absolute() or args.output.exists():
        parser.error('Output must be a new absolute directory')
    args.output.mkdir(parents=True)
    root = args.output
    repo = Path(__file__).resolve().parent.parent
    env = os.environ.copy()
    env['CLANG_MODULE_CACHE_PATH'] = str(root / 'module-cache')
    env['SWIFTPM_MODULECACHE_OVERRIDE'] = str(root / 'module-cache')
    commands = []
    result = {'passed': False, 'variants': [], 'limitations': [
        'Development build statically linking the pinned MPVKit FFmpeg; no bundled/signed shipping dependency qualification',
        'Sequence runtime proof covers two mono ALAC source streams, 48 kHz, 16/24-bit only',
        'Offline native audio engine and image captures; no live display/CoreAudio synchronization or latency',
        'No lossy audio, resampling, offsets, gaps, codec delay/padding or general malformed-file qualification'
    ]}

    def run(command, log, capture=False, timeout=300):
        command = [str(item) for item in command]
        commands.append(command)
        completed = subprocess.run(command, env=env, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, timeout=timeout, check=False)
        (root / log).write_bytes(completed.stdout + completed.stderr)
        completed.check_returncode()
        return completed.stdout.decode().strip() if capture else None

    def ff(arguments, log):
        run([args.ffmpeg, '-hide_banner', '-nostdin', '-n', *arguments], log)

    try:
        identities = {'ffmpeg': {'path': str(args.ffmpeg), 'sha256': digest(args.ffmpeg),
            'version': run([args.ffmpeg, '-version'], 'ffmpeg-version.txt', capture=True)},
            'mpvkit': mpvkit_pin(repo)}
        source_files = [repo / 'scripts/native-alac-sequence-proof.py', repo / 'scripts/native_parity.py']
        for directory in (repo / 'Packages/NativePlaybackProof', repo / 'Packages/EditorCore'):
            source_files += [path for path in directory.rglob('*') if path.is_file() and
                '.build' not in path.parts and path.suffix in ('.swift', '.c', '.h', '.modulemap')]
        write_json(root / 'source-manifest.json', {str(path.relative_to(repo)): digest(path) for path in sorted(source_files)})
        run(['swift', 'build', '--package-path', repo / 'Packages/NativePlaybackProof',
            '--scratch-path', root / 'build', '--cache-path', root / 'cache', '--disable-sandbox'], 'build.log', timeout=SWIFTPM_TIMEOUT)
        native = root / 'build/debug/NativeSequenceProof'
        identities['nativeExecutable'] = {'path': str(native), 'sha256': digest(native)}
        write_json(root / 'identities.json', identities)
        project = json.loads((args.fixture / 'project.json').read_text())
        source = Path(unquote(urlparse(project['assets'][0]['originalURL']).path))
        if len(project['assets']) != 2 or source != args.fixture / 'a.mov':
            raise ValueError('Fixture must retain its original two-asset barcode source project')
        write_json(root / 'fixture-identities.json', {str(path): digest(path) for path in [
            source, args.fixture / 'b.mov', args.fixture / 'project.json', args.fixture / 'command.json',
            args.fixture / 'result.json', args.fixture / 'render.mov']})
        ff(['-i', args.fixture / 'render.mov', '-map', '0:v:0', '-fps_mode', 'passthrough',
            '-pix_fmt', 'rgb24', '-f', 'rawvideo', root / 'reference.rgb'], 'reference-video.log')
        ff(['-i', args.fixture / 'render.mov', '-map', '0:a:0', '-f', 's16le',
            root / 'reference.pcm'], 'reference-audio.log')
        rgb, pcm = (root / 'reference.rgb').read_bytes(), (root / 'reference.pcm').read_bytes()
        assert len(rgb) == 180 * 160 * 90 * 3 and len(pcm) == 288288 * 2 * 2
        for bits, sample_format in [(16, 's16p'), (24, 's32p')]:
            variant = root / f'alac-{bits}'
            variant.mkdir()
            encoded = variant / 'source.mov'
            ff(['-i', source, '-map', '0', '-c:v', 'copy', '-c:a', 'alac',
                '-sample_fmt', sample_format, encoded], f'alac-{bits}-encode.log')
            edited = copy.deepcopy(project)
            edited['assets'][0]['originalURL'] = encoded.as_uri()
            project_path = variant / 'project.json'
            write_json(project_path, edited)
            capture = variant / 'capture'
            run([native, project_path, capture], f'alac-{bits}-native.log')
            manifest = json.loads((capture / 'manifest.json').read_text())
            assert (manifest['videoFrames'], manifest['audioSamples'], manifest['sampleRate'], manifest['channels']) == (180, 288288, 48000, 2)
            assert manifest['asynchronousCacheBytes'] <= 128 * 1024 and manifest['asynchronousPendingRequests'] == 0
            checked = {'bits': bits, 'sourceSHA256': digest(encoded),
                'libraryVersion': manifest['libraryVersion'], 'audio': {}, 'video': {},
                'audioSeekRanges': [], 'videoSeekFrames': [],
                'asynchronousCacheBytes': manifest['asynchronousCacheBytes']}
            for name in ('mixed.f32', 'scheduled.f32', 'asynchronous.f32'):
                checked['audio'][name] = compare_float_audio((capture / name).read_bytes(), pcm, 2)
            for name in ('native.rgb', 'asynchronous.rgb'):
                checked['video'][name] = compare_rgb((capture / name).read_bytes(), rgb, 160 * 90 * 3)
            assert len(manifest['audioCaptures']) == 13 and manifest['audioCaptures'][-1]['rebuilt']
            for seek in manifest['audioCaptures']:
                start, count = seek['startSample'], seek['sampleCount']
                expected = pcm[start * 4:(start + count) * 4]
                for name in ('mixedFile', 'scheduledFile', 'asynchronousFile'):
                    compare_float_audio((capture / seek[name]).read_bytes(), expected, 2)
                checked['audioSeekRanges'].append([start, count, seek['rebuilt']])
            assert len(manifest['videoCaptures']) == 10 and manifest['videoCaptures'][-1]['rebuilt']
            for seek in manifest['videoCaptures']:
                start = seek['frame'] * 160 * 90 * 3
                for name in ('rgbFile', 'asynchronousFile'):
                    compare_rgb((capture / seek[name]).read_bytes(), rgb[start:start + 160 * 90 * 3], 160 * 90 * 3)
                checked['videoSeekFrames'].append(seek['frame'])
            result['variants'].append(checked)
        result['passed'] = True
    except Exception as error:
        result['failure'] = f'{type(error).__name__}: {error}'
        raise
    finally:
        write_json(root / 'commands.json', commands)
        write_json(root / 'result.json', result)
        print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
