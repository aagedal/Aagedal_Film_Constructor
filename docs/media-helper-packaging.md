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
