# Media engine reuse audit

Observed locally on 2026-10-09. This records checkout evidence and a development
render proof; it does not certify a redistributable Film Constructor media bundle
or establish MPV timeline preview/export parity. No binaries were copied.

## Checked sources

All adjacent paths below are relative to `/Users/truls.aagedal/Developer/`.

| Checkout | Observed HEAD |
| --- | --- |
| `Aagedal-Media-Converter` | `e4b8cd2b2f790e2d1d502575cf0c392f79187214` |
| `Aagedal-Media-Player` | `d899408b4bfb1c4f345756c91480eb6537d3bc78` |
| `MPVKit` | `230c3174f1515898f24599147ad61c2a277d0dc2` |

Evidence was read from the working trees, including ignored build artifacts;
HEAD alone does not authenticate every artifact below. Commands used included
`git rev-parse HEAD`, `file`, `stat -f '%z'`, `shasum -a 256`, executable
`-version`, and `otool -L`. Release signatures were not verified by this audit.

## Executable availability

| Location | Observed bytes / identity |
| --- | --- |
| `Aagedal-Media-Converter/Aagedal Media Converter/Binaries/ffmpeg` | 54,661,504 bytes; arm64 Mach-O; FFmpeg 9.0.1; SHA-256 `25ee9d7ecd96c81b18cf5970e58201f4c94c4b1f5b4dea51c765aa28c639afd2` |
| `Aagedal-Media-Player/Aagedal Media Player/Binaries/ffmpeg` | 54,679,648 bytes; arm64 Mach-O; FFmpeg 9.0.1; SHA-256 `dc3770d91735cfe8b0ef8f4eb7c6f8431d722cca0d79c0959d62be216868d604` |

Both executables ran their version queries successfully. Both report
`--enable-static --disable-shared --enable-gpl --enable-version3` and neither
reported `--enable-nonfree` in its configuration. They are different artifacts,
despite matching version numbers. Converter's FFmpeg reports explicit Metal
toolchain paths; Player's reports a different build prefix and Metal command.
Converter's `otool -L` lists only Apple system frameworks and `/usr/lib` libraries;
that does not replace deployment-target, signing, or runtime verification.

Neither checkout's current `Binaries/` directory contains `ffprobe`.
Converter's `docs/4.5-ffprobe-packaging-review-2026-09-23.md` states that an older
Git-history FFprobe was built with `--enable-nonfree --enable-libfdk-aac` and must
not be restored for its redistributable release. This audit did not recover it.
The document describes a matching attributed 9.0.1 FFprobe candidate whose bytes
were unavailable at the time; this audit has not located or qualified that candidate.

The shell resolves `/opt/homebrew/bin/ffmpeg` and `/opt/homebrew/bin/ffprobe`.
No `mpv` executable resolved. Installed command paths are development facilities,
not bundled app dependencies, and their versions were not used for this proof.

## MPV and metadata integration evidence

- Converter's resolved package and `PackageAttributions.json` pin MPVKit
  `400202b687841fb394cbf0ef59ad8c6fcfc1275b`; Player resolves the older
  `230c3174f1515898f24599147ad61c2a277d0dc2`. Both use the `MPVKit-GPL` product.
  The local `MPVKit/Package.swift` at the latter revision describes MPV 0.41 /
  FFmpeg n8.1.2 GPL assets. This is a separate FFmpeg build from the command-line
  9.0.1 executable; codec/filter parity must be measured.
- Local `MPVKit/dist/release/Libmpv-GPL.xcframework.zip` and
  `MPVKit/dist/libmpv/macos/Libmpv.framework` exist. They were not hashed, loaded,
  or matched against either app's package pin. Existence is not suitability.
- Converter's `docs/4.5-mpv-coreaudio-failure-cleanup-validation-2026-09-26.md`
  records the `.2` CoreAudio candidate at `400202b…`, forced-failure cleanup,
  signed playback/teardown tests, and local signed Release validation. Earlier
  `.1` validation is historical; this later document explicitly supersedes it.
  Its distribution/notarization checks remain separate from local Apple Development
  signing. These are retained reports, not checks rerun by Film Constructor.
- Player's `docs/evidence/coreaudio-publication-preparation-20260930/README.md`
  describes a newer staged GPL/Metal package as unpublished, with the app still
  resolving `230c317…`. Its recorded staging directory
  `/private/tmp/aagedal-coreaudio-publication-prepared-20260930` was absent here.
  Do not select a package based on that historical temporary path.
