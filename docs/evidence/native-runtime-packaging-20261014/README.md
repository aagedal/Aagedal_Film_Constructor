# Self-contained native development runtime (2026-10-14)

The production sequence controller now passes its native smoke from an ad-hoc
signed bundle containing the native runtime and all 16 transitive non-system
libraries. The smoke verifies original/proxy frame parity, nonzero representation
switching, exact seeks, play/sample-clock/pause, edit/replay and deactivation.
`DYLD_*` overrides are removed before execution; `DYLD_PRINT_LIBRARIES` records
actual loads. No build directory, Homebrew or `/usr/local` dependency is loaded.
This is the first relocated development bundle, not shipping Xcode integration.

The retained manifest records input paths/hashes, relocated dependencies, library
hashes, architectures and Mach-O deployment versions. The library closure includes
FFmpeg, OpenSSL, x264/x265, libvpx, SVT-AV1, Opus, LAME, mpg123, dav1d and xz.
The selected local libraries require macOS 26/27; the aggregate floor is macOS 27,
so this bundle cannot establish the app's intended macOS 14 compatibility.
Notices and source/build attribution remain explicitly unreviewed.

Reproduce with explicit notices/provenance and a fresh output directory:

```sh
python3 scripts/sequence-monitor-native-smoke.py \
  --pkg-config /absolute/path/pkg-config --ffmpeg /absolute/path/ffmpeg \
  --output /absolute/new/native-packaging-proof --build-workspace \
  --package-runtime-notices /absolute/notices \
  --package-runtime-provenance /absolute/provenance.txt
```

The runner builds an ordinary locally linked development workspace, then packages
both the smoke app and a separate `Packaged Native Workspace.app`. See its
`Contents/Resources/NativeRuntime/manifest.json`. The packager never mutates the
source app or libraries, refuses unresolved/ambiguous dependencies and filename
collisions, strips developer rpaths, checks architecture coverage, rewrites load
commands, signs nested code and verifies the complete bundle before publication.
The six packaging regressions cover cycles/aliases, collisions, ambiguous or
missing rpaths, loader-relative resolution, staging overlap and thin-architecture
admission. Universal binaries are explicitly refused: this development tool
inspects a single architecture.

Local verification artifacts were generated under
`/private/tmp/afc-native-self-contained-proof-20261014`; only text evidence is
committed. Initial restricted-sandbox execution failed when AVAudioPlayerNode
could not initialize the hardware format; unchanged host-service execution passed.
Unsigned system app builds remain AVFoundation-backed. Release dependency
selection, complete notices/corresponding source, macOS 14 libraries, signed
sandbox grants, distribution signing/notarization and measured A/V synchronization
remain open.

## Deployment compatibility enforcement follow-up

The packager now reads macOS deployment metadata from both modern
`LC_BUILD_VERSION` and legacy `LC_VERSION_MIN_MACOSX` load commands. Missing,
malformed or non-macOS deployment metadata is refused. Version comparison treats
`14`, `14.0` and `14.0.0` consistently. A stricter existing app or per-architecture
minimum is preserved; the packaged `LSMinimumSystemVersion` can never advertise
an OS below the actual dependency closure floor.

Use `--deployment-target 14.0` with `package-native-runtime.py` to require inputs
compatible with the intended macOS 14 baseline. This is a ceiling on the bundle's
minimum required OS, not a deployment-version rewrite of the libraries. It refuses
incompatible inputs before creating staging/output directories. The native runner
forwards the same constraint through `--package-runtime-deployment-target 14.0`,
which requires its explicit notices/provenance packaging options. Omitting the
constraint still records and declares the true minimum OS.

`deployment-summary.json` retains the re-packaged controller's input hashes,
relocated dependency lists, architectures, deployment versions, library hashes
and constraint. All three reported floors (`Info.plist`, manifest `minimumOS` and
`binaryMinimumOS`) are 27.0. It contains the native runtime plus 16 transitive
libraries; strict bundle signature verification passes. The same input with a
14.0 target fails with `Bundle requires macOS 27.0, exceeding deployment target
14.0`, leaving no output directory.

`deployment-packaged-smoke.log` retains the successful actual controller run from
`/private/tmp/afc-native-deployment-20261014/Packaged Native Smoke.app`. Developer
loader overrides are cleared; dyld observations contain the relocated runtime and
no Homebrew, `/usr/local` or build-directory library loads. Eleven packaging
regressions now cover modern/legacy metadata, malformed/missing/other-platform
refusal, semantic version ordering, stricter app minima, full staged publication
and pre-staging target refusal, alongside the earlier dependency checks.

Notices/provenance remain unreviewed, and `releaseCertified` remains false.
Accurate minimum-OS declaration and refusal do not supply macOS 14-compatible
libraries, release attribution or shipping Xcode integration.
