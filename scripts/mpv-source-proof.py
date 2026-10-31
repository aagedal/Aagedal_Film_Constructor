#!/usr/bin/env python3
"""Offline source-player qualification against explicitly selected cached MPVKit artifacts.

Builds an isolated executable, never links the application or downloads dependencies.
Null audio output does not qualify CoreAudio or decoded audio fidelity.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import re
import subprocess
import sys

REVISION = '400202b687841fb394cbf0ef59ad8c6fcfc1275b'
# Clean MPVKit checkouts these proofs accept, with the release their Libmpv-GPL
# artifact must come from: the 8.1.2-era CoreAudio fix, and the n9.0.2 editor
# build the native runtime links (Packages/NativePlaybackProof).
PINS = {REVISION: 'aagedal-1.0.0-n8.1.2-coreaudio.2',
        '7f5d3f53bd2676aa5c569271ada72752a2e83267': 'aagedal-1.1.0-n9.0.2-editor.1'}
ARTIFACTS = ('Libmpv-GPL', 'Libavcodec-GPL', 'Libavdevice-GPL', 'Libavfilter-GPL',
             'Libavformat-GPL', 'Libavutil-GPL', 'Libswresample-GPL', 'Libswscale-GPL',
             'Libssl', 'Libcrypto', 'Libass', 'Libfreetype', 'Libfribidi', 'Libharfbuzz',
             'MoltenVK', 'Libshaderc_combined', 'lcms2', 'Libplacebo', 'Libdovi',
             'Libunibreak', 'Libsmbclient', 'gmp', 'nettle', 'hogweed', 'gnutls',
             'Libdav1d', 'Libuavs3d', 'Libuchardet', 'Libbluray')
FRAMEWORKS = ('AVFoundation', 'CoreAudio', 'AudioToolbox', 'CoreVideo',
              'CoreFoundation', 'CoreMedia', 'Metal', 'VideoToolbox')
LIBRARIES = ('bz2', 'iconv', 'expat', 'resolv', 'xml2', 'z', 'c++')


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def framework_slice(artifact, architecture):
    """Require one native macOS slice; never use an iOS/Catalyst simulator slice."""
    bundles = list(artifact.glob('*.xcframework'))
    if len(bundles) != 1:
        raise ValueError(f'Expected one xcframework in {artifact}')
    bundle = bundles[0]
    info = plistlib.loads((bundle / 'Info.plist').read_bytes())
    matches = [item for item in info['AvailableLibraries']
               if item.get('SupportedPlatform') == 'macos'
               and not item.get('SupportedPlatformVariant')
               and architecture in item.get('SupportedArchitectures', [])]
    if len(matches) != 1:
        raise ValueError(f'Expected one macOS {architecture} slice in {bundle}')
    item = matches[0]
    # Reject malformed metadata escaping the explicitly supplied artifact root.
    candidate = bundle / item['LibraryIdentifier'] / item['LibraryPath']
    if not candidate.resolve().is_relative_to(bundle.resolve()) or candidate.suffix not in ('.framework', '.a'):
        raise ValueError(f'Invalid framework path in {bundle}')
    binary = candidate / candidate.stem if candidate.suffix == '.framework' else candidate
    if not binary.is_file():
        raise ValueError(f'Missing framework binary: {binary}')
    return candidate, binary


def compare_rgb(actual, expected, mean_limit=3.0, max_limit=32, width=None):
    if not actual or len(actual) != len(expected):
        raise ValueError('Captured/reference RGB byte counts differ or are empty')
    if len(actual) % 3 or (width is not None and (width <= 0 or len(actual) % (width * 3))):
        raise ValueError('Captured/reference bytes do not describe complete RGB rows')
    errors = [abs(a - b) for a, b in zip(actual, expected)]
    mean = sum(errors) / len(errors)
    maximum = max(errors)
    peak = errors.index(maximum)
    pixel = peak // 3
    start = pixel * 3
    result = {'meanRGBError': mean, 'maximumRGBError': maximum,
              'componentsOverMaximumTolerance': sum(error > max_limit for error in errors),
              'channelMeanErrors': {channel: sum(errors[index::3]) / (len(errors) // 3)
                                    for index, channel in enumerate(('red', 'green', 'blue'))},
              'peakError': {'pixelIndex': pixel, 'channel': ('red', 'green', 'blue')[peak % 3],
                            'actualRGB': list(actual[start:start + 3]),
                            'referenceRGB': list(expected[start:start + 3])},
              'passed': mean <= mean_limit and maximum <= max_limit}
    if width is not None:
        result['peakError'].update({'x': pixel % width, 'y': pixel // width})
    return result


def pinned_checkout(checkout):
    revision = subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip()
    status = subprocess.check_output(['git', '-C', str(checkout), 'status', '--porcelain', '--untracked-files=no'], text=True)
    if revision not in PINS or status:
        raise ValueError('MPVKit must be a clean checkout at one of ' + ', '.join(PINS))
    package = (checkout / 'Package.swift').read_text()
    # Record the expected upstream archive identity separately from hashes of
    # extracted local bytes: this does not reauthenticate a missing zip archive.
    match = re.search(r'name: "Libmpv-GPL",\s*url: "([^"]+)",\s*checksum: "([a-f0-9]{64})"', package)
    if not match or not match[1].endswith('/' + PINS[revision] + '/Libmpv-GPL.xcframework.zip'):
        raise ValueError('Pinned package does not select the artifact release for its revision')
    return {'revision': revision, 'release': PINS[revision], 'packageSHA256': digest(checkout / 'Package.swift'),
            'declaredLibmpvArchiveURL': match[1], 'declaredLibmpvArchiveSHA256': match[2],
            'archiveBytesReauthenticated': False}


def run_proof(args):
    root = args.output
    root.mkdir(parents=True)
    result = {'passed': False, 'nativeDisplayTested': False, 'coreAudioTested': False,
              'decodedAudioTested': False, 'applicationIntegrated': False,
              'fixtureColor': 'color' if args.color_fixtures else 'grayscale',
              'commands': [], 'fixtures': [], 'pixelMeanTolerance': 3.0,
              'pixelMaximumTolerance': 32,
              'pixelComparisonPolicy': 'All RGB components; no edge masking, spatial alignment or fitted color transform',
              'referenceConversion': 'Independent FFmpeg default YUV-to-rgb24 conversion',
              'captureConversion': 'MPV screenshot-raw video bgr0, repacked to RGB24',
              'coloredFixturePixelsPassed': False}

    def run(command, name, timeout=60, expect_failure=False):
        command = [str(value) for value in command]
        result['commands'].append({'name': name, 'argv': command})
        with (root / (name + '.log')).open('wb') as log:
            completed = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
        if (completed.returncode == 0) == expect_failure:
            raise RuntimeError(f'{name} returned {completed.returncode}; see retained log')
        return completed.returncode

    try:
        result['candidate'] = pinned_checkout(args.checkout)
        architecture = platform.machine()
        frameworks = [framework_slice(args.artifacts / name, architecture) for name in ARTIFACTS]
        result['architecture'] = architecture
        result['frameworks'] = [{'artifact': name, 'binary': str(binary), 'sha256': digest(binary)}
                                for name, (_, binary) in zip(ARTIFACTS, frameworks)]
        source = root / 'mpv-source-proof.c'
        source.write_bytes(Path(__file__).with_suffix('.c').read_bytes())
        result['proofSourceSHA256'] = digest(source)
        result['runnerSHA256'] = digest(Path(__file__))
        executable = root / 'mpv-source-proof'
        swiftc = Path(subprocess.check_output(['/usr/bin/xcrun', '--find', 'swiftc'], text=True).strip())
        swift_libraries = swiftc.parent.parent / 'lib' / 'swift' / 'macosx'
        command = ['/usr/bin/clang', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2',
                   '-arch', architecture, '-mmacosx-version-min=27.0',
                   '-L', swift_libraries,
                   '-I', frameworks[0][0] / 'Headers', source]
        command.extend(binary for _, binary in frameworks)
        for name in FRAMEWORKS:
            command.extend(['-framework', name])
        command.extend('-l' + name for name in LIBRARIES)
        command.extend(['-o', executable])
        run(command, 'compile', timeout=180)
        result['executableSHA256'] = digest(executable)
        run(['/usr/bin/otool', '-L', executable], 'linked-libraries')
        run([args.ffmpeg, '-version'], 'ffmpeg-version')
        result['ffmpegSHA256'] = digest(args.ffmpeg)
        result['ffprobeSHA256'] = digest(args.ffprobe)
        fixture = root / 'source.mov'
        run([args.ffmpeg, '-hide_banner', '-nostdin', '-n', '-f', 'lavfi', '-i',
             'testsrc2=size=320x180:rate=24:duration=3' + ('' if args.color_fixtures else ',hue=s=0'), '-f', 'lavfi', '-i',
             'sine=frequency=440:sample_rate=48000:duration=3', '-f', 'lavfi', '-i',
             'sine=frequency=880:sample_rate=48000:duration=3', '-map', '0:v', '-map', '1:a', '-map', '2:a',
             '-c:v', 'prores_ks', '-profile:v', '3', '-pix_fmt', 'yuv422p10le', '-c:a', 'pcm_s16le', fixture], 'generate')
        # A second container deliberately puts audio before picture. Track IDs
        # are scoped by type and cannot be guessed from container stream order.
        reordered = root / 'reordered.mkv'
        run([args.ffmpeg, '-hide_banner', '-nostdin', '-n', '-i', fixture,
             '-map', '0:1', '-map', '0:0', '-map', '0:2', '-c', 'copy', reordered], 'reorder')
        h264 = root / 'h264-aac.mp4'
        run([args.ffmpeg, '-hide_banner', '-nostdin', '-n', '-i', fixture,
             '-map', '0', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-g', '48', '-bf', '3',
             '-c:a', 'aac', h264], 'h264')
        hevc = root / 'open-gop-hevc-aac.mp4'
        run([args.ffmpeg, '-hide_banner', '-nostdin', '-n', '-i', fixture,
             '-map', '0', '-c:v', 'libx265', '-pix_fmt', 'yuv420p',
             '-x265-params', 'keyint=24:min-keyint=24:scenecut=0:open-gop=1:pools=1',
             '-tag:v', 'hvc1', '-c:a', 'aac', hevc], 'hevc')
        cases = ((fixture, 0, 2), (reordered, 1, 2), (fixture, 0, -1), (fixture, -1, 2),
                 (h264, 0, 2), (hevc, 0, 2))
        for index, (path, video_index, audio_index) in enumerate(cases):
            output = root / f'fixture-{index}'
            probe = subprocess.check_output([str(args.ffprobe), '-v', 'error', '-show_streams', '-of', 'json', str(path)], timeout=30)
            streams = json.loads(probe)['streams']
            if (video_index >= 0 and not any(s['index'] == video_index and s['codec_type'] == 'video' for s in streams)) or (audio_index >= 0 and not any(s['index'] == audio_index and s['codec_type'] == 'audio' for s in streams)):
                raise ValueError('Generated fixture stream indices differ from requested mapping')
            run([executable, path, video_index, audio_index, output], f'playback-{index}')
            (output / 'probe.json').write_bytes(probe)
            report = json.loads((output / 'report.json').read_text())
            item = {'path': str(path), 'sha256': digest(path), 'videoStreamIndex': video_index,
                    'audioStreamIndex': audio_index, 'report': report, 'comparisons': [],
                    'sourceVideoColorMetadata': [{key: stream[key] for key in
                        ('index', 'pix_fmt', 'color_range', 'color_space', 'color_transfer',
                         'color_primaries', 'chroma_location') if key in stream}
                        for stream in streams if stream['codec_type'] == 'video']}
            result['fixtures'].append(item)
            if report.get('passed') is not True or [c['index'] for c in report['cycles']] != list(range(4)):
                raise ValueError('Source runner did not complete four lifecycle cycles')
            for cycle in report['cycles']:
                if [c['targetSeconds'] for c in cycle['captures']] != [0, 1.5, 0.25, 2, 0.5]:
                    raise ValueError('Source runner did not capture every seek')
                for capture in cycle['captures']:
                    target = capture['targetSeconds']
                    if not math.isfinite(capture['timePosition']) or abs(capture['timePosition'] - target) > 1 / 24:
                        raise ValueError('MPV source coordinate differs by more than one frame')
                    if video_index < 0:
                        if capture['file'] is not None:
                            raise ValueError('Disabled video unexpectedly emitted a capture')
                        continue
                    image = output / capture['file']
                    if not image.resolve().is_relative_to(output.resolve()):
                        raise ValueError('Capture path escapes output directory')
                    reference = image.with_suffix('.reference.rgb')
                    tag = f"{index}-{cycle['index']}-{len(item['comparisons'])}"
                    rgb = image
                    frame = round(target * 24)
                    run([args.ffmpeg, '-v', 'error', '-nostdin', '-n', '-i', path, '-map', f'0:{video_index}',
                         '-vf', f'select=eq(n\\,{frame})', '-frames:v', '1', '-pix_fmt', 'rgb24',
                         '-f', 'rawvideo', reference], 'reference-' + tag)
                    comparison = compare_rgb(rgb.read_bytes(), reference.read_bytes(), width=320)
                    comparison.update({'cycle': cycle['index'], 'targetSeconds': target, 'capture': capture['file']})
                    item['comparisons'].append(comparison)
            rejected = root / f'rejected-{index}'
            run([executable, path, video_index, 99, rejected], f'reject-track-{index}', expect_failure=True)
            rejection = json.loads((rejected / 'report.json').read_text())
            if rejection.get('passed') is not False or rejection.get('failure') != 'missing or ambiguous container stream identity':
                raise ValueError('Unknown track was not explicitly rejected by identity resolution')
            wrong_kind = root / f'wrong-kind-{index}'
            run([executable, path, 2, video_index if video_index >= 0 else 0, wrong_kind],
                f'reject-kind-{index}', expect_failure=True)
            rejection = json.loads((wrong_kind / 'report.json').read_text())
            if rejection.get('passed') is not False or rejection.get('failure') != 'missing or ambiguous container stream identity':
                raise ValueError('Wrong-kind stream was not explicitly rejected by identity resolution')
        result['passed'] = all(c['passed'] for fixture in result['fixtures'] for c in fixture['comparisons'])
        result['coloredFixturePixelsPassed'] = result['passed'] and args.color_fixtures
        if not result['passed']:
            result['error'] = 'Decoded source seeks exceeded unchanged RGB bounds'
    except Exception as error:
        result['error'] = str(error)
    finally:
        (root / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'passed': result['passed'], 'result': str(root / 'result.json'), 'error': result.get('error')}))
    return 0 if result['passed'] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--color-fixtures', action='store_true',
                        help='Diagnostic color matrix; retain color-conversion failures without changing bounds')
    for name in ('checkout', 'artifacts', 'ffmpeg', 'ffprobe', 'output'):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    for name in ('checkout', 'artifacts', 'ffmpeg', 'ffprobe', 'output'):
        if not getattr(args, name).is_absolute():
            parser.error(name + ' must be absolute')
    for name in ('ffmpeg', 'ffprobe'):
        if not os.access(getattr(args, name), os.X_OK):
            parser.error(name + ' must be an explicit executable')
    if args.output.exists() or args.output.resolve().is_relative_to(args.checkout.resolve()) or args.output.resolve().is_relative_to(args.artifacts.resolve()):
        parser.error('output must be a new directory outside the selected dependency roots')
    return run_proof(args)


if __name__ == '__main__':
    sys.exit(main())