- Both apps' source wrappers import `Libmpv` and use source load/seek and a single
  selected audio track. Player additionally applies `AudioChannelRouting` to that
  stream. Converter's callback-lifetime box and serialized destruction deserve
  review when extracting a minimal source controller. Neither wrapper proves
  simultaneous timeline clips, canonical mixing, or timeline graph invalidation.
- Both resolved files pin SwiftMediaMetadata 3.0.1 at
  `8662054299a3e13c49c65f74c564360559d1bf7f`. Converter's
  `Logic/VideoMetadataService.swift` imports it and applies bounded probes.
  Film Constructor must adapt stream identities and rational timestamps rather
  than import converter queue models.
- Player's `docs/RELEASE.md` states that App Sandbox is disabled and that library
  validation is relaxed for its native playback stack. Its file-access and
  entitlement choices cannot be assumed appropriate for this editor.

## Safe reuse and packaging work

Converter source headers identify `GPL-3.0-or-later`. Its package attribution
records MPVKit as `GPL-3.0-or-later` and SwiftMediaMetadata as
`GPL-3.0-only AND CC-BY-4.0`; the dependency manifest records FFmpeg as
`GPL-3.0-or-later`. Film Constructor has a GPLv3 license file. These are observed
notices, not a new licensing determination. Preserve copyright/SPDX headers for
extracted source and audit the exact chosen native build and its transitive
notices before distribution.

Converter's `BundledDependencies.json` names 89 source accompaniment archives;
all 89 paths existed locally when checked. Presence was checked, not every archive
hash or reconstruction. Its `Licenses/`, `PackageAttributions.json`,
`scripts/copy-sign-media-helpers.sh`, dependency-manifest tooling, and source
packaging scripts provide a concrete release model to adapt. Select only the
dependencies the editor needs; copying ten converter helpers is unnecessary.

Before enabling production media features:

1. Choose and pin the exact MPVKit package revision and FFmpeg artifact. Record
   SHA-256, architecture, deployment target, configure flags, actual decoders,
   encoders, filters, and bundle size. Recheck CoreAudio lifecycle in this app.
2. Acquire or build a matching attributed FFprobe if packet/stream probing needs
   it; otherwise implement explicit native metadata coverage and unsupported status.
   Never silently discover a user's command via `PATH` in the shipping app.
3. Bundle/sign helpers and all required linked libraries, ship matching notices
   and source accompaniment, and validate an extracted Release distribution.
   No such editor bundle was prepared by this audit.
4. Extract subprocess cancellation, bounded output/progress, scoped URL leases,
   and source-controller behavior into small editor services. Retest cancellation,
   bookmark ownership, teardown, unavailable helpers, and stream/channel identity.

## Reproducible development render proof

[`scripts/media-render-proof.sh`](../scripts/media-render-proof.sh) requires an
explicit absolute FFmpeg executable and a new output directory, plus Python 3.
It records executable version/hash, graph, logs, decoded frame hashes, decoded PCM,
and `result.json`. It does not install, discover, or copy the executable.

```bash
scripts/media-render-proof.sh \
  '/Users/truls.aagedal/Developer/Aagedal-Media-Converter/Aagedal Media Converter/Binaries/ffmpeg' \
  /private/tmp/film-constructor-media-proof-new
```

The standalone synthetic smoke render trims red and blue inputs at different
source in-points and places upper-track B at sequence time 2, where it wins the
overlap. It mixes three mono tones with different timeline offsets and left/right
routing, applies complementary quarter-sine audio crossfade envelopes during
sequence time [2, 3), and fades the third tone's edges. It writes ProRes HQ
with stereo PCM in MOV at 30000/1001 and drop-frame timecode `01:00:00;00`.
FFmpeg decodes the actual output to verify 180 frames at time base 1001/30000 and
288,288 samples per channel at 48 kHz (6.006 seconds). Frequency checks verify
440/880/1320 Hz presence/absence on both channels at 0.5, 1.75, 2.25, and 5 seconds;
measured crossfade amplitudes at 2.25 and 2.75 seconds match the expected envelope
within 50 signed-16-bit amplitude units. Decoded RGB pixels at frames 15, 75, and
150 (0.5005, 2.5025, and 5.005 seconds) verify red, blue, and blue track priority.
FFmpeg's demux log reads back the timecode.

