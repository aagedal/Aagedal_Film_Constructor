# Native video spatial conform proof

Development evidence retained from `/private/tmp/afc-native-geometry-final-20261012`.
Media and decoded buffers remain temporary artifacts. Reproduce with:

```sh
python3 scripts/native-sequence-proof.py \
  /absolute/path/ffmpeg /absolute/path/ffprobe /absolute/path/pkg-config \
  /absolute/path/passing-barcode-fixture /absolute/path/new-output --geometry-only
```

Baseline plus nine spatial variants pass: 80×90, 240×90 and 81×91 sources using
fit, fill and none in a 160×90 sequence at 30000/1001. Each variant independently
renders through the EditorCore FFmpeg compiler into ProRes/PCM, then compares all
180 native synchronous/asynchronous frames and 288,288 stereo samples per channel.
Ten video seeks, thirteen audio seeks, native PNG capture, offline audio scheduling
and 282 sample-clock transport observations also pass. Geometry variants replace
an already-used matching-raster plan, exercising decoder/cache invalidation.

The source fixtures use lossless RGB FFV1 with square pixels, barcode columns and
asymmetric red/blue bands. Active-picture comparisons exclude black padding so
padding cannot dilute a picture mismatch. Maximum whole-frame mean RGB error is
2.0; maximum active-picture mean error is 1.994, below the original tolerance of
12. Maximum audio error is 0.5 s16 units. Original 300-frame barcode identities
are authenticated before deriving the geometry fixtures.

All 20 native runtime tests passed. Source/intermediate/sequence rasters have
4096-per-dimension limits; extreme fill aspect ratios fail before allocation.
The fixtures establish scoped spatial parity, not universal pixel/color identity.
Subsampled-source edge alignment, arbitrary color tags, rotation, anamorphic/VFR
sources, still alpha, proxies, compressed audio and resampling remain unqualified.
These captures use offline AVAudioEngine, without measuring hardware A/V sync.
The local FFmpeg dylibs were built for macOS 27; this is not a signed shipping
dependency bundle or evidence of macOS 14 compatibility.

`result.json` retains comparison metrics and artifact hashes. `identities.json`
records actual tools/libraries, `commands.json` records executed commands, and
`source-manifest.json` binds the proof to source bytes. Native system audio-component
registration required running outside the restricted tool sandbox.
