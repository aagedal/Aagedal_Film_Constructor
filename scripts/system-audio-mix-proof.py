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
    parser.add_argument('--include-resampling', action='store_true', help='Also test 44.1-to-48 and 48-to-44.1 kHz sources')
    parser.add_argument('--include-packet-cuts', action='store_true', help='Also test AAC cuts around a 1024-frame packet boundary (requires --include-aac)')
    parser.add_argument('--expect-resampling-rejection', action='store_true', help='Assert the system backend rejects each cross-rate case (requires --include-resampling)')
    args = parser.parse_args()
    if args.expect_resampling_rejection and not args.include_resampling:
        parser.error('--expect-resampling-rejection requires --include-resampling')
    if args.include_packet_cuts and not args.include_aac:
        parser.error('--include-packet-cuts requires --include-aac')
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
    packet_evidence = []
    if args.include_aac:
        for channels in [1, 2]:
            for rate in [44100, 48000]:
                stem = f'source-{channels}-{rate}'
                run([args.ffmpeg, '-v', 'error', '-nostdin', '-n', '-i', root / (stem + '.wav'),
                     '-c:a', 'aac', '-b:a', '192k', root / (stem + '.m4a')], stem + '-aac.log')
                run([args.ffmpeg, '-v', 'error', '-nostdin', '-i', root / (stem + '.m4a'),
                     '-map', '0:a:0', '-c:a', 'copy', '-f', 'framecrc', '-'], stem + '-packets.txt')
                lines = (root / (stem + '-packets.txt')).read_text().splitlines()
                packets = [list(map(int, line.split(',')[:4])) for line in lines if not line.startswith('#')]
                if f'#tb 0: 1/{rate}' not in lines or not any(p[2] == 12288 and p[3] == 1024 for p in packets):
                    raise RuntimeError(f'{stem}: expected AAC packet boundary not established')
                packet_evidence.append(dict(channels=channels, sampleRate=rate,
                    timeBase=f'1/{rate}', testedPacketPTS=12288, testedPacketDuration=1024,
                    packetTableSHA256=hashlib.sha256((root / (stem + '-packets.txt')).read_bytes()).hexdigest()))
    common = ['swiftc', '-swift-version', '6', '-default-isolation', 'MainActor',
              '-module-cache-path', root / 'module-cache']
    run([*common, '-emit-library', '-emit-module', '-module-name', 'EditorCore',
         *sorted((repo / 'Packages/EditorCore/Sources/EditorCore').glob('*.swift')),
         '-emit-module-path', root / 'EditorCore.swiftmodule', '-o', root / 'libEditorCore.dylib'], 'core-build.log')
    run([*common, '-parse-as-library', '-I', root, '-L', root, '-lEditorCore',
         repo / 'Aagedal Film Constructor/AVFoundationSequenceBackend.swift',
         repo / 'Aagedal Film Constructor/SequencePlaybackController.swift',
         repo / 'scripts/system-audio-mix-proof.swift', '-o', root / 'mix-proof'], 'mix-build.log')
    run([root / 'mix-proof', root, *[flag for flag, enabled in [('--include-aac', args.include_aac), ('--include-resampling', args.include_resampling), ('--include-packet-cuts', args.include_packet_cuts), ('--expect-resampling-rejection', args.expect_resampling_rejection)] if enabled]], 'mix-decode.log')
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
    source_resamplers = []
    if args.include_resampling:
        for format in (["pcm", "aac"] if args.include_aac else ["pcm"]):
            for channels in [1, 2]:
                for source_rate, rate in [(44100, 48000), (48000, 44100)]:
                    stem = f"{format}-source-{channels}-{source_rate}-to-{rate}"
                    raw = root / (stem + "-reference.f32")
                    run([args.ffmpeg, "-v", "error", "-nostdin", "-n", "-i",
                         root / f"source-{channels}-{source_rate}.{'wav' if format == 'pcm' else 'm4a'}",
                         "-t", "2", "-ar", rate, "-c:a", "pcm_f32le", "-f", "f32le", raw], stem + "-decode.log")
                    system, reference = floats(root / (stem + "-system.f32")), floats(raw)
                    count = min(len(system), len(reference))
                    interior = [abs(system[i] - reference[i]) for i in range(12001 * channels, 47004 * channels)]
                    source_resamplers.append(dict(case=stem, systemFrames=len(system) // channels,
                        referenceFrames=len(reference) // channels,
                        maximumError=max(abs(system[i] - reference[i]) for i in range(count)),
                        interiorMaximumError=max(interior),
                        interiorRMSError=math.sqrt(sum(e * e for e in interior) / len(interior))))
    cases = []
    for mix in json.loads((root / 'mixes.json').read_text()):
        name = mix['case']
        if mix.get('rejected'):
            if not args.expect_resampling_rejection or mix['sourceSampleRate'] == mix['sampleRate'] or not mix['rejectionReason'].startswith('System preview requires audio at the sequence sample rate'):
                raise RuntimeError(f'{name}: unexpected rejection')
            cases.append(dict(mix, passed=True, qualification='explicit-cross-rate-rejection'))
            print(f'{name}: PASS explicitly rejected', flush=True)
            continue
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
        constant = '-constant-' in name or '-packet-' in name
        resampling = mix['sourceSampleRate'] != mix['sampleRate']
        # Cross-rate constant cases retain a one-s16-code budget: different
        # resampling kernels are not assumed equivalent. Errors outside that
        # engineering bound remain failures, including at discontinuous cuts.
        limit = (1 / 32768 if name.startswith('aac-') or resampling else 0.000002) if constant else 0.0001
        maximum_index = errors.index(maximum)
        # Excluding 64 output frames per edit is diagnostic only; pass/fail
        # always includes every sample. This separates kernel edge behaviour
        # from an error persisting throughout the audible clip.
        start = 6001
        interior = errors[(start + 64) * mix['channels']:(start + 35003 - 64) * mix['channels']]
        passed = all(math.isfinite(value) for value in system) and all(math.isfinite(value) for value in reference) and maximum <= limit
        observation = dict(case=name, passed=passed, channels=mix['channels'], sampleRate=mix['sampleRate'],
                           sourceSampleRate=mix['sourceSampleRate'], sourceStartOutputSample=mix['sourceStartOutputSample'],
                           sourceStartTime=mix['sourceStartTime'], aacPacketFrames=mix['aacPacketFrames'],
                           nearestPacketBoundaryOutputSample=mix['nearestPacketBoundaryOutputSample'],
                           frames=mix['frames'], decodedFrames=mix['decodedFrames'],
                           maximumErrorFrame=maximum_index // mix['channels'], maximumErrorChannel=maximum_index % mix['channels'],
                           interiorMaximumError=max(interior), interiorExcludedFramesPerEdge=64,
                           maximumError=maximum, rmsError=rms, maximumErrorLimit=limit,
                           systemSHA256=hashlib.sha256((root / (name + '-system.f32')).read_bytes()).hexdigest(),
                           referenceSHA256=hashlib.sha256(raw.read_bytes()).hexdigest())
        if constant and resampling:
            channels = mix['channels']
            diagnostic_range = range(15000 * channels, 30000 * channels)
            def lag_rms(lag):
                return math.sqrt(sum((system[i] - reference[i + lag * channels]) ** 2
                                     for i in diagnostic_range) / len(diagnostic_range))
            best_lag = min(range(-16, 17), key=lag_rms)
            derivatives = [(reference[i + channels] - reference[i - channels]) / 2 for i in diagnostic_range]
            denominator = sum(d * d for d in derivatives)
            observation.update(bestIntegerLag=best_lag, bestIntegerLagRMSError=lag_rms(best_lag),
                diagnosticInteriorRMSError=lag_rms(0),
                firstOrderFractionalLag=sum((system[i] - reference[i]) * d
                    for i, d in zip(diagnostic_range, derivatives)) / denominator if denominator else None)
        cases.append(observation)
        print(f'{name}: {"PASS" if passed else "FAIL"} max={maximum:.9f} rms={rms:.9f}', flush=True)
    (root / 'results.json').write_text(json.dumps(dict(system=platform.platform(),
        ffmpeg=(root / 'ffmpeg-version.txt').read_text().splitlines()[0], aacPacketEvidence=packet_evidence, sourceDecoderComparisons=source_decoders, sourceResamplerComparisons=source_resamplers, cases=cases), indent=2) + '\n')
    if any(not case['passed'] for case in cases):
        raise SystemExit('System mix qualification failed; inspect results.json')


if __name__ == '__main__':
    main()
