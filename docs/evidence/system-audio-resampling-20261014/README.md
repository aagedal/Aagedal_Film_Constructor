# System audio packet cuts and resampling — 2026-10-14

The production `AVFoundationSequenceBackend.makePlayerItem()` composition/audio mix
was decoded using `AVAssetReaderAudioMixOutput` and compared with canonical
`FFmpegRenderCompiler` renders. The generated 2-second mono/distinct-stereo sources
contain 317/733 Hz tones plus a 59 Hz tone, stored as 16-bit PCM WAV or encoded
AAC-LC/M4A. Each case uses gain 0.65, a delayed 6,001-output-sample placement,
35,003-sample clip, leading silence, a trailing gap and muted tail. Constant,
linear/equal-power, overlapping fade edges and linked crossfades are tested at
matching rates and in both 44.1-to-48 and 48-to-44.1 kHz directions.

## Before the sample-rate guard

`results.json` and `mixes.json` retain 104 decoded cases: all 52 matching-rate cases
pass; all 52 cross-rate cases fail. Both decoders return the exact planned timeline
sample count in every mix case. Maximum cross-rate amplitude error reaches
0.181815803. Excluding 64 frames at each edit edge still leaves constant-case
errors up to 0.019447761, so boundary transients alone do not explain the failure.

The bounds retain the original proof's float-amplitude budgets: 0.000002 for PCM
constant gain without conversion, 1/32768 for AAC or cross-rate constant gain, and
0.0001 for approximate piecewise fade ramps. The constant cross-rate budget is one
16-bit PCM code value (the generated input's quantization step); the fade budget
corresponds to about 3.28 such values and includes the existing nonlinear ramp
approximation. These are explicit fidelity requirements, not a mathematical claim
that independently implemented resamplers must agree. No bound was increased to
accept an observed error. Pass/fail includes every sample, without lag correction
or removal of edit boundaries.

`lag-diagnostics.json` diagnoses the constant cases over output frames 15,000–29,999.
In PCM mono, the estimated first-order fractional phase displacement is -1.6319
samples for 44.1-to-48 and +0.35636 for 48-to-44.1. Stereo and AAC yield essentially
the same estimates. Searching integer lags -16…16 finds -2 for the former direction,
reducing interior RMS from 0.00561731 to 0.00126414, still outside the budget. The
estimate uses a central-difference waveform derivative and least squares; it is a
diagnostic small-displacement approximation, not an exact delay measurement.

The FFmpeg compiler resamples the full source then trims on the output sample grid;
AVFoundation inserts the source-time range into a composition and converts that
composition. Direct whole-source `AVAssetReaderTrackOutput` conversion diagnostics
also disagree with FFmpeg and return 95,983/88,184 frames compared with
96,000/88,200. These source diagnostics concatenate returned buffers and do not
qualify resampled source timestamp placement or decoder latency. The evidence
establishes a production/reference discrepancy; it does not prove a universal
phase compensation or identify one portable fix for Apple's rate converter.

## Compressed packet-boundary starts

Twelve new matching-rate AAC cases pass: mono/stereo at 44.1/48 kHz, starting one
sample before, exactly at, and one sample after source packet PTS 12,288. FFmpeg
stream-copy `framecrc` tables retained as `source-*-packets.txt` establish that
packet's exact PTS and 1,024-frame duration with timebase 1/sourceRate. Cross-rate
packet cases use the nearest representable output sample and its neighbours; the
`packet-at` label in those cases is not a claim of an exact rational packet cut.
Maximum same-rate packet-case error is 0.000021949, below one s16 code value.
These are interior starts with a 35,003-sample unaligned end, not AAC priming/end
padding, arbitrary compressed codecs, or stream-copy qualification.

## Reproduction and retained artifacts

```sh
python3 scripts/system-audio-mix-proof.py /opt/homebrew/bin/ffmpeg \
  /private/tmp/new-audio-proof --include-aac --include-resampling --include-packet-cuts
```

`after-guard-results.json` records the final passing run: 52 matching-rate decoded
mixes pass their unchanged amplitude bounds and all 52 cross-rate cases are
explicitly rejected. `after-guard-mixes.json` retains case metadata and rejection
reasons; matching-rate reference commands remain included. The host run exits zero.

With the production sample-rate guard, add `--expect-resampling-rejection`. The
runner then accepts only the specific system-preview sample-rate rejection for
cross-rate cases and still decodes/compares every matching-rate case. Unexpected
acceptance or unrelated errors fail. The decoded pre-guard discrepancies remain
retained here; explicit rejection does not qualify resampling fidelity.

Build logs, FFmpeg version, commands, hashes, exact sample counts, direct codec/
conversion diagnostics and amplitude errors are retained. Generated media, raw PCM
and binaries remain in `/private/tmp/afc-system-audio-resampling-final-20261014`.
The initial sandbox media-reader failure (-11800 / underlying -1) is retained in
`sandbox-reader-failure.log`; successful decoding required host media-service access.
This offline proof does not qualify physical output, live/seek audio, A/V sync,
signed sandbox grants, or broader real-world AAC acceptance.