The audit run passed with Converter's hashed executable at
`/private/tmp/film-constructor-media-proof-overlay-20261009`. The proof verifies
render timing and selected synthetic audio routing. Static color sources do not
visually qualify source in-points, and this script does not validate a general
editor render-plan compiler, prove sandboxed helper
access, or measure startup/performance. It has no MPV preview parity result.

## Next source/timeline parity proof

Before expanding timeline UI, use a minimal signed development harness with the
chosen pinned MPVKit package:

1. Generate moving/frame-numbered sources plus impulse/tone multistream audio.
   Retain exact source timestamps and expected samples; include 30000/1001,
   24000/1001, and 25 fps fixtures, and at least one MXF/broad-format sample.
2. Prove source load, selected-stream monitoring, precise seek, fast scrub followed
   by precise seek, frame step, pause/resume, and repeated teardown. Check actual
   audio output; a progressing video clock alone is insufficient.
3. Compile one canonical timeline description into both export and proposed MPV
   graphs: two overlapping videos with different source ranges, multiple selected
   audio streams, channel mapping, upper-video-track priority, gap, cut, and audio
   crossfade. Seek before/inside/after
   overlap, scrub backward, and invalidate/rebuild after an edit.
4. Capture monitored frames and PCM segments at specified rational sequence times,
   compare them with FFmpeg render output using declared pixel/audio tolerances,
   and record frame/sample offsets, errors, latency, and both engine capabilities.
   Keep display color transforms distinct from compositor comparisons.
5. Accept MPV sequence monitoring only if graph rebuilding, clock continuity,
   exact seeking, simultaneous stream routing, and repeatable parity pass. If they
   fail, retain MPV for sources and evaluate an FFmpeg library bridge with native
   rendering/audio scheduling for sequences, as specified in `PLAN.md`.

## Render-plan compiler proof (2026-10-09)

`FFmpegRenderCompiler` now generates an argument array and filter graph from
`TimelineRenderPlan`. The standalone `RenderPlanProof` development executable
creates, saves, decodes, and compiles a fixture project; it is not an app helper.
`scripts/render-plan-proof.py` creates lossless frame-coded video and two separate
mono audio streams, executes the compiler's arguments without a shell, records
helper hashes/versions, and probes/decodes the rendered MOV. Reproduce with:

```sh
scripts/render-plan-proof.py \
  '/Users/truls.aagedal/Developer/Aagedal-Media-Converter/Aagedal Media Converter/Binaries/ffmpeg' \
  /opt/homebrew/bin/ffprobe \
  /private/tmp/film-constructor-render-plan-proof-new
```

The run at `/private/tmp/film-constructor-render-plan-proof-20261009-v3` passed:
180 frames, 30000/1001, 160x90, 288,288 stereo samples at 48 kHz, and MOV
timecode `01:00:00;00`. Eleven frame checks include both sides of the upper layer's
start/end and source in-points; whole-frame colors change every frame to expose
off-by-one selection. Mean RGB errors were 1–2.67 byte values after ProRes
encoding (tolerance 12). Audio uses stream 2 on left and stream 1 on right with
0.5 static gain, with exact zero PCM outside sample interval [48048, 240240).

The experiment caught the overlay ending one frame early with `repeatlast=0`;
the compiler now retains the last frame and explicitly limits layer visibility
to the clip's half-open range using integer sequence frame indices. Placement uses integer frame offsets after `fps`
to avoid floating-point `start/TB` truncation. FFmpeg's documented
[`fps`, `overlay`, `pan`, and audio filters](https://ffmpeg.org/ffmpeg-filters.html)
provide the filter semantics; decoded fixtures provide the integration evidence.

Current compiler subset: originals, local MOV/ProRes HQ + PCM, even raster,
mono/stereo output, frame-aligned video, sample-aligned audio, and zero stream
offsets. Video uses explicit sequence-grid `fps` with nearest timestamp rounding
before source trim. Fit/fill/none graph generation exists; only square-pixel SDR
fixtures at fit have been qualified. Stills and nonzero stream offsets are rejected.
Geometry/color metadata and VFR mapping cannot yet be validated from this model.
Missing originals and invalid maps fail compilation; existing output is protected
by `-n`. Helpers remain supplied explicitly by the development runner, with no
shipping dependency on Homebrew or `PATH`. Hashes/versions for the separately
supplied development FFprobe are recorded alongside FFmpeg, without asserting
that they form a matched redistributable bundle.

This is a canonical-plan export proof, not MPV monitoring parity or a completed
export service. Crossfades remain demonstrated only by the earlier handwritten
smoke graph; they are not yet represented by EditorCore or this compiler.
