# Open-GOP system random-access diagnosis — 2026-10-14

Open-GOP HEVC remains unqualified. A bounded experiment separates source decoding,
composition still generation, composition-reader seeking and the paused player's
video output. No experimental capture workaround was added to production.

The four existing 96-frame open-GOP barcode fixtures from the
[system codec matrix](../system-sequence-20261014/README.md) were checked at 24,
24000/1001, 30000/1001 and 60000/1001 fps on the same macOS 27.0.1 / Apple Silicon
host. Fixture SHA256 values remain recorded in that matrix's results.json.
The diagnostic inserts the **entire untrimmed picture track** at timeline zero,
with one identity video-composition layer, so a trimmed insertion alone cannot
explain the failures. Retained per-rate JSON records independently decoded stripe
levels, returned timestamps and errors.

All four rates gave the same observations:

- Source frame 60: direct source image generation, exact composition-reader
  capture and paused AVPlayerItemVideoOutput decode the correct barcode.
  AVAssetImageGenerator with a video composition returns black.
- Source frame 70: direct source image generation fails with AVFoundation -11821
  and underlying OSStatus -12911. The composition image generator, exact
  composition-reader capture and paused player output return black at the
  requested timestamp without reporting that source-decoder error.
- Reading the composition sequentially from zero, or starting 24 source frames
  before the requested point, correctly decodes frames 60 and 70.

A temporary production-backend experiment replacing seek image generation with
an exact one-frame AVAssetReaderVideoCompositionOutput range passed the first
trim boundary but failed the existing 24 fps matrix at timeline frame 11 / source
frame 70. It was discarded. A fixed preroll window is also insufficient evidence
for arbitrary GOP lengths/dependencies; reading from zero would make seek work
unbounded with source duration. Neither approach is an accepted preview fix.
The paused-player failure means replacing still capture alone would also leave
transport random access unqualified.

Additional exploratory checks at 24 fps returned black for a full source track,
a source asset plus video composition, and disabled instruction postprocessing.
Composition without video composition decoded source frame 60 correctly.
Attempting to insert source preroll at a negative composition time was rejected
with OSStatus -12780. These exploratory variants are not part of the retained
reproduction script and do not establish support for other GOP structures.

Reproduce the retained diagnostic after generating the matrix fixtures:

```sh
swiftc -swift-version 6 -parse-as-library \
  -module-cache-path /private/tmp/afc-open-gop-module-cache \
  scripts/system-open-gop-diagnostic.swift -o /private/tmp/afc-open-gop-diagnostic
/private/tmp/afc-open-gop-diagnostic \
  /absolute/matrix/output/hevc-open-gop-aac-24-1.mov 24 1
```

Use the other fixture filenames and rational rate arguments for fractional rates.
Run with host media-service access; a restrictive sandbox produces unrelated
system decoder failures. The script intentionally reports failing observations
as JSON with exit zero, because it diagnoses a known unsupported fixture rather
than declaring a passing qualification. Its fixture scan is capped at 97 samples
and paused-player capture waits at most 500 ms per point. The legacy synchronous
image-generator call is diagnostic only; no production UI path uses this script.

Verified proxy picture or the native FFmpeg runtime remains the broader-format
path. Hardware synchronization, actual live playback through these boundaries,
other GOP configurations, minimum-OS behavior and signed sandbox access remain
open. Container keyframe flags alone do not prove safe open-GOP random access.
