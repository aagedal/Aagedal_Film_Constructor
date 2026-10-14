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
