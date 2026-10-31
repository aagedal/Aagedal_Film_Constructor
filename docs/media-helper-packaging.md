# Automatic media helper packaging

A fresh checkout builds with bundled FFmpeg and FFprobe automatically, in both
Debug and Release. Open the Xcode project and build: the existing helper phase
runs `bootstrap-media-helpers.py` when no local override is selected. The first
build downloads the signed Apple Silicon 9.0.2 ZIP from this repository's pinned
GitHub dependency release. `Configuration/MediaHelpers.json` records the exact
URL, archive SHA-256 and executable hashes. Preparation verifies signatures,
matching build configurations, capabilities and system-only dependencies before
publishing an ignored `.local/downloaded-media-helpers/` cache. Subsequent builds
validate and reuse that cache without network access. Concurrent builds share a
lock; failed downloads/preparations never become usable cached helpers.

A disposable checkout with no local settings/cache passes Debug and Release
builds; the Debug app passes production-bundle ProRes/H.264 proxy smokes, and
the actual prepared cache passes reuse with network requests blocked.

The first build needs internet access and macOS command-line tools/Python 3.
These pinned executables run on Apple Silicon. To seed the cache offline, run:

```sh
python3 scripts/bootstrap-media-helpers.py --archive /absolute/ffmpeg-9.0.2-full-signed.zip
```

Set `AFC_BUNDLE_MEDIA_HELPERS=NO` in Xcode build settings or on `xcodebuild` to
explicitly build without helpers. Download or integrity failures fail the build
with a diagnostic rather than silently shipping an app without media tools.

For a different matching helper pair, prepare explicitly selected FFmpeg and
FFprobe executables from the same build, with its notices and provenance:

```sh
python3 scripts/prepare-media-helpers.py \
  --ffmpeg /absolute/build/ffmpeg --ffprobe /absolute/build/ffprobe \
  --notices /absolute/build/notices --provenance /absolute/build/provenance.txt \
  --output /absolute/new/prepared-helpers
```

Preparation checks matching version/configuration, required render filters and encoders, and system-only dynamic dependencies. It rejects `--enable-nonfree`. The prepared directory records helper hashes, full version output, dependency lists, capabilities, archived notices and supplied provenance. Preparation never downloads helpers or verifies the accuracy/completeness of supplied licensing or provenance material. All manifests explicitly record unreviewed notices/provenance and `releaseCertified: false`.

Set the Xcode build setting `AFC_MEDIA_HELPER_DIR` to the absolute prepared directory. The copy phase verifies every prepared file hash, rejects links/unexpected files, copies to `Resources/Helpers`, and signs each helper with the app signing identity, hardened runtime and sandbox inheritance when signing is enabled. Leave the setting unset to use the pinned automatic helpers; set `AFC_BUNDLE_MEDIA_HELPERS=NO` to remove bundled helpers. Signing changes executable bytes; the manifest hashes identify the prepared input binaries, not the signed app copies. Do not mutate or re-prepare the directory while a build is copying it.

For local development, unknown source attribution or a mismatch against a previously attributed converter binary must be written explicitly into provenance. A filename, matching version string or copied converter notice alone does not establish matching build provenance. Release review still needs verified source/build attribution, complete notices and corresponding-source obligations where applicable, reproducible build records, helper/app signing and notarization, and an actual sandboxed export smoke test. This tooling does not certify release suitability.

Validate with a local prepared directory and a disposable build destination. No helper executables, generated prepared directories or local source archives should be committed.

## Persistent local Debug selection

After preparation, select that directory for this checkout's Debug builds:

```sh
python3 scripts/configure-local-media-helpers.py \
  --prepared-dir /absolute/prepared-helpers
xcodebuild -project 'Aagedal Film Constructor.xcodeproj' \
  -scheme 'Aagedal Film Constructor' -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/afc-local-media build
```

The configurator writes ignored `Configuration/LocalMediaHelpers.xcconfig`,
included optionally by the tracked Debug configuration. It works for Xcode's
Run action as well as command-line builds. Paths containing spaces are supported.
The build phase still verifies the entire prepared manifest before copying and
signing. Release uses the pinned automatic selection rather than this local Debug
override; explicit command-line `AFC_MEDIA_HELPER_DIR` selection also remains available.

