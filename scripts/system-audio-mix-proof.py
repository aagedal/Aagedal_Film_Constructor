#!/usr/bin/env python3
"""Compare the production AVFoundation sequence mix with sample-timed FFmpeg renders."""
import argparse
import array
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import subprocess
import wave


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ffmpeg', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--include-aac', action='store_true', help='Also qualify compressed AAC fixture decoding')
    args = parser.parse_args()
    if not args.ffmpeg.is_absolute() or not os.access(args.ffmpeg, os.X_OK):
        parser.error('Supply an absolute FFmpeg executable')
    if not args.output.is_absolute() or args.output.exists():
        parser.error('Supply a new absolute output directory')
    root = args.output
    root.mkdir(parents=True)
    repo = Path(__file__).resolve().parent.parent
    env = dict(os.environ, DYLD_LIBRARY_PATH=str(root), NSUnbufferedIO='YES')

    def run(command, log):
        with (root / log).open('wb') as stream:
            subprocess.run(list(map(str, command)), env=env, stdout=stream,
                           stderr=subprocess.STDOUT, check=True, timeout=240)

    run([args.ffmpeg, '-version'], 'ffmpeg-version.txt')
    # Distinct channel frequencies and irregular trim/delay sample counts reveal
    # channel swaps, off-by-one cuts, gain normalization and incorrect envelopes.
    for channels in [1, 2]:
        for rate in [44100, 48000]:
            values = array.array('h')
            for frame in range(rate * 2):
                for channel in range(channels):
                    signal = 0.18 * math.sin(2 * math.pi * (317 if channel == 0 else 733) * frame / rate)
                    signal += 0.07 * math.sin(2 * math.pi * 59 * frame / rate)
                    values.append(round(signal * 32767))
            with wave.open(str(root / f'source-{channels}-{rate}.wav'), 'wb') as stream:
                stream.setnchannels(channels)
                stream.setsampwidth(2)
                stream.setframerate(rate)
                stream.writeframes(values.tobytes())
    if args.include_aac:
        for channels in [1, 2]:
            for rate in [44100, 48000]:
                stem = f'source-{channels}-{rate}'
                run([args.ffmpeg, '-v', 'error', '-nostdin', '-n', '-i', root / (stem + '.wav'),
                     '-c:a', 'aac', '-b:a', '192k', root / (stem + '.m4a')], stem + '-aac.log')
    common = ['swiftc', '-swift-version', '6', '-default-isolation', 'MainActor',
              '-module-cache-path', root / 'module-cache']
    run([*common, '-emit-library', '-emit-module', '-module-name', 'EditorCore',
         *sorted((repo / 'Packages/EditorCore/Sources/EditorCore').glob('*.swift')),
         '-emit-module-path', root / 'EditorCore.swiftmodule', '-o', root / 'libEditorCore.dylib'], 'core-build.log')
    run([*common, '-parse-as-library', '-I', root, '-L', root, '-lEditorCore',
         repo / 'Aagedal Film Constructor/AVFoundationSequenceBackend.swift',
         repo / 'Aagedal Film Constructor/SequencePlaybackController.swift',
         repo / 'scripts/system-audio-mix-proof.swift', '-o', root / 'mix-proof'], 'mix-build.log')
    run([root / 'mix-proof', root, *(['--include-aac'] if args.include_aac else [])], 'mix-decode.log')
    def floats(path):
        result = array.array('f')
        result.frombytes(path.read_bytes())
        return result

    source_decoders = []
    if args.include_aac:
        for channels in [1, 2]:
            for rate in [44100, 48000]:
                stem = f'source-{channels}-{rate}'
                raw = root / (stem + '-reference.f32')
                run([args.ffmpeg, '-v', 'error', '-nostdin', '-n', '-i', root / (stem + '.m4a'),
                     '-t', '2', '-c:a', 'pcm_f32le', '-f', 'f32le', raw], stem + '-decode.log')
                system, reference = floats(root / (stem + '-system.f32')), floats(raw)
                if len(system) != 2 * rate * channels or len(system) != len(reference):
                    raise RuntimeError(f'{stem}: unexpected direct-source PCM lengths')
                trim = slice(12001 * channels, 47004 * channels)
                source_decoders.append(dict(channels=channels, sampleRate=rate,
                    maximumFullSourceError=max(abs(a - b) for a, b in zip(system, reference)),
                    sourceStartSample=12001, sourceSampleCount=35003,
                    maximumTrimmedSourceError=max(abs(a - b) for a, b in zip(system[trim], reference[trim]))))
    cases = []
    for mix in json.loads((root / 'mixes.json').read_text()):
        name = mix['case']
        run([args.ffmpeg, *mix['arguments']], name + '-render.log')
        raw = root / (name + '-reference.f32')
        run([args.ffmpeg, '-v', 'error', '-nostdin', '-n', '-i', mix['arguments'][-1],
             '-map', '0:a:0', '-c:a', 'pcm_f32le', '-f', 'f32le', raw], name + '-decode.log')
        system = floats(root / (name + '-system.f32'))
        reference = floats(raw)
        expected = mix['frames'] * mix['channels']
        if len(system) != expected or len(reference) != expected:
            raise RuntimeError(f'{name}: unexpected PCM length {len(system)}/{len(reference)}, expected {expected}')
        errors = [abs(a - b) for a, b in zip(system, reference)]
        maximum = max(errors)
        rms = math.sqrt(sum(error * error for error in errors) / len(errors))
        # PCM constant gain uses a tight float-rounding bound. AAC constant mix
        # permits one 16-bit PCM code value across the two decoder implementations.
        # Piecewise nonlinear ramps intentionally approximate the exact envelope.
        limit = (1 / 32768 if name.startswith('aac-') else 0.000002) if '-constant-' in name else 0.0001
        passed = all(math.isfinite(value) for value in system) and all(math.isfinite(value) for value in reference) and maximum <= limit
        observation = dict(case=name, passed=passed, channels=mix['channels'], sampleRate=mix['sampleRate'],
                           frames=mix['frames'], decodedFrames=mix['decodedFrames'],
                           maximumError=maximum, rmsError=rms, maximumErrorLimit=limit,
                           systemSHA256=hashlib.sha256((root / (name + '-system.f32')).read_bytes()).hexdigest(),
                           referenceSHA256=hashlib.sha256(raw.read_bytes()).hexdigest())
        cases.append(observation)
        print(f'{name}: {"PASS" if passed else "FAIL"} max={maximum:.9f} rms={rms:.9f}', flush=True)
    (root / 'results.json').write_text(json.dumps(dict(system=platform.platform(),
        ffmpeg=(root / 'ffmpeg-version.txt').read_text().splitlines()[0], sourceDecoderComparisons=source_decoders, cases=cases), indent=2) + '\n')
    if any(not case['passed'] for case in cases):
        raise SystemExit('System mix qualification failed; inspect results.json')


if __name__ == '__main__':
    main()
