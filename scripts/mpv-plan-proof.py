#!/usr/bin/env python3
"""Record development MPV graph parity, including reproducible negative results.

Requires a completed render-plan-proof directory with mpv-command.json. This
headless graph experiment does not qualify native display or CoreAudio playback.
A nonzero exit status records failed parity while retaining result.json evidence.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile

from mpv_ipc import connect


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mpv', type=Path)
    parser.add_argument('ffmpeg', type=Path)
    parser.add_argument('fixture', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    for executable in (args.mpv, args.ffmpeg):
        if not executable.is_absolute() or not os.access(executable, os.X_OK):
            parser.error('Supply explicit absolute executable paths for MPV and FFmpeg')
    if not args.fixture.is_absolute():
        parser.error('Fixture must be an absolute directory')
    for name in ('mpv-command.json', 'project.json', 'probe.json', 'a.mov', 'b.mov', 'render.mov', 'render.rgb', 'audio.pcm'):
        if not (args.fixture / name).is_file():
            parser.error('Fixture is missing ' + name)
    if not args.output.is_absolute() or args.output.exists():
        parser.error('Output must be a new absolute directory')
    manifest = json.loads((args.fixture / 'mpv-command.json').read_text())
    probe = json.loads((args.fixture / 'probe.json').read_text())
    video = next(s for s in probe['streams'] if s['codec_type'] == 'video')
    audio = next(s for s in probe['streams'] if s['codec_type'] == 'audio')
    root = args.output
    root.mkdir(parents=True)

    def run(command, log, timeout=60):
        with (root / log).open('wb') as stream:
            try:
                process = subprocess.run([str(x) for x in command], stdout=stream,
                                         stderr=subprocess.STDOUT, timeout=timeout)
                return {'exitCode': process.returncode, 'timedOut': False}
            except subprocess.TimeoutExpired:
                return {'exitCode': None, 'timedOut': True}

    for name, executable, flag in (('mpv', args.mpv, '--version'), ('ffmpeg', args.ffmpeg, '-version')):
        run([executable, flag], name + '-version.txt')
        (root / (name + '.sha256')).write_text(hashlib.sha256(executable.read_bytes()).hexdigest() + '\n')
    run([args.mpv, '--list-options'], 'mpv-options.txt')
    graph = manifest['filterGraph']
    (root / 'filtergraph.txt').write_text(graph + '\n')
    # Identity record ties this experiment to the exact canonical graph and fixtures.
    hashes = {name: hashlib.sha256((args.fixture / name).read_bytes()).hexdigest()
              for name in ('mpv-command.json', 'project.json', 'probe.json', 'a.mov', 'b.mov', 'render.mov', 'render.rgb', 'audio.pcm')}
    common = [args.mpv, '--no-config', '--hwdec=no', '--untimed',
              '--vo=image', '--vo-image-format=png', '--audio-format=s16',
              '--audio-samplerate=' + audio['sample_rate'], '--audio-channels=stereo',
              '--volume=100', '--replaygain=no', '--demuxer=lavf', '--demuxer-lavf-format=mov',
              '--autoload-files=no']
    # Headless builds without Lua omit this option altogether.
    if any(line.strip().startswith('--load-scripts ') for line in (root / 'mpv-options.txt').read_text().splitlines()):
        common.append('--load-scripts=no')
    controls = root / 'source-control'
    controls.mkdir()
    control_command = [*common, '--vo-image-outdir=' + str(controls), '--ao=pcm',
                       '--ao-pcm-file=' + str(controls / 'audio.wav'), '--aid=2', '--frames=3', args.fixture / 'a.mov']
    control = run(control_command, 'source-control.log')
    control['capturedFrames'] = len([p for p in controls.glob('*.png') if p.stat().st_size > 0])
    control['selectedAudioTrack'] = 2
    control_decode = run([args.ffmpeg, '-hide_banner', '-nostdin', '-n', '-i', controls / 'audio.wav',
                          '-c:a', 'pcm_s16le', '-f', 's16le', controls / 'audio.pcm'], 'source-audio-decode.log')
    control['audioDecode'] = control_decode
    control['decodedPCMBytes'] = (controls / 'audio.pcm').stat().st_size if (controls / 'audio.pcm').exists() else 0
    control['passed'] = (control['exitCode'] == 0 and control['capturedFrames'] == 3
                         and control_decode['exitCode'] == 0 and control['decodedPCMBytes'] > 0)
    prores_control = root / 'prores-control'
    prores_control.mkdir()
    prores = run([*common, '--vo=null', '--ao=pcm',
                  '--ao-pcm-file=' + str(prores_control / 'audio.wav'), '--frames=3',
                  args.fixture / 'render.mov'], 'prores-source-control.log')
    prores_log = (root / 'prores-source-control.log').read_text(errors='replace')
    prores['videoDecodeObserved'] = 'VO: [null]' in prores_log
    prores_decode = run([args.ffmpeg, '-hide_banner', '-nostdin', '-n', '-i', prores_control / 'audio.wav',
                         '-c:a', 'pcm_s16le', '-f', 's16le', prores_control / 'audio.pcm'], 'prores-audio-decode.log')
    prores['audioDecode'] = prores_decode
    prores['decodedPCMBytes'] = (prores_control / 'audio.pcm').stat().st_size if (prores_control / 'audio.pcm').exists() else 0
    prores['passed'] = (prores['exitCode'] == 0 and prores['videoDecodeObserved']
                       and prores_decode['exitCode'] == 0 and prores['decodedPCMBytes'] > 0)
    prores['framesCaptured'] = False
    capture_dir = root / 'capture-control'
    capture_dir.mkdir()
    capture = run([*common, '--vo-image-outdir=' + str(capture_dir), '--ao=null', '--frames=1',
                   args.fixture / 'render.mov'], 'capture-control.log')
    capture_log = (root / 'capture-control.log').read_text(errors='replace')
    capture['capturedFrames'] = len([p for p in capture_dir.glob('*.png') if p.stat().st_size > 0])
    capture['captureUnsupported'] = 'Could not open libavcodec encoder for saving images' in capture_log
    images = root / 'frames'
    images.mkdir()
    # Discover and compile against the same paused instance used for capture.
    # An independent discovery process could enumerate tracks differently.
    runtime = {'trackBindingPassed': False, 'demuxer': 'lavf'}
    repo = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix='film-mpv-ipc-') as ipc_root:
        socket_path = Path(ipc_root) / 'mpv.sock'
        command = [*common, '--vo-image-outdir=' + str(images), '--ao=pcm',
                   '--ao-pcm-file=' + str(root / 'audio.wav'), '--ao-pcm-waveheader=yes',
                   '--pause=yes', '--idle=yes', '--keep-open=no', '--vid=1', '--aid=no',
                   '--input-ipc-server=' + str(socket_path),
                   '--external-file=' + str(args.fixture / 'b.mov')]
        (root / 'command.json').write_text(json.dumps([str(x) for x in command], indent=2) + '\n')
        client = None
        with (root / 'mpv.log').open('wb') as log:
            process = subprocess.Popen([str(x) for x in command], stdout=log, stderr=subprocess.STDOUT)
            try:
                client = connect(socket_path, process)
                client.command('loadfile', str(args.fixture / 'a.mov'))
                client.wait_event('file-loaded')
                client.wait_event('playback-restart')
                # Loading requires one selected track. Discard its paused source
                # frame before attaching the timeline graph; audio is disabled.
                for frame in images.glob('*.png'):
                    frame.unlink()
                tracks = client.command('get_property', 'track-list')
                (root / 'track-list.json').write_text(json.dumps(tracks, indent=2) + '\n')
                env = os.environ.copy()
                env['CLANG_MODULE_CACHE_PATH'] = str(root / 'module-cache')
                env['SWIFTPM_MODULECACHE_OVERRIDE'] = str(root / 'module-cache')
                with (root / 'binding-compiler.log').open('wb') as compiler_log:
                    subprocess.run(['swift', 'run', '--package-path', str(repo / 'Packages/EditorCore'),
                                    '--scratch-path', str(root / 'build'), '--cache-path', str(root / 'cache'),
                                    '--disable-sandbox', 'RenderPlanProof', 'resolve-mpv',
                                    str(args.fixture / 'project.json'), str(root / 'track-list.json'),
                                    str(args.fixture / 'a.mov'), str(root / 'runtime-mpv-command.json')],
                                   env=env, stdout=compiler_log, stderr=subprocess.STDOUT,
                                   timeout=120, check=True)
                monitor = json.loads((root / 'runtime-mpv-command.json').read_text())
                if (monitor['videoFrames'], monitor['audioSamples']) != (manifest['videoFrames'], manifest['audioSamples']):
                    raise ValueError('Runtime project and fixture graph disagree on frame/sample counts')
                runtime['graphSHA256'] = hashlib.sha256((root / 'runtime-mpv-command.json').read_bytes()).hexdigest()
                graph = monitor['filterGraph']
                (root / 'filtergraph.txt').write_text(graph + '\n')
                runtime['trackBindingPassed'] = True
                client.command('set_property', 'lavfi-complex', graph)
                client.command('set_property', 'pause', False)
                end_file = client.wait_event('end-file')
                runtime['endFile'] = end_file
                # idle keeps the IPC connection alive for evidence collection.
                client.command('quit')
                exit_code = process.wait(timeout=15)
                execution = {'exitCode': exit_code, 'timedOut': False}
                if end_file.get('reason') != 'eof':
                    runtime['failureReason'] = 'MPV did not finish the sequence at EOF'
                    execution['exitCode'] = exit_code or 1
            except (OSError, EOFError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
                runtime['failureReason'] = str(error)
                execution = {'exitCode': process.poll(), 'timedOut': isinstance(error, (TimeoutError, subprocess.TimeoutExpired))}
                if execution['exitCode'] == 0:
                    execution['exitCode'] = 1
            finally:
                if client:
                    client.connection.close()
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
    result = {'fixtureDirectory': str(args.fixture), 'fixtureHashes': hashes,
              'runtime': runtime, 'fixtureSourceControl': control, 'proresSourceControl': prores, 'captureControl': capture, 'execution': execution,
              'capturedVideoFrames': len([p for p in images.glob('*.png') if p.stat().st_size > 0]),
              'expectedVideoFrames': manifest['videoFrames'],
              'expectedAudioSamplesPerChannel': manifest['audioSamples'],
              'sequentialParityPassed': False, 'seekParityTested': False,
              'nativeDisplayTested': False, 'coreAudioTested': False,
              'pixelMeanTolerance': 12, 'pcmSampleTolerance': 20}
    if execution['exitCode'] == 0 and result['capturedVideoFrames']:
        decode_video = run([args.ffmpeg, '-hide_banner', '-nostdin', '-n', '-framerate',
                            video['avg_frame_rate'], '-i', images / '%08d.png',
                            '-pix_fmt', 'rgb24', '-f', 'rawvideo', root / 'video.rgb'], 'video-decode.log')
        decode_audio = run([args.ffmpeg, '-hide_banner', '-nostdin', '-n', '-i', root / 'audio.wav',
                            '-c:a', 'pcm_s16le', '-f', 's16le', root / 'audio.pcm'], 'audio-decode.log')
        result['decodeVideo'] = decode_video
        result['decodeAudio'] = decode_audio
        if decode_video['exitCode'] == decode_audio['exitCode'] == 0:
            actual = (root / 'video.rgb').read_bytes()
            expected = (args.fixture / 'render.rgb').read_bytes()
            frame_size = video['width'] * video['height'] * 3
            errors = [sum(abs(a - b) for a, b in zip(actual[i:i + frame_size], expected[i:i + frame_size])) / frame_size
                      for i in range(0, min(len(actual), len(expected)), frame_size)
                      if i + frame_size <= min(len(actual), len(expected))]
            result['videoMeanRGBErrors'] = errors
            result['maxFrameMeanRGBError'] = max(errors, default=None)
            pcm = (root / 'audio.pcm').read_bytes()
            expected_pcm = (args.fixture / 'audio.pcm').read_bytes()
            result['audioSamplesPerChannel'] = len(pcm) // 4
            differences = [abs(a[0] - b[0]) for a, b in zip(struct.iter_unpack('<h', pcm),
                                                          struct.iter_unpack('<h', expected_pcm))]
            result['maxPCMSampleError'] = max(differences, default=None)
            result['sequentialParityPassed'] = (result['capturedVideoFrames'] == manifest['videoFrames']
                and len(actual) == len(expected) == frame_size * manifest['videoFrames'] and bool(errors)
                and max(errors) <= 12 and len(pcm) == len(expected_pcm) and bool(differences)
                and len(pcm) == manifest['audioSamples'] * 4
                and max(differences) <= 20)
    if execution['exitCode'] != 0:
        result['failureReason'] = 'MPV graph did not complete; inspect mpv.log for decoder/filter errors'
    elif not result['sequentialParityPassed']:
        result['failureReason'] = 'Captured frame/sample counts or values differ from the canonical FFmpeg render'
    (root / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    return 0 if result['sequentialParityPassed'] and prores['passed'] and runtime['trackBindingPassed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