Remove the local override with
`python3 scripts/configure-local-media-helpers.py --disable`, then rebuild to
return to the pinned automatic selection. Keep persistent prepared output
inside ignored `.local/` if desired, rather than relying on a temporary directory.

On 2026-10-12 the local matching static pair was found at
`/Users/truls.aagedal/Developer/ffmpeg-apple-silicon/dist/9.0.1/full/`.
Both report FFmpeg 9.0.1 and identical configure flags, with only Apple system
dynamic dependencies, so no dylib relocation is required for that pair. The
local Debug selection uses `.local/media-helpers`, prepared with the build's
README and local FFmpeg license files plus provenance explicitly recording
unverified source attribution and incomplete notice review. This is local test
material, not a release dependency. Homebrew helpers remain outside this flow:
their transitive non-system dylibs are rejected by the preparer.

Run `scripts/bundled-proxy-smoke.sh /absolute/built.app` after building. It copies
the built app's helpers into a disposable app harness and generates both available
proxy presets using the production `Bundle.main` lookup, with developer loader
paths cleared. It verifies raster, exact fractional frame rate/count and output
SHA256 while preserving the original fixture. This is an unsigned integration
test; it does not qualify signed sandbox execution or native UI gestures.

## Signed 9.0.2 local integration (2026-10-14)

The user-supplied `ffmpeg-9.0.2-full-signed.zip` contains both Apple Silicon
helpers, a build README, qualification metadata and a notarization report.
Extracted executable SHA-256 values match the qualification metadata:

- FFmpeg: `ec3d81944809bf5d0173edb77b8dbf8eaeabf2388289812ce87b3f90fbe410c6`
- FFprobe: `f2cabc2f9dbd8bd0325b4ed105cf434de9117ceda984bea1bf1e03450876d5ad`

Both pass `codesign --verify --strict` with host services. Signature checks in
this tool sandbox initially reported an invalid signature; the same unchanged
files validate outside the sandbox. The supplied report records accepted
notarization; online notarization was not independently checked here.

Preparation confirms matching version/configuration, required render capabilities
and system-only dynamic dependencies. This checkout's ignored Debug configuration
now selects `.local/media-helpers-9.0.2-signed`. The original archive and prepared
binaries remain outside version control. An unsigned Debug app build embeds the
pair successfully; its copy phase preserves the existing helper signatures.
The production-bundle proxy smoke passes both ProRes Proxy and H.264 presets
(24 frames at 24000/1001, 80×48 raster, verified SHA-256, originals preserved).
Signing an app build still applies the configured sandbox-inheritance entitlements
and signs the helpers with the app identity.

The export-service smoke also passes with this pair: verified MOV output,
CFR/VFR/offset and geometry qualification, resampling, failure reporting,
destination protection and cancellation cleanup.

The archived build README and qualification reports are retained as local provenance.
Complete dependency notices and corresponding-source review remain outstanding,
and the prepared manifest retains `releaseCertified: false`. These CLI binaries
support proxies and rendered export; they do not supply the FFmpeg-library bridge
needed for native sequence monitoring.

## Two FFmpeg copies (2026-10-31)

With the Debug-only native runtime selected, the app carries two FFmpeg builds: these
helpers, and FFmpeg linked statically into `libNativePlaybackRuntime.dylib` from the
pinned `aagedal/MPVKit` fork (`MPVKit-GPL`, 7f5d3f5). Normal and Release builds carry
only the helpers. `scripts/ffmpeg-copies-audit.py` compares the two:

```sh
python3 scripts/ffmpeg-copies-audit.py --helpers /absolute/prepared-helpers \
  --runtime /absolute/libNativePlaybackRuntime.dylib --helper-demuxers --json report.json
```

