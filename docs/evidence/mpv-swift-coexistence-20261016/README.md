# Asynchronous MPV and Swift sequence sessions — 2026-10-16

The private asynchronous MPV source bridge now passes a concurrent Swift 6
main-actor exercise alongside the public `NativePlaybackSession` actor. Ordinary
app builds continue to use AVFoundation for source playback.

The runner rebuilds and qualifies the bridge first, then builds a fresh native
runtime from snapshotted package sources. It runs the same native requests in
separate native-only and concurrent processes. MPV remains behind its nine-function
private ABI; no media-library types or borrowed allocations cross it.

The retained AddressSanitizer run verifies:

- 120 native picture/audio pairs per process through `NativePlaybackSession`,
  its epoch checks and serial decode worker. C decoder exports are not called
  directly. The cache is disabled so repeated coordinates require decoding.
- Native RGB and 1024-sample mono float blocks match the native-only process
  byte for byte. Every picture is also checked against independent FFmpeg with
  unchanged mean/peak RGB limits of 3/32; every audio sample matches FFmpeg exactly.
- 12 plan replacements alternate source trims by six frames. In the concurrent
  process MPV is already loaded when replacement occurs. All 11 previous epochs
  are refused; subsequent decoded coordinates reflect the new trim.
- 12 MPV create/open/play/pause/rapid-seek/close cycles and 60 independently
  compared forward/backward/repeated grayscale captures pass existing bounds.
  Maximum MPV mean RGB error is 1.8199132 and peak component error is 3; native
  RGB matches the independent reference exactly in this fixture.
- Timestamped native completions occur inside each cycle's MPV command window.
  The retained run has 88 overlapping frame/audio completions (6–8 per cycle).
  Each window begins after source opening and ends before awaiting the native
  task, so waiting for that task cannot manufacture overlap.
- Native requests finish with no pending work or cached bytes. Repeated session
  close and refusal of decoding after close pass. Errors cancel and join the
  native task, and ownership-level source destruction also releases MPV workers
  when an error or cancellation bypasses explicit close.

The bridge and Swift clients are AddressSanitizer-instrumented, as are the native
Swift/C targets built for this run. Prebuilt MPV archives and dynamic FFmpeg
libraries remain uninstrumented. The earlier C coexistence proof retains both
library load-order/address checks; this run qualifies Swift session coordination.
It does not establish in-flight replacement/cancellation behavior, live hardware
output, decoded MPV audio, GPU display, physical synchronization, color parity,
proxy composition, signed sandbox media access, library unloading or application
integration. The colored source matrix still fails. Redistribution, notices,
release signing and packaging remain open.

`result.json` retains build/run commands, source/dependency hashes, prerequisite
bridge results, timestamp windows and all comparisons. `native-only-report.json`
and `concurrent-report.json` retain Swift observations. Full fixtures, sources,
logs and binaries remain at the absolute temporary paths recorded in the result.

## Reproduce

Use a clean pinned checkout, its extracted artifact cache, explicit executables
and a new output directory. The runner downloads nothing and changes no app code:

```sh
python3 scripts/mpv-swift-coexistence-proof.py --sanitize-address \
  /absolute/path/to/MPVKit \
  /absolute/path/to/SourcePackages/artifacts/mpvkit \
  /absolute/path/to/ffmpeg /absolute/path/to/pkg-config \
  /private/tmp/afc-mpv-swift-coexistence-new
```

Requires macOS 27, Xcode and native FFmpeg development libraries discoverable by
the selected pkg-config. Omit `--sanitize-address` for an uninstrumented run.
