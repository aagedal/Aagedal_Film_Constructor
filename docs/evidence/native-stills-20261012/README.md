# Native still-image qualification, 2026-10-12

The development native monitor passed baseline plus twelve PNG-alpha/JPEG still
variants against independently compiled FFmpeg exports. Images are 80×90 and
240×90 in a 160×90, 30000/1001 sequence, with fit/fill/none. Each variant checks
all 180 sequential and asynchronous video frames, mixed/scheduled/asynchronous
PCM, ten reverse/repeated/rebuilt raw/PNG/asynchronous video seeks, thirteen
audio seeks, the offline transport clock and primed plan replacement. Still
source trims deliberately start off the video frame grid: they retain image
frame zero. Visibility remains half-open at frame 3 and frame 120.

Maximum per-frame mean RGB error against ProRes export was 3.371 on the 0–255
scale, below the existing threshold of 12. Active-picture comparisons exclude
padding. A separate integer straight-alpha oracle checks every occupied pixel
on the no-scaling PNG cases against deterministic RGBA fixture pixels and
independently decoded lower-layer barcode frames. Transparent, partial and
opaque coverage each had maximum channel error **zero**: 336,960 / 252,720 /
252,720 pixels for the smaller image and 589,680 / 505,440 / 589,680 for the
cropped larger image. This oracle does not average away an alpha failure.

A separate geometry regression passed baseline plus the nine prior video
fit/fill/none cases, including odd-sized sources. Its retained result is
`geometry-regression-result.json`; full working outputs remain at
`/private/tmp/afc-native-still-geometry-regression-20261012`.

The final native runtime run passed 32 tests in six suites. Still regressions
cover transparent padding, cropping, retained PNG/JPEG frames, preserved PNG
alpha, concatenated PNG/JPEG rejection, GIF/APNG disguised with a `.png` suffix,
invalid stream selection, and alpha-bearing image rejection through the motion
video decoder. EditorCore passed 72 tests, including still layering, synthetic
in points, half-open cuts and unsupported still stream offsets.

Reproduce with explicit local libraries and an existing barcode fixture:

```sh
python3 scripts/native-sequence-proof.py \
  /opt/homebrew/bin/ffmpeg /opt/homebrew/bin/ffprobe /opt/homebrew/bin/pkg-config \
  /private/tmp/film-barcode-render-20261009 \
  /private/tmp/new-native-stills-proof --stills-only
```

The proof needs macOS offline audio services. The first sandboxed attempt aborted
in AVAudioEngine initialization; the passing run used approved access to those
services. Passing full outputs remain at
`/private/tmp/afc-native-stills-qualified-20261012`. Only lightweight results,
commands, identities, manifests and logs are retained here. Generated source
image hashes are in `still-source-identities.json`.

`source-manifest.json` records the proof build snapshot. The supplemental final
runtime log and `final-source-manifest.json` include subsequent GIF/APNG and
concatenated-JPEG rejection assertions. Subsequent production-source edits were
comments; the proof runner additionally records generated-source identities in
future runs. Decoding and composition behavior did not change after the parity
run.

Qualification is limited to these square-pixel SDR PNG/JPEG fixtures and their
straight-alpha composition. The decoder admits only one PNG/JPEG image stream
and verifies that decoding yields exactly one frame; animations, other image
formats, container video disguised as an image and alpha-bearing motion video
fail explicitly. Linear-light composition, general color management, source
orientation/PAR, broad image formats, live hardware synchronization and signed
redistribution remain unqualified.

The live session's 8 MB output cache excludes source decoder state. Up to 64
source decoders can retain their own frames, including one decoded image per
still. Source probing runs before codec raster limits, so its allocations are
not bounded by the explicit frame/audio conversion limits. These are development
bounds, not a measured total-memory guarantee or startup performance claim.
