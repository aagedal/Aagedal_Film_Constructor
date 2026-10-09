#!/usr/bin/env python3
"""Measure paused MPV video seek and graph rebuild parity against a render.

This development experiment does not qualify audio seeking, native display, or
CoreAudio. Failed operations retain logs, images, and result.json and exit 1.
"""
import argparse
from fractions import Fraction
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

from mpv_ipc import connect


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('mpv', 'ffmpeg', 'fixture', 'runtime_manifest', 'resolver', 'output'):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    for name in ('mpv', 'ffmpeg', 'resolver'):
        path = getattr(args, name)
        if not path.is_absolute() or not os.access(path, os.X_OK):
            parser.error(name + ' must be an explicit absolute executable path')
    for name in ('fixture', 'runtime_manifest', 'output'):
        if not getattr(args, name).is_absolute():
            parser.error(name + ' must be absolute')
    if args.output.exists():
        parser.error('Output must be a new directory')
    for name in ('project.json', 'probe.json', 'a.mov', 'b.mov', 'render.rgb'):
        if not (args.fixture / name).is_file():
            parser.error('Fixture missing ' + name)
    manifest = json.loads(args.runtime_manifest.read_text())
    probe = json.loads((args.fixture / 'probe.json').read_text())
    video = next(stream for stream in probe['streams'] if stream['codec_type'] == 'video')
    fps = Fraction(video['avg_frame_rate'])
    frame_bytes = video['width'] * video['height'] * 3
    reference = (args.fixture / 'render.rgb').read_bytes()
    seek_frames = (0, 2, 3, 60, 119, 120, 179, 60, 15)
    if len(reference) != frame_bytes * manifest['videoFrames']:
        parser.error('Canonical raw video byte count differs from manifest videoFrames')
    if any(frame < 0 or frame >= manifest['videoFrames'] for frame in seek_frames):
        parser.error('Fixture is too short for the required seek targets')
    root = args.output
    root.mkdir()
    images = root / 'frames'
    images.mkdir()
    result = {'fixtureDirectory': str(args.fixture), 'runtimeManifest': str(args.runtime_manifest),
              'fixtureHashes': {name: hashlib.sha256((args.fixture / name).read_bytes()).hexdigest()
                                for name in ('project.json', 'probe.json', 'a.mov', 'b.mov', 'render.rgb')},
              'expectedVideoFrames': manifest['videoFrames'],
              'expectedAudioSamplesPerChannel': manifest['audioSamples'],
              'runtimeManifestSHA256': hashlib.sha256(args.runtime_manifest.read_bytes()).hexdigest(),
              'trackBindingPassed': False, 'pixelMeanTolerance': 12,
              'timePositionToleranceSeconds': float(1 / fps), 'operations': [],
              'seekParityPassed': False, 'graphRebuildParityPassed': False,
              'audioSeekTested': False, 'nativeDisplayTested': False, 'coreAudioTested': False}
    for name in ('mpv', 'ffmpeg', 'resolver'):
        path = getattr(args, name)
        (root / (name + '.sha256')).write_text(hashlib.sha256(path.read_bytes()).hexdigest() + '\n')
    source_manifest = args.mpv.parent.parent / 'source-manifest.json'
    if source_manifest.is_file():
        source_bytes = source_manifest.read_bytes()
        (root / 'candidate-source-manifest.json').write_bytes(source_bytes)
        result['candidateSourceRevision'] = json.loads(source_bytes)['revision']
        result['candidateSourceManifestSHA256'] = hashlib.sha256(source_bytes).hexdigest()
    for name, flag in (('mpv', '--version'), ('ffmpeg', '-version')):
        with (root / (name + '-version.txt')).open('wb') as log:
            subprocess.run([str(getattr(args, name)), flag], stdout=log, stderr=subprocess.STDOUT,
                           timeout=15, check=True)
    process = None
    client = None
    try:
        with tempfile.TemporaryDirectory(prefix='film-seek-ipc-') as ipc_root:
            socket_path = Path(ipc_root) / 'mpv.sock'
            command = [str(args.mpv), '--no-config', '--hwdec=no', '--vo=image',
                       '--vo-image-format=png', '--vo-image-outdir=' + str(images), '--ao=null',
                       '--pause=yes', '--idle=yes', '--keep-open=yes', '--vid=1', '--aid=no',
                       '--demuxer=lavf', '--demuxer-lavf-format=mov', '--autoload-files=no',
                       '--input-ipc-server=' + str(socket_path),
                       '--external-file=' + str(args.fixture / 'b.mov')]
            (root / 'command.json').write_text(json.dumps(command, indent=2) + '\n')
            with (root / 'mpv.log').open('wb') as log:
                process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
                client = connect(socket_path, process, timeout=5)
                client.command('loadfile', str(args.fixture / 'a.mov'))
                client.wait_event('file-loaded')
                client.wait_event('playback-restart')
                tracks = client.command('get_property', 'track-list')
                (root / 'track-list.json').write_text(json.dumps(tracks, indent=2) + '\n')
                resolve = [str(args.resolver), 'resolve-mpv', str(args.fixture / 'project.json'),
                           str(root / 'track-list.json'), str(args.fixture / 'a.mov'),
                           str(root / 'resolved-mpv-command.json')]
                (root / 'resolver-command.json').write_text(json.dumps(resolve, indent=2) + '\n')
                with (root / 'resolver.log').open('wb') as resolver_log:
                    subprocess.run(resolve, stdout=resolver_log, stderr=subprocess.STDOUT,
                                   timeout=30, check=True)
                resolved = json.loads((root / 'resolved-mpv-command.json').read_text())
                if resolved != manifest:
                    raise ValueError('Loaded instance resolves differently from supplied runtime manifest')
                result['trackBindingPassed'] = True
                graph = resolved['filterGraph']
                (root / 'filtergraph.txt').write_text(graph + '\n')
                client.command('set_property', 'lavfi-complex', graph)
                client.wait_event('playback-restart')

                def measure(kind, frame):
                    item = {'kind': kind, 'targetFrame': frame,
                            'targetTimeSeconds': float(frame / fps), 'passed': False}
                    result['operations'].append(item)
                    before = set(images.glob('*.png'))
                    client.events.clear()
                    start = time.monotonic()
                    try:
                        if kind == 'rebuild':
                            item['playheadBeforeRebuild'] = client.command('get_property', 'time-pos')
                            client.command('set_property', 'lavfi-complex', '')
                            client.command('set_property', 'lavfi-complex', graph)
                            client.wait_event('playback-restart')
                            client.events.clear()
                        client.command('seek', item['targetTimeSeconds'], 'absolute+exact')
                        client.wait_event('playback-restart')
                        item['restartLatencySeconds'] = time.monotonic() - start
                        item['timePositionSeconds'] = client.command('get_property', 'time-pos')
                        new_frames = sorted(set(images.glob('*.png')) - before)
                        item['capturedFrames'] = [str(path.relative_to(root)) for path in new_frames]
                        # A seek to the current playhead can retain the displayed
                        # frame without another image VO write. Capture the
                        # actual displayed video frame through MPV in all cases.
                        capture = root / ('operation-%02d.png' % len(result['operations']))
                        client.command('screenshot-to-file', str(capture), 'video')
                        item['displayedFrameCapture'] = str(capture.relative_to(root))
                        rgb = root / ('operation-%02d.rgb' % len(result['operations']))
                        decode = [str(args.ffmpeg), '-hide_banner', '-nostdin', '-n', '-i', str(capture),
                                  '-frames:v', '1', '-pix_fmt', 'rgb24', '-f', 'rawvideo', str(rgb)]
                        with (root / ('decode-%02d.log' % len(result['operations']))).open('wb') as decode_log:
                            subprocess.run(decode, stdout=decode_log, stderr=subprocess.STDOUT,
                                           timeout=15, check=True)
                        actual = rgb.read_bytes()
                        expected = reference[frame * frame_bytes:(frame + 1) * frame_bytes]
                        if len(actual) != frame_bytes or len(expected) != frame_bytes:
                            raise ValueError('Captured/reference frame byte count differs')
                        item['meanRGBError'] = sum(abs(a - b) for a, b in zip(actual, expected)) / frame_bytes
                        item['timePositionErrorSeconds'] = abs(item['timePositionSeconds'] - item['targetTimeSeconds'])
                        item['passed'] = (item['meanRGBError'] <= 12 and
                                          item['timePositionErrorSeconds'] <= float(1 / fps))
                        if not item['passed']:
                            item['failureReason'] = 'Displayed pixels or time position differ from canonical target frame'
                    except (OSError, EOFError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
                        item['failureReason'] = str(error)
                        item['elapsedSeconds'] = time.monotonic() - start
                    (root / 'result.json').write_text(json.dumps(result, indent=2) + '\n')

                for frame in seek_frames:
                    measure('seek', frame)
                measure('rebuild', 15)
                result['seekParityPassed'] = all(item['passed'] for item in result['operations'] if item['kind'] == 'seek')
                result['graphRebuildParityPassed'] = all(item['passed'] for item in result['operations'] if item['kind'] == 'rebuild')
                client.command('quit')
                result['exitCode'] = process.wait(timeout=10)
    except (OSError, EOFError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        result['failureReason'] = str(error)
    finally:
        if client:
            client.connection.close()
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        (root / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    return 0 if (result['trackBindingPassed'] and result.get('exitCode') == 0
                 and len(result['operations']) == len(seek_frames) + 1
                 and result['seekParityPassed'] and result['graphRebuildParityPassed']) else 1


if __name__ == '__main__':
    raise SystemExit(main())
