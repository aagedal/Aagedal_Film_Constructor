# Private MPV / native FFmpeg coexistence — 2026-10-16

The pinned cached MPVKit candidate now coexists with a freshly built
`NativePlaybackRuntime` in a standalone process. This qualifies the finite local
dependency-isolation experiment, not application integration or shipping builds.

`scripts/mpv-coexistence-proof.py` builds the static MPVKit closure into a private
dylib with exactly two exported proof entry points. MPV and its FFmpeg APIs are
hidden. The host itself links neither media engine; it loads the private MPV
image and the native runtime through a small native binding probe, in both
orders. The native Swift runtime is built from snapshotted repository sources
with the explicitly selected pkg-config libraries. Its exported CNativeDecoder
functions perform the native decoding; Swift playback coordination is not exercised.

The following checks pass:

- `nm` reports exactly the two allowed MPV exports. `dlsym` cannot discover
  `mpv_create` or `avcodec_version` through that private image.
- Actual function addresses for avformat, avcodec, avutil, swresample and
  swscale resolve inside the private MPV image for FFmpeg 8.1.2, and inside
  the selected dynamic FFmpeg 9.0.2 libraries for native decoding. Both load
  orders preserve these bindings; native versions match pkg-config.
- An independent native-only process establishes the baseline. Both concurrent
  runs produce byte-identical native RGB frames and float audio for the first
  120 forward/backward/repeated requests. Every later request also matches its
  retained first-pass frame/sample bytes. PCM output additionally matches
  independent FFmpeg decoding exactly; baseline picture meets the unchanged
  RGB mean/peak limits of 3/32.
- Each concurrent run completes four MPV create/load/play/pause/destroy cycles
  and 20 exact seek captures. All 40 grayscale MPV captures match independent
  FFmpeg frames within the same 3/32 bounds. Native completion timestamps must
  fall inside MPV execution for either concurrent run to pass; a worker starting
  only after MPV returns is rejected.

The fixture is a three-second 320×180 24 fps grayscale ProRes MOV with two
48 kHz mono PCM streams. Native decoding explicitly selects picture stream 0
and audio stream 2, repeatedly seeking frames 0, 36, 6, 48 and 12 and the
corresponding 1,024-sample audio ranges. Exact iteration/overlap counts, commands,
source/archive/executable hashes, runtime hash, dependency-image hashes and all
pixel comparisons are retained in `result.json`.

MPV output sinks remain null. This does not qualify colored picture, decoded MPV
audio, CoreAudio, GPU presentation, physical synchronization, Swift sequence
coordination, callback lifetime/unloading, proxy composition or sandbox grants.
The native and MPV bridges are closed only after the worker joins and all MPV
players have been destroyed. The separate colored source matrix still fails.
The private export list is an integration constraint, not an app packaging change;
ordinary builds continue to use AVFoundation for source playback.

## Reproduce

Supply absolute paths to the clean pinned checkout, extracted artifact cache,
development helpers and a new output directory:

```sh
python3 scripts/mpv-coexistence-proof.py \
  /absolute/path/to/MPVKit \
  /absolute/path/to/SourcePackages/artifacts/mpvkit \
  /absolute/path/to/ffmpeg /absolute/path/to/pkg-config \
  /private/tmp/afc-mpv-coexistence-new
```

Requires macOS 27, Xcode and the already available dependency closure. It does
not download, modify a dependency checkout, change the app, or install libraries.
Generated media, snapshots and binaries remain at the output path in the report.
Extracted MPV archive bytes are hashed; missing original zip files are not
reauthenticated. Distribution, attribution and signed sandbox qualification remain open.
