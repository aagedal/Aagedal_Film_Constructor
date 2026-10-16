# Embedded AAC priming-packet and frame-duration controls — 2026-10-16

This continues the [initial-seek isolation](../mpv-aac-seek-20261016/README.md).
The same generated two-stream MOV fixtures, six source ranges, exact sample
counts and mean/peak amplitude limits of 1e-6/1e-5 remain in force. MPV captures
and the comparator are unchanged. Application source playback remains AVFoundation.

## Separate direct-library controls

`--embedded-reference` now runs four fresh software-AAC decoder instances per
selected stream against the same cached static FFmpeg closure as MPV:

- Unseeked: explicit decoder skip/discard metadata only, preserving the baseline.
- Seek zero: selected-stream backward seek to timestamp zero, preserving the
  control that reproduces MPV's AAC captures.
- Seek first packet: read until the first selected packet, retain its observed
  PTS, then seek backward to that PTS before opening the decoder. No fixed
  preroll amount is assumed. The harness checks the first returned selected
  packet has that timestamp; duplicate timestamps would not prove packet identity.
- Seek first packet plus frame duration: additionally limit decoded output to
  the explicit decoded-frame duration, converted exactly from stream timebase
  to samples. Nonintegral or skip-incompatible durations fail. Missing duration
  does not cause a guessed trim; nominal source duration is never used.

The direct program reports first/last selected packet timestamps, last packet
and decoded-frame duration, decoded frame sample count, skipped/discarded samples
and samples removed by the optional duration control. The baseline controls do
not apply frame-duration clipping. All conversions remain same-rate float32.

## Results

Seeking to the observed first packet returns PTS -1024 and restores the decoder's
1024-sample priming skip on all four selected streams. Its complete natural
output hashes equal unseeked decoding byte for byte. This isolates a working
source-head control for these generated fixtures; it is not efficient random access.

Without the duration control, all four natural outputs still have excess tails.
At 44.1 kHz, the last decoded frame contains 1024 samples but its packet/frame
duration is 204 samples, accounting for the extra 820. At 48 kHz, duration is
640 samples, accounting for the extra 384. The decoder reports no discard-side-data
samples. Applying the explicit frame duration removes exactly these excess samples.

The combined first-packet/duration control passes **24/24 direct AAC comparisons**:
four natural complete outputs and twenty bounded whole/head/packet-edge/tail
reference slices. Natural outputs contain exactly 132300 samples per channel at
44.1 kHz or 144000 at 48 kHz. The maximum per-channel mean error is below 5.13e-9;
maximum individual error is below 8.95e-8. Reference slicing uses only requested
integer coordinates. MPV captures are never aligned, padded, trimmed or repaired.

The actual MPV matrix remains **72/96**, with PCM/ALAC/MP3 24/24 each and AAC 0/24.
All 16 wrong-kind/missing-stream rejections pass. Every AAC MPV capture still
matches the seek-zero control within the unchanged bounds. The overall report
and runner intentionally retain a failing qualification result (exit 1).
The new direct controls have not been implemented in MPV or the async bridge.
Color, efficient in-place audio seeks, CoreAudio/GPU presentation, hardware sync,
proxy composition, signed sandbox access and distribution remain open.

## Evidence and reproduction

`result.json` retains commands, dependency/source/executable hashes and all
positive/negative comparisons. Representative direct-control logs retain the
reported boundary metadata. `capture-hashes.json` independently checks complete
first-packet/unseeked byte equality and MPV/seek-zero range byte equality.
The complete temporary fixtures, logs, executables and captures remain at the
paths in the report. AddressSanitizer covers the new executables; cached library
archives remain uninstrumented. The final source hashes match the committed scripts.

```sh
python3 scripts/mpv-audio-proof.py --sanitize-address \
  --range-mode sample-filter --demuxer lavf --embedded-reference \
  /absolute/path/to/MPVKit \
  /absolute/path/to/SourcePackages/artifacts/mpvkit \
  /absolute/path/to/ffmpeg /private/tmp/afc-mpv-aac-preroll-new
```

Use a fresh output path and the pinned cached dependencies described by the
previous proof. No downloads occur. Verification also includes 36 MPV Python
regression tests and independent code review; review wording findings were fixed.
