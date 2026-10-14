# System sequence decoded audio mix qualification — 2026-10-14

The production AVFoundation sequence composition and `AVAudioMix` are read through
`AVAssetReaderAudioMixOutput` and compared with the canonical FFmpeg render compiler's
MOV/24-bit PCM output, decoded to float PCM. The app and proof share `makePlayerItem()`;
the proof does not recreate the volume ramps separately.

The proof exposed an initial-volume defect: a delayed clip began at unity and
AVFoundation smoothed toward the requested gain/fade during approximately the first
400–1,100 samples. Explicitly setting the initial volume at sequence zero, before
adding clip-local ramps, fixes these generated cases. The pre-fix observations are
retained in `before-initial-volume-fix.json`; its cases preceded the additional muted
tail fixture and used looser fade error limits, but all 20 still failed.

## Retained results

`results.json` records 40 passing cases, 2,016,248 timeline sample frames and
3,024,372 channel samples. PCM WAV and AAC/M4A fixtures each cover mono and distinct
stereo channels at matching 44.1/48 kHz source/output rates, constant gain 0.65,
linear/equal-power fades, overlapping independent fade edges and an adjacent linked
crossfade using source handles. Source trim (12,001 samples), placement (6,001),
clip duration (35,003) and fade lengths deliberately avoid common buffer boundaries.
Leading silence, a trailing gap and a muted tail are included. Reader timestamps
place samples on the exact timeline; overlapping/out-of-range buffers and unexpected
PCM packing fail. Both system and reference sample counts must match the plan.

Maximum absolute float-amplitude error:

- PCM constant gain: 0.000000119 (limit 0.000002).
- AAC constant gain: 0.000021949 (limit one 16-bit PCM code value, 1/32768).
- PCM/AAC fades and crossfades: 0.000081390 (limit 0.0001).

Nonlinear ramps remain an approximation. The AAC limit is explicit rather than a
claim of identical decoding: a separate direct-source `AVAssetReaderTrackOutput`
comparison measures Apple/FFmpeg decoder differences before composition. Stereo
AAC's tested trimmed interval differs by up to 0.000033498 before gain. The full
two-second source comparison differs more near encoded boundaries (up to 0.001884377),
so these passing interior-trim cases do not qualify AAC priming/end padding or every
compressed-media cut. Direct-source observations are included in `results.json`.

## Reproduction

Use an existing absolute FFmpeg executable and a new output directory:

```sh
python3 scripts/system-audio-mix-proof.py /absolute/path/ffmpeg \
  /private/tmp/afc-system-audio-proof --include-aac
```

Without `--include-aac`, the 20 PCM cases run. The output directory retains generated
source media, reference MOVs, system/reference float PCM, compilation/render logs,
command arguments, exact sample counts, hashes, error metrics and FFmpeg version.
Generated media and build artifacts are intentionally outside the repository.
Host AVFoundation media services are required; restrictive sandboxes may fail with
AVFoundation -11800 / underlying -1 before reading the mix.

`ffmpeg-version.txt` records the fixture/reference helper used for this checkpoint.
`scripts/verify.sh` passed (47 Python tests, eight skipped; 100 core tests, two skipped;
workspace smokes and unsigned Debug Xcode build). The existing system sequence smoke
also passed decoded seeks, live transport, cleanup and unsupported routing rejection.

## Scope

This qualifies the generated, same-rate decoded mix subset within the stated error
bounds. It does not qualify AVPlayer audio after random seeks, physical output,
A/V synchronization, resampling, arbitrary independent overlapping layers, boosted
gain, explicit channel mapping, surround, long/capped envelopes, or real-world AAC
boundary handling. Signed sandbox grants and broader media acceptance remain open.
