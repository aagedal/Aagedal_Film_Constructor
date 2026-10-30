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
import math
import struct
from pathlib import Path
import subprocess
import uuid
from urllib.parse import unquote, urlparse

from native_parity import compare_float_audio, compare_rgb, compare_rgb_region, mpvkit_pin


# A fresh cache downloads every MPVKit binary artifact before building.
SWIFTPM_TIMEOUT = 1800


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ffmpeg', type=Path)
    parser.add_argument('ffprobe', type=Path)
    parser.add_argument('fixture', type=Path)
    parser.add_argument('output', type=Path)
    subset = parser.add_mutually_exclusive_group()
    subset.add_argument('--crossfades-only', action='store_true', help='Qualify linked audio transitions and baseline only')
    subset.add_argument('--geometry-only', action='store_true', help='Qualify video fit/fill/none and baseline only')
    subset.add_argument("--stills-only", action="store_true", help="Qualify PNG alpha/JPEG still fit/fill/none and baseline only")
    subset.add_argument('--partial-tail-only', action='store_true', help='Qualify an audio tail ending between video frames and baseline only')
    args = parser.parse_args()
    for executable in (args.ffmpeg, args.ffprobe):
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
        'Development build statically linking the pinned MPVKit FFmpeg; no bundled/signed distribution',
        'Bounded square-pixel SDR CFR video and matching-rate PCM audio only',
        'Native CGImage/PNG captures and offline AVAudioEngine; no live display/CoreAudio A/V sync',
        'Only recorded video scaling/PNG-alpha/JPEG fixtures qualified; no general image-format/color/VFR conformance, compressed audio/resampling, video transitions or proxies',
        'First source access qualifies all selected-stream timestamps; launch/interactive performance unmeasured'
    ]}
    commands = []
    env = os.environ.copy()
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
                                 ('ffprobe', args.ffprobe, '-version')]:
            identities[name] = {'path': str(path), 'sha256': digest(path),
                               'version': run([path, flag], name + '-version.txt', capture=True)}
        identities['mpvkit'] = mpvkit_pin(repo)
        source_files = [repo / 'scripts/native-sequence-proof.py', repo / 'scripts/native_parity.py']
        for directory in (repo / 'Packages/NativePlaybackProof', repo / 'Packages/EditorCore'):
            source_files += [p for p in directory.rglob('*') if p.is_file() and
                             '.build' not in p.parts and p.suffix in ('.swift', '.c', '.h', '.modulemap')]
        write_json(root / 'source-manifest.json', {str(p.relative_to(repo)): digest(p) for p in sorted(source_files)})
        run(['git', '-C', repo, 'status', '--short'], 'git-status.txt')
        run(['swift', 'build', '--package-path', repo / 'Packages/NativePlaybackProof',
             '--scratch-path', root / 'build', '--cache-path', root / 'cache', '--disable-sandbox'], 'build.log', timeout=SWIFTPM_TIMEOUT)
        run(['swift', 'test', '--package-path', repo / 'Packages/NativePlaybackProof',
             '--scratch-path', root / 'build', '--cache-path', root / 'cache', '--disable-sandbox'], 'runtime-tests.log', timeout=SWIFTPM_TIMEOUT)
        native = root / 'build/debug/NativeSequenceProof'
        identities['nativeExecutable'] = {'path': str(native), 'sha256': digest(native)}
        run(['otool', '-L', native], 'native-dependencies.txt')
        run(['swift', 'build', '--package-path', repo / 'Packages/EditorCore',
             '--scratch-path', root / 'core-build', '--cache-path', root / 'cache', '--disable-sandbox'], 'core-build.log', timeout=SWIFTPM_TIMEOUT)
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

        def evaluate(name, project, replace_from=None, crossfade_oracle=None, active_region=None, still_oracle=None,
                     expected_frames=180, expected_samples=288288):
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
                manifest['channels'], manifest['sampleRate']) != (expected_frames, expected_samples, 160, 90, 2, 48000):
                raise ValueError('Native capture differs from the qualified fixture dimensions/counts')
            video_cases = [(0, False), (2, False), (3, False), (60, False), (119, False),
                           (120, False), (179, False), (60, False), (15, False), (15, True)]
            audio_cases = [(0, False), (48047, False), (48048, False), (240239, False),
                           (115315, False), (48048, False), (expected_samples - 1024, False),
                           (144144, False), (120120, False), (168168, False), (192192, False),
                           (144144, False), (48047, True)]
            if expected_frames == 181:
                video_cases.insert(-1, (180, False))
                audio_cases.insert(-1, (expected_samples - 1, False))
            if [(c['frame'], c['rebuilt']) for c in manifest['videoCaptures']] != video_cases:
                raise ValueError('Missing, reordered or incomplete video seek/rebuild captures')
            if [(c['startSample'], c['rebuilt']) for c in manifest['audioCaptures']] != audio_cases:
                raise ValueError('Missing, reordered or incomplete audio seek/rebuild captures')
            if any(c['sampleCount'] != min(2048, expected_samples - c['startSample']) for c in manifest['audioCaptures']):
                raise ValueError('Truncated audio seek span')
            if (manifest['videoFrames'], manifest['audioSamples']) != (command['videoFrames'], command['audioSamples']):
                raise ValueError('Native and independent render compiler output counts differ')
            if not 0 <= manifest['asynchronousCacheBytes'] <= 128 * 1024 or manifest['asynchronousPendingRequests'] != 0:
                raise ValueError('Asynchronous cache/admission bounds failed')
            clock = manifest['transportClock']
            expected_counts = list(range(1024, manifest['audioSamples'], 1024)) + [manifest['audioSamples']]
            if [c['presentedSamples'] for c in clock] != expected_counts:
                raise ValueError('Incomplete native sample-clock observations')
            for observation in clock:
                sample = observation['presentedSamples']
                ended = sample == manifest['audioSamples']
                expected_frame = None if ended else sample * 30000 // (48000 * 1001)
                if (observation.get('frame'), observation['sample'], observation['playing']) != (expected_frame, sample, not ended):
                    raise ValueError('Native transport differs from independent exact sample/frame clock')
            size = manifest['width'] * manifest['height'] * 3
            reference_rgb, reference_pcm = (variant / 'reference.rgb').read_bytes(), (variant / 'reference.pcm').read_bytes()
            if len(reference_rgb) != size * command['videoFrames'] or len(reference_pcm) != 2 * manifest['channels'] * command['audioSamples']:
                raise ValueError('Decoded reference counts differ from compiled exact counts')
            checked = {'name': name, 'libraryVersion': manifest['libraryVersion'],
                'initialPlanReplaced': manifest['initialPlanReplaced'],
                'sequentialVideo': compare_rgb((capture / 'native.rgb').read_bytes(), reference_rgb, size),
                'asynchronousVideo': compare_rgb((capture / 'asynchronous.rgb').read_bytes(), reference_rgb, size),
                'asynchronousAudio': compare_float_audio((capture / 'asynchronous.f32').read_bytes(), reference_pcm, manifest['channels']),
                'asynchronousCacheBytes': manifest['asynchronousCacheBytes'],
                'asynchronousPendingRequests': manifest['asynchronousPendingRequests'],
                'transportClockObservations': len(clock),
                'mixedAudio': compare_float_audio((capture / 'mixed.f32').read_bytes(), reference_pcm, manifest['channels']),
                'scheduledAudio': compare_float_audio((capture / 'scheduled.f32').read_bytes(), reference_pcm, manifest['channels']),
                'videoSeeks': [], 'audioSeeks': []}
            if active_region is not None:
                checked['activePictureRegion'] = active_region
                checked['activePictureVideo'] = {
                    file: compare_rgb_region((capture / file).read_bytes(), reference_rgb,
                                             manifest['width'], manifest['height'], active_region)
                    for file in ['native.rgb', 'asynchronous.rgb']}
            for index, check in enumerate(manifest['videoCaptures']):
                offset = check['frame'] * size
                expected = reference_rgb[offset:offset + size]
                raw = compare_rgb((capture / check['rgbFile']).read_bytes(), expected, size)
                decoded = variant / f'png-seek-{index}.rgb'
                ff(['-i', capture / check['pngFile'], '-pix_fmt', 'rgb24', '-f', 'rawvideo', decoded], name + f'-png-{index}.log')
                png = compare_rgb(decoded.read_bytes(), expected, size)
                checked['videoSeeks'].append({'frame': check['frame'], 'rebuilt': check['rebuilt'],
                                              'raw': raw, 'nativePNG': png,
                                              'asynchronous': compare_rgb((capture / check['asynchronousFile']).read_bytes(), expected, size)})
            for check in manifest['audioCaptures']:
                offset = check['startSample'] * 2 * manifest['channels']
                length = check['sampleCount'] * 2 * manifest['channels']
                expected = reference_pcm[offset:offset + length]
                checked['audioSeeks'].append({'startSample': check['startSample'], 'rebuilt': check['rebuilt'],
                    'mixed': compare_float_audio((capture / check['mixedFile']).read_bytes(), expected, manifest['channels']),
                    'asynchronous': compare_float_audio((capture / check['asynchronousFile']).read_bytes(), expected, manifest['channels']),
                    'scheduled': compare_float_audio((capture / check['scheduledFile']).read_bytes(), expected, manifest['channels'])})
            if crossfade_oracle is not None:
                mode, curve = crossfade_oracle
                # Independent source/sample oracle: both editorial source placements
                # are continuous, so only the paired transition changes the waveform.
                source_pcm = root / 'crossfade-source.pcm'
                if not source_pcm.exists():
                    ff(['-i', source_paths[0], '-filter_complex',
                        '[0:2][0:1]amerge=inputs=2[a]', '-map', '[a]', '-c:a', 'pcm_s16le',
                        '-f', 's16le', source_pcm], 'crossfade-source-decode.log')
                source = source_pcm.read_bytes()
                transition_start = 144144 if mode == 'overlap' else 120120
                transition_end = transition_start + 48048
                maximum = 0
                for sample in range(command['audioSamples']):
                    if not 48048 <= sample < 240240:
                        envelope = 0
                    elif transition_start <= sample < transition_end:
                        progress = (sample - transition_start) / 48048
                        envelope = (math.cos(progress * math.pi / 2) + math.sin(progress * math.pi / 2)) if curve == 'equalPower' else 1
                    else:
                        envelope = 1
                    for channel in range(2):
                        original = struct.unpack_from('<h', source, sample * 4 + channel * 2)[0]
                        actual = struct.unpack_from('<h', reference_pcm, sample * 4 + channel * 2)[0]
                        error = abs(actual - original * .5 * envelope)
                        maximum = max(maximum, error)
                        if error > 1.01:
                            raise ValueError(f'Independent crossfade oracle sample {sample} channel {channel}: error {error}')
                checked['crossfadeSampleOracle'] = {'mode': mode, 'curve': curve,
                    'transitionSamples': [transition_start, transition_end],
                    'samplesPerChannel': command['audioSamples'], 'maxErrorInS16Units': maximum}
            if still_oracle is not None:
                # No-scaled-image oracle uses independently generated RGBA and decoded barcode
                # background frames, then integer straight-alpha arithmetic. It
                # checks transparent/partial/opaque regions separately so mean
                # frame error cannot hide dropping alpha or skipping a layer.
                rgba_path, image_width, image_height = still_oracle
                image = rgba_path.read_bytes()
                if len(image) != image_width * image_height * 4:
                    raise ValueError('Incomplete independent still RGBA decode')
                lower = (root / 'barcode-source-0.rgb').read_bytes()
                actual = (capture / 'native.rgb').read_bytes()
                maxima = {'transparent': 0, 'partial': 0, 'opaque': 0}
                counts = dict.fromkeys(maxima, 0)
                x, y = int((160 - image_width) / 2), int((90 - image_height) / 2)
                for frame in range(3, 120):
                    for sy in range(image_height):
                        dy = y + sy
                        if not 0 <= dy < 90:
                            continue
                        for sx in range(image_width):
                            dx = x + sx
                            if not 0 <= dx < 160:
                                continue
                            source = (sy * image_width + sx) * 4
                            alpha = image[source + 3]
                            kind = 'transparent' if alpha == 0 else 'opaque' if alpha == 255 else 'partial'
                            counts[kind] += 1
                            destination = (dy * 160 + dx) * 3
                            for channel in range(3):
                                background = lower[(frame + 30) * size + destination + channel]
                                expected = (image[source + channel] * alpha + background * (255 - alpha) + 127) // 255
                                error = abs(actual[frame * size + destination + channel] - expected)
                                maxima[kind] = max(maxima[kind], error)
                                if error > 1:
                                    raise ValueError(f'Still {kind} alpha oracle frame {frame} error {error}')
                if not all(counts.values()):
                    raise ValueError('Still fixture must exercise transparent, partial and opaque coverage')
                checked['straightAlphaOracle'] = {'pixels': counts, 'maximumChannelError': maxima}
            checked['artifacts'] = {str(p.relative_to(variant)): digest(p) for p in variant.rglob('*') if p.is_file()}
            result['variants'].append(checked)
            write_json(root / 'result.json', result)
            print(f"{name}: all sequential frames/samples and {len(checked['videoSeeks'])} video / {len(checked['audioSeeks'])} audio seeks pass", flush=True)

        evaluate('baseline', fixture_project)
        if args.partial_tail_only:
            partial = copy.deepcopy(fixture_project)
            partial['tracks'][2]['clips'][0]['sourceRange']['duration'] = {'numerator': 240241, 'denominator': 48000}
            evaluate('partial-final-frame-audio-tail-rebuild', partial, replace_from=fixture_project,
                     expected_frames=181, expected_samples=288289)
            capture = root / 'partial-final-frame-audio-tail-rebuild' / 'native'
            frame_size = 160 * 90 * 3
            for file in ['native.rgb', 'asynchronous.rgb']:
                if any((capture / file).read_bytes()[-frame_size:]):
                    raise ValueError('Partial final frame must be black after the picture cut')
            result['partialTail'] = {'videoFrames': 181, 'audioSamples': 288289,
                'exactDuration': '288289/48000', 'finalFrameBlack': True}
        if not args.crossfades_only and not args.stills_only and not args.partial_tail_only:
            # Different aspect ratios, both smaller/larger sources, and odd
            # dimensions exercise center padding/cropping and aspect rounding.
            # Lossless RGB sources avoid encoding a chroma-alignment policy into
            # these fixtures; the independently encoded reference remains ProRes.
            for width, height in [(80, 90), (240, 90), (81, 91)]:
                geometry = copy.deepcopy(fixture_project)
                for index, asset in enumerate(geometry['assets']):
                    path = root / f'geometry-source-{width}x{height}-{index}.nut'
                    ff(['-i', source_paths[index], '-map', '0', '-vf',
                        f'scale={width}:{height}:flags=neighbor,setsar=1,format=rgb24,'
                        'drawbox=x=0:y=0:w=iw:h=8:color=red:t=fill,'
                        'drawbox=x=0:y=ih-8:w=iw:h=8:color=blue:t=fill',
                        '-c:v', 'ffv1', '-pix_fmt', 'bgr0', '-c:a', 'copy', path],
                        f'geometry-source-{width}x{height}-{index}.log')
                    asset['originalURL'] = path.as_uri()
                for mode in ['fit', 'fill', 'none']:
                    project = copy.deepcopy(geometry)
                    for track in project['tracks']:
                        if track['template']['kind'] == 'video':
                            for clip in track['clips']:
                                clip['scalingMode'] = mode
                    # Independent expected occupied rectangles for these fixed
                    # fixtures. Never average black padding into picture parity.
                    regions = {
                        (80, 90): {'fit': (40, 0, 80, 90), 'none': (40, 0, 80, 90)},
                        (240, 90): {'fit': (0, 15, 160, 60), 'none': (0, 0, 160, 90)},
                        (81, 91): {'fit': (40, 0, 80, 90), 'none': (39, 0, 81, 90)},
                    }
                    region = regions[(width, height)].get(mode, (0, 0, 160, 90))
                    evaluate(f'geometry-{width}x{height}-{mode}-rebuild', project,
                             replace_from=fixture_project, active_region=region)
        if not args.geometry_only and not args.stills_only and not args.partial_tail_only:
            for mode, curve in [('overlap', 'equalPower'), ('adjacent', 'equalPower'), ('adjacent', 'linear')]:
                name = f'linked-crossfade-{mode}-{curve}-rebuild'
                path = root / (name + '-project.json')
                run([compiler, 'crossfade-fixture', args.fixture / 'project.json', path, mode, curve], name + '-fixture.log')
                project = json.loads(path.read_text())
                evaluate(name, project, replace_from=fixture_project, crossfade_oracle=(mode, curve))
        if not args.crossfades_only and not args.geometry_only and not args.stills_only and not args.partial_tail_only:
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

            # Independent native/FFmpeg sample comparison across overlapping edge
            # envelopes, both curves, routing, irregular blocks and reverse seeks.
            faded = copy.deepcopy(layered)
            first = faded['tracks'][2]['clips'][0]
            first['fadeIn'] = {'duration': {'numerator': 3, 'denominator': 1}, 'curve': 'linear'}
            first['fadeOut'] = {'duration': {'numerator': 3, 'denominator': 1}, 'curve': 'equalPower'}
            second = faded['tracks'][3]['clips'][0]
            # Nonintegral sample duration exercises the exact rational fade clock.
            second['fadeIn'] = {'duration': {'numerator': 250001, 'denominator': 96000}, 'curve': 'equalPower'}
            second['fadeOut'] = {'duration': {'numerator': 3, 'denominator': 1}, 'curve': 'linear'}
            evaluate('overlapping-edge-fades-rebuild', faded, replace_from=fixture_project)

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
        if not args.crossfades_only and not args.geometry_only and not args.partial_tail_only:
            for image_width, image_height in [(80, 90), (240, 90)]:
                rgba = root / f'still-source-{image_width}x{image_height}.rgba'
                # Colored blocks vary both coordinates and include fully hidden,
                # half-covered, and opaque pixels, including nonzero hidden RGB.
                rgba.write_bytes(b''.join(bytes((40 + (x // 8 % 3) * 60,
                    40 + (y // 8 % 3) * 60, 180, [0, 128, 255][x // 8 % 3]))
                    for y in range(image_height) for x in range(image_width)))
                for extension in ['png', 'jpg']:
                    image = root / f'still-source-{image_width}x{image_height}.{extension}'
                    ff(['-f', 'rawvideo', '-pixel_format', 'rgba', '-video_size', f'{image_width}x{image_height}',
                        '-i', rgba, '-frames:v', '1', image], f'still-source-{image_width}x{image_height}-{extension}.log')
                    result.setdefault('stillSourceIdentities', []).append({
                        'path': str(image), 'sha256': digest(image), 'width': image_width,
                        'height': image_height, 'rgbaFixtureSHA256': digest(rgba)})
                    for mode in ['fit', 'fill', 'none']:
                        project = copy.deepcopy(fixture_project)
                        asset = project['assets'][1]
                        asset['originalURL'] = image.as_uri()
                        # Imported images use synthetic duration with no probed streams.
                        asset['streams'] = []
                        clip = project['tracks'][0]['clips'][0]
                        clip['selection'] = {'still': {}}
                        clip['scalingMode'] = mode
                        # Synthetic still in is intentionally off the frame grid.
                        clip['sourceRange']['start'] = {'numerator': 1, 'denominator': 48000}
                        region = (40, 0, 80, 90) if image_width == 80 and mode != 'fill' else (0, 15, 160, 60) if image_width == 240 and mode == 'fit' else (0, 0, 160, 90)
                        oracle = (rgba, image_width, image_height) if extension == 'png' and mode == 'none' else None
                        evaluate(f'still-{extension}-{image_width}x{image_height}-{mode}-rebuild', project,
                                 replace_from=fixture_project, active_region=region, still_oracle=oracle)
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
