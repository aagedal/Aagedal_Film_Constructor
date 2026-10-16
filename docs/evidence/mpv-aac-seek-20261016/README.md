# MPV AAC decoder and initial-seek isolation — 2026-10-16

This continues the [audio range/demuxer controls](../mpv-audio-controls-20261016/README.md).
The generated fixtures, two stream identities, six ranges, exact counts and
mean/peak amplitude limits of 1e-6/1e-5 stay unchanged. No application source
backend or format admission changes.

## Decoder controls

`--aac-decoder aac|aac_fixed|aac_at` selects only the requested AAC decoder and
disables fallback. Successful captures must also contain exactly one observed
`Selected decoder` log matching that name. Other codecs retain automatic decoder
selection. The default remains `auto`.

Three complete AddressSanitizer matrices with integer filtering and forced lavf
retain 288 comparisons and 48 explicit wrong-kind/missing-stream rejections.
Each passes PCM/ALAC/MP3 24/24 each, while AAC remains 0/24, for 72/96 overall.
Forced software `aac` repeats the original content errors; `aac_fixed` does not
resolve them. Forced `aac_at` cannot initialize on these fixtures and reports
AudioToolbox header-parse error -9405. That failure is retained rather than
silently falling back to another decoder.

## Direct embedded-library control

`--embedded-reference` compiles a separate diagnostic against the same pinned
cached static media-library closure. It bypasses MPV and decodes each selected
AAC stream with software `aac`, including when MPV uses a different forced
decoder. It drains the decoder fully and converts same-rate mono/stereo to packed
float32. Explicit frame skip/discard metadata is applied; missing padding is never
inferred from nominal duration. It checks output writes and rejects unexpected
conversion delay. Both executables are AddressSanitizer-instrumented; cached
archives remain uninstrumented.

The unseeked direct path reports 1024 skipped priming samples and no discarded
tail samples for each stream. Natural output still exceeds the independent
FFmpeg 9 reference by 820 samples at 44.1 kHz or 384 at 48 kHz. All four natural
exact-count comparisons therefore fail. This is a separate tail-boundary issue,
not a complete faithful AAC decode qualification.

For the 20 explicitly requested bounded reference ranges, unseeked direct AAC
matches the independent external reference within the unchanged limits. Maximum
per-channel mean error is 5.12973e-9; maximum sample error is 8.94070e-8. These
are reference-only integer slices, like the existing external reference ranges;
no captured MPV output is aligned, padded, trimmed or repaired by the comparator.
MPV disagrees with the unseeked embedded reference in all 24 cases.

A second direct control performs
`av_seek_frame(format, selectedStreamIndex, 0, AVSEEK_FLAG_BACKWARD)` before
opening the decoder. It reports zero skipped priming samples. This specific
seek control reproduces all 24 MPV captures exactly, including all four full
natural outputs. `captureVsSeekZero` retains the per-case exact-count and
amplitude checks; `capture-hashes.json` independently verifies byte equality
using hashes of complete captures and the explicitly requested reference ranges.
The original external-reference `passed` results remain false for all AAC cases.

This demonstrates that an initial selected-stream seek is sufficient to reproduce
the AAC content divergence using the embedded libraries without MPV's decoder,
filters or PCM sink. MPV logs also show an initial refresh seek to zero, but this
control does not establish every detail of MPV's seek implementation. Missing
preroll is implicated; prediction/noise-generation state, a reliable preroll fix,
and final discard-padding handling remain unresolved. No efficient random
access, asynchronous source seeks, CoreAudio/GPU presentation, hardware sync,
proxy composition, signed sandbox access or runtime distribution is qualified.

## Evidence and reproduction

The four named reports retain commands, source/fixture/dependency/executable
hashes, comparison results and nonzero qualification outcomes. Representative
logs show decoder selection/failure, priming counts and refresh seeking. Full
fixtures/captures/logs remain in the temporary paths recorded by the reports.
The final `embedded-reference.json` source hashes match the committed scripts.

```sh
python3 scripts/mpv-audio-proof.py --sanitize-address \
  --range-mode sample-filter --demuxer lavf --embedded-reference \
  /absolute/path/to/MPVKit \
  /absolute/path/to/SourcePackages/artifacts/mpvkit \
  /absolute/path/to/ffmpeg /private/tmp/afc-mpv-aac-new
```

Use a fresh output path for each run. To reproduce decoder controls, replace
`--embedded-reference` with `--aac-decoder aac`, `aac_fixed`, or `aac_at`.
Requires the same explicit pinned cached dependencies and macOS 27/Xcode setup
as the earlier proof; no downloads occur. Each broad matrix intentionally exits
1 because AAC remains unqualified. Python regression tests and independent code
review pass; this change affects proof tools and documentation only.