| | Helpers | Runtime |
| --- | --- | --- |
| Version | FFmpeg 9.0.2 release | `n9.0.2` tag (same release) |
| Licence | GPL v3 or later, no nonfree | GPL v3 or later, no nonfree |
| Configuration | "full" build: x264, x265, vpx, aom, SVT-AV1, vvenc, JPEG XL, WebP, Opus, Vorbis, LAME, Theora, OpenJPEG, VMAF, whisper; `yadif_videotoolbox` patch | MPVKit playback allow-lists plus `editor.1` additions: dav1d, uavs3d, libplacebo/Vulkan, lcms2, GnuTLS, smbclient |
| Components | 199 encoders, 530 decoders, 484 filters, 183 muxers, 366 demuxers | 45 encoders, 230 decoders, 67 filters, 13 muxers, 67 demuxers |
| Size | `ffmpeg` 60.1 MB + `ffprobe` 60.0 MB, each fully static | inside the 60 MB Debug runtime with libmpv; the GPL `Libav*`/`Libsw*` static archives total 39 MB for arm64 + x86_64 |
| Signing | separate executables, app identity, hardened runtime, sandbox inheritance | nested library sealed in the app (Debug only) |

`Configuration/FFmpegRequirements.json` records, per feature, what the app's
command lines use: export (`FFmpegRenderCompiler` and its audio effects), proxies,
conversion, the deshaken copy and noise reduction. `prepare-media-helpers.py`
now requires all of it, which adds `libx264`, `aac`, `hevc_videotoolbox`, `deshake`,
`afftdn`, the export audio-effect filters and the MP4/WAV/f32le muxers to the old
minimum. The pinned pair passes. The runtime's FFmpeg covers none of these features
in full: it lacks `prores_ks` and `libx264` (it has only `prores_aw` and the
VideoToolbox encoders), 20 export filters (`pad`, `setsar`, `settb`, `loop`, `anullsrc`,
`adelay`, `aeval`, `asetpts`, `fade`, `chromakey`, …), `deshake`, `afftdn`/`amerge`, and
the WAV and f32le muxers.

In the other direction, the runtime can decode every codec the helpers can except
AVS3 (`libuavs3d`), and it has one extra demuxer (`dash`). The runtime admits
unconverted imports and the helpers export them, so `MediaImporter.inspectNative` now
also requires every imported stream's codec to appear in the bundled
`Helpers/decoders.txt`. Otherwise the import falls back to conversion, as other
media the runtime cannot play does.

When native embedding is selected, the Xcode embed phase runs the audit against the
bundled helper listings (never executing the sandbox-inheriting helper copies). The
build fails if the versions or licences differ, if either copy is nonfree, or if the
helpers lack a required component. The report is written to
`Resources/NativeRuntime/ffmpeg-copies.json`.

### Consolidation options

- **In-process export through the runtime's libraries (rejected).** Export parity is
  defined by FFmpeg command lines, and `fftools` is not part of the libraries: option
  parsing, stream mapping, `-ss`/`-t` placement, filtergraph wiring, `-timecode`,
  `-movflags`, progress reporting. Rebuilding that in-process means requalifying every
  export path, and the runtime lacks the components anyway. The app would also lose
  process isolation (a crashing or leaking filtergraph would take the editor down) and
  terminate-to-cancel. Release has no runtime, so it would still need the helpers.
- **A helper dynamically linked against the runtime (rejected as stated).** The dylib
  exports the full FFmpeg API, so linking works. But each helper launch would load
  the Swift runtime, libmpv and MoltenVK, the components would still be missing, and
  Release would have to ship the runtime. A useful variant is FFmpeg as its own
  shared `libav*` dylibs, used by both the runtime and thin helper executables. That
  is the only option that saves size (about 120 MB of static helpers), but MPVKit
  publishes static XCFrameworks, so it needs fork changes first.
- **One FFmpeg build for both (recommended next step).** MPVKit's macOS build already
  compiles FFmpeg's programs (it passes `--enable-ffplay` and does not pass
  `--disable-programs`). Widening the fork's allow-lists to
  `FFmpegRequirements.json` and adding x264, then publishing that build's `ffmpeg`
  and `ffprobe` with notices as a signed release asset, would let `MediaHelpers.json`
  pin helpers from the same source, configuration and version as the runtime. The
  audit would then report no gaps. This changes the helpers Release ships (they would
  lose x265, VPX, AOM, whisper and other encoders the app does not use), so it waits
  for a product decision, a fork release, and helper signing and notarization.

Until then, the version, licence and requirement checks above stop the copies from
drifting silently, and the import check keeps runtime-admitted media exportable.
