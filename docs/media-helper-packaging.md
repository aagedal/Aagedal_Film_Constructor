# Opt-in media helper packaging

The application build contains no FFmpeg binaries by default. To opt in, prepare explicitly selected FFmpeg and FFprobe executables from the same build, with that build's notices and provenance:

```sh
python3 scripts/prepare-media-helpers.py \
  --ffmpeg /absolute/build/ffmpeg --ffprobe /absolute/build/ffprobe \
  --notices /absolute/build/notices --provenance /absolute/build/provenance.txt \
  --output /absolute/new/prepared-helpers
```

Preparation checks matching version/configuration, required render filters and encoders, and system-only dynamic dependencies. It rejects `--enable-nonfree`. The prepared directory records helper hashes, full version output, dependency lists, capabilities, archived notices and supplied provenance. Preparation never downloads helpers or verifies the accuracy/completeness of supplied licensing or provenance material. All manifests explicitly record unreviewed notices/provenance and `releaseCertified: false`.

Set the Xcode build setting `AFC_MEDIA_HELPER_DIR` to the absolute prepared directory. The copy phase verifies every prepared file hash, rejects links/unexpected files, copies to `Resources/Helpers`, and signs each helper with the app signing identity, hardened runtime and sandbox inheritance when signing is enabled. Leave the setting unset to remove stale bundled helpers. Signing changes executable bytes; the manifest hashes identify the prepared input binaries, not the signed app copies. Do not mutate or re-prepare the directory while a build is copying it.

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
signing. Release does not include this local configuration; explicit command-line
`AFC_MEDIA_HELPER_DIR` selection remains available for separate packaging review.

Disable the local selection with
`python3 scripts/configure-local-media-helpers.py --disable`, then rebuild to
remove stale helpers. Keep persistent prepared output
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
