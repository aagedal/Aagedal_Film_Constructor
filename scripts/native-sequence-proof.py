#!/usr/bin/env python3
"""Build/evaluate the development FFmpeg bridge and native image/audio output.

Requires an existing passing render-plan barcode fixture, explicit helpers, and
locally installed FFmpeg headers/libraries. No packages are installed or shipped.
"""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import uuid
from urllib.parse import unquote, urlparse

from native_parity import compare_float_audio, compare_rgb


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ffmpeg', type=Path)
    parser.add_argument('ffprobe', type=Path)
    parser.add_argument('pkg_config', type=Path)
    parser.add_argument('fixture', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    for executable in (args.ffmpeg, args.ffprobe, args.pkg_config):
        if not executable.is_absolute() or not os.access(executable, os.X_OK):
            parser.error('Supply explicit absolute executable paths')
    if not args.fixture.is_absolute() or not (args.fixture / 'result.json').is_file():
        parser.error('Fixture must be an absolute existing render-plan proof directory')
    fixture_result = json.loads((args.fixture / 'result.json').read_text())
    if (fixture_result.get('decodedVideoFrames'), fixture_result.get('audioSamplesPerChannel'),
        fixture_result.get('frameRate'), fixture_result.get('audioActiveSamples')) != (180, 288288, '30000/1001', [48048, 240240]):
        parser.error('Fixture must be the completed 180-frame barcode render-plan proof')
    if not args.output.is_absolute() or args.output.exists():
        parser.error('Output must be a new absolute directory')
    args.output.mkdir(parents=True)
    root = args.output
    repo = Path(__file__).resolve().parent.parent
    result = {'passed': False, 'variants': [], 'limitations': [
        'Development dynamically linked libraries, no bundled/signed distribution',
        'Matching-raster square-pixel SDR CFR video and matching-rate PCM audio only',
        'Native CGImage/PNG captures and offline AVAudioEngine; no live display/CoreAudio A/V sync',
        'No scaling/color/VFR conformance, compressed audio/resampling, fades/crossfades or proxies',
        'First source access qualifies all selected-stream timestamps; launch/interactive performance unmeasured'
    ]}
    commands = []
    env = os.environ.copy()
    # SwiftPM's pkg-config must resolve the supplied tool, not an unrelated helper.
    env['PATH'] = str(args.pkg_config.parent) + os.pathsep + env.get('PATH', '')
    env['CLANG_MODULE_CACHE_PATH'] = str(root / 'module-cache')
    env['SWIFTPM_MODULECACHE_OVERRIDE'] = str(root / 'module-cache')

    def run(command, log, timeout=300, capture=False):
        command = [str(x) for x in command]
        commands.append(command)
        if capture:
            completed = subprocess.run(command, env=env, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, check=True, timeout=timeout)
            (root / log).write_bytes(completed.stdout + completed.stderr)
            return completed.stdout.decode().strip()
        with (root / log).open('wb') as stream:
            subprocess.run(command, env=env, stdout=stream, stderr=subprocess.STDOUT,
                           check=True, timeout=timeout)

    def digest(path):
        hasher = hashlib.sha256()
        with Path(path).open('rb') as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b''):
                hasher.update(block)
        return hasher.hexdigest()

    def ff(arguments, log):
        run([args.ffmpeg, '-hide_banner', '-nostdin', '-n', *arguments], log)

    def write_json(path, value):
        path.write_text(json.dumps(value, indent=2) + '\n')

    try:
        identities = {}
        for name, path, flag in [('ffmpeg', args.ffmpeg, '-version'),
                                 ('ffprobe', args.ffprobe, '-version'),
                                 ('pkgConfig', args.pkg_config, '--version')]:
            identities[name] = {'path': str(path), 'sha256': digest(path),
                               'version': run([path, flag], name + '-version.txt', capture=True)}
        libraries = ['libavformat', 'libavcodec', 'libavutil', 'libswscale', 'libswresample']
        run([args.pkg_config, '--modversion', *libraries], 'library-versions.txt')
        cflags = shlex.split(run([args.pkg_config, '--cflags', *libraries], 'library-cflags.txt', capture=True))
        ldflags = shlex.split(run([args.pkg_config, '--libs', *libraries], 'library-ldflags.txt', capture=True))
        flags = [flag for item in cflags for flag in ('-Xcc', item)]
        flags += [flag for item in ldflags for flag in ('-Xlinker', item)]
        for library in libraries:
            libdir = Path(run([args.pkg_config, '--variable=libdir', library], library + '-libdir.txt', capture=True))
            path = libdir / (library + '.dylib')
            identities[library] = {'path': str(path.resolve()), 'sha256': digest(path)}
            run(['otool', '-L', path], library + '-dependencies.txt')
        source_files = [repo / 'scripts/native-sequence-proof.py', repo / 'scripts/native_parity.py']
        for directory in (repo / 'Packages/NativePlaybackProof', repo / 'Packages/EditorCore'):
            source_files += [p for p in directory.rglob('*') if p.is_file() and
                             '.build' not in p.parts and p.suffix in ('.swift', '.c', '.h', '.modulemap')]
        write_json(root / 'source-manifest.json', {str(p.relative_to(repo)): digest(p) for p in sorted(source_files)})
        run(['git', '-C', repo, 'status', '--short'], 'git-status.txt')
        run(['swift', 'build', '--package-path', repo / 'Packages/NativePlaybackProof',
             '--scratch-path', root / 'build', '--cache-path', root / 'cache', '--disable-sandbox', *flags], 'build.log')
        native = root / 'build/debug/NativeSequenceProof'
        identities['nativeExecutable'] = {'path': str(native), 'sha256': digest(native)}
        run(['otool', '-L', native], 'native-dependencies.txt')
        run(['swift', 'build', '--package-path', repo / 'Packages/EditorCore',
             '--scratch-path', root / 'core-build', '--cache-path', root / 'cache', '--disable-sandbox'], 'core-build.log')
        compiler = root / 'core-build/debug/RenderPlanProof'
        write_json(root / 'identities.json', identities)
        fixture_project = json.loads((args.fixture / 'project.json').read_text())
        source_paths = [Path(unquote(urlparse(a['originalURL']).path)) for a in fixture_project['assets']]
        if len(source_paths) != 2:
            raise ValueError('Barcode fixture requires exactly two sources')
        write_json(root / 'fixture-identities.json', {
            str(p): digest(p) for p in [args.fixture / 'project.json', args.fixture / 'command.json',
                args.fixture / 'result.json', *source_paths]})
        # Authenticate the actual source frame identities, independently of both
        # compilers. A colliding color-ramp fixture cannot qualify exact seeking.
        result['fixtureBarcodes'] = []
        for index, source in enumerate(source_paths):
            decoded = root / f'barcode-source-{index}.rgb'
            ff(['-i', source, '-map', '0:v:0', '-fps_mode', 'passthrough', '-pix_fmt', 'rgb24',
                '-f', 'rawvideo', decoded], f'barcode-source-{index}.log')
            expected = bytearray()
            for frame in range(300):
                row = b''.join(bytes([32 + 192 * (((frame + index * 512) >> bit) & 1)]) * (16 * 3) for bit in range(10))
                expected.extend(row * 90)
            result['fixtureBarcodes'].append(compare_rgb(decoded.read_bytes(), expected, 160 * 90 * 3, tolerance=4))

        def evaluate(name, project, replace_from=None):
            variant = root / name
            variant.mkdir()
            project_path = variant / 'project.json'
            write_json(project_path, project)
            command_path, rendered = variant / 'command.json', variant / 'render.mov'
            run([compiler, 'compile-render', project_path, rendered, command_path], name + '-compile.log')
            command = json.loads(command_path.read_text())
            ff(command['arguments'], name + '-render.log')
            ff(['-i', rendered, '-map', '0:v:0', '-fps_mode', 'passthrough',
                '-pix_fmt', 'rgb24', '-f', 'rawvideo', variant / 'reference.rgb'], name + '-decode-video.log')
            ff(['-i', rendered, '-map', '0:a:0', '-c:a', 'pcm_s16le',
                '-f', 's16le', variant / 'reference.pcm'], name + '-decode-audio.log')
            capture = variant / 'native'
            invocation = [native, project_path, capture]
            if replace_from is not None:
                initial_path = variant / 'initial-project.json'
                write_json(initial_path, replace_from)
                invocation = [native, initial_path, capture, project_path]
            run(invocation, name + '-native.log')
            manifest = json.loads((capture / 'manifest.json').read_text())
            if manifest['initialPlanReplaced'] != (replace_from is not None):
                raise ValueError('Edited playback plan was not replaced in the primed monitor')
            if (manifest['videoFrames'], manifest['audioSamples'], manifest['width'], manifest['height'],
                manifest['channels'], manifest['sampleRate']) != (180, 288288, 160, 90, 2, 48000):
                raise ValueError('Native capture differs from the qualified fixture dimensions/counts')
            video_cases = [(0, False), (2, False), (3, False), (60, False), (119, False),
                           (120, False), (179, False), (60, False), (15, False), (15, True)]
            audio_cases = [(0, False), (48047, False), (48048, False), (240239, False),
                           (115315, False), (48048, False), (287264, False), (48047, True)]
            if [(c['frame'], c['rebuilt']) for c in manifest['videoCaptures']] != video_cases:
                raise ValueError('Missing, reordered or incomplete video seek/rebuild captures')
            if [(c['startSample'], c['rebuilt']) for c in manifest['audioCaptures']] != audio_cases:
                raise ValueError('Missing, reordered or incomplete audio seek/rebuild captures')
            if any(c['sampleCount'] != min(2048, 288288 - c['startSample']) for c in manifest['audioCaptures']):
                raise ValueError('Truncated audio seek span')
            if (manifest['videoFrames'], manifest['audioSamples']) != (command['videoFrames'], command['audioSamples']):
                raise ValueError('Native and independent render compiler output counts differ')
            size = manifest['width'] * manifest['height'] * 3
            reference_rgb, reference_pcm = (variant / 'reference.rgb').read_bytes(), (variant / 'reference.pcm').read_bytes()
            if len(reference_rgb) != size * command['videoFrames'] or len(reference_pcm) != 2 * manifest['channels'] * command['audioSamples']:
                raise ValueError('Decoded reference counts differ from compiled exact counts')
            checked = {'name': name, 'libraryVersion': manifest['libraryVersion'],
                'initialPlanReplaced': manifest['initialPlanReplaced'],
                'sequentialVideo': compare_rgb((capture / 'native.rgb').read_bytes(), reference_rgb, size),
                'mixedAudio': compare_float_audio((capture / 'mixed.f32').read_bytes(), reference_pcm, manifest['channels']),
                'scheduledAudio': compare_float_audio((capture / 'scheduled.f32').read_bytes(), reference_pcm, manifest['channels']),
                'videoSeeks': [], 'audioSeeks': []}
            for index, check in enumerate(manifest['videoCaptures']):
                offset = check['frame'] * size
                expected = reference_rgb[offset:offset + size]
                raw = compare_rgb((capture / check['rgbFile']).read_bytes(), expected, size)
                decoded = variant / f'png-seek-{index}.rgb'
                ff(['-i', capture / check['pngFile'], '-pix_fmt', 'rgb24', '-f', 'rawvideo', decoded], name + f'-png-{index}.log')
                png = compare_rgb(decoded.read_bytes(), expected, size)
                checked['videoSeeks'].append({'frame': check['frame'], 'rebuilt': check['rebuilt'],
                                              'raw': raw, 'nativePNG': png})
            for check in manifest['audioCaptures']:
                offset = check['startSample'] * 2 * manifest['channels']
                length = check['sampleCount'] * 2 * manifest['channels']
                expected = reference_pcm[offset:offset + length]
                checked['audioSeeks'].append({'startSample': check['startSample'], 'rebuilt': check['rebuilt'],
                    'mixed': compare_float_audio((capture / check['mixedFile']).read_bytes(), expected, manifest['channels']),
                    'scheduled': compare_float_audio((capture / check['scheduledFile']).read_bytes(), expected, manifest['channels'])})
            checked['artifacts'] = {str(p.relative_to(variant)): digest(p) for p in variant.rglob('*') if p.is_file()}
            result['variants'].append(checked)
            write_json(root / 'result.json', result)
            print(f"{name}: all sequential frames/samples and {len(checked['videoSeeks'])} video / {len(checked['audioSeeks'])} audio seeks pass", flush=True)

        evaluate('baseline', fixture_project)
        layered = copy.deepcopy(fixture_project)
        lower = layered['tracks'][1]['clips'][0]
        lower['timelineStart'] = {'numerator': 1001, 'denominator': 2000}  # frame 15
        lower['sourceRange']['duration'] = {'numerator': 1001, 'denominator': 200}  # 150 frames
        extra = copy.deepcopy(layered['tracks'][2])
        extra['id'] = str(uuid.uuid4()).upper()
        extra['template']['gain'] = .25
        extra['template']['routing']['outputChannels'] = [1, 0]
        clip = extra['clips'][0]
        clip['id'] = str(uuid.uuid4()).upper()
        clip['sourceRange']['start'] = {'numerator': 0, 'denominator': 1}
        clip['timelineStart'] = {'numerator': 1001, 'denominator': 500}  # frame 60
        layered['tracks'].append(extra)
        evaluate('gaps-and-audio-overlap', layered)

        interframe = copy.deepcopy(layered)
        for index, asset in enumerate(interframe['assets']):
            path = root / f'interframe-source-{index}.mov'
            ff(['-i', source_paths[index], '-map', '0', '-c:v', 'libx264', '-preset', 'veryfast',
                '-crf', '12', '-g', '60', '-bf', '3', '-x264-params', 'scenecut=0:open-gop=0:b-adapt=0',
                '-pix_fmt', 'yuv420p', '-c:a', 'copy', path], f'interframe-{index}.log')
            probe = json.loads(run([args.ffprobe, '-v', 'error', '-show_streams', '-of', 'json', path], f'interframe-{index}-probe.json', capture=True))
            video = next(s for s in probe['streams'] if s['codec_type'] == 'video')
            if int(video['has_b_frames']) < 1:
                raise ValueError('Interframe control lacks reordered B frames')
            asset['originalURL'] = path.as_uri()
        evaluate('interframe-b-frames', interframe)
        edited = copy.deepcopy(fixture_project)
        edited['tracks'][0]['clips'][0]['sourceRange']['start'] = {'numerator': 1001, 'denominator': 400}  # frame 75
        edited['tracks'][2]['template']['gain'] = .25
        edited['tracks'][2]['template']['routing']['outputChannels'] = [1, 0]
        evaluate('edited-plan-rebuild', edited, replace_from=fixture_project)
        result['passed'] = True
    except Exception as error:
        result['failure'] = f'{type(error).__name__}: {error}'
        raise
    finally:
        write_json(root / 'commands.json', commands)
        write_json(root / 'result.json', result)
    print(json.dumps({'passed': result['passed'], 'variants': len(result['variants']),
                      'result': str(root / 'result.json')}, indent=2))


if __name__ == '__main__':
    main()
