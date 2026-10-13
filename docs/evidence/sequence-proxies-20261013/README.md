# Qualified native sequence proxies — 2026-10-13

The global HiRes/Proxy preference now reaches the opt-in native sequence monitor.
The normal Xcode build still reports the missing native runtime. Qualification uses
local unsigned macOS runners with Homebrew FFmpeg and native audio services;
shipping runtime packaging, signed sandbox behavior and physical A/V sync remain open.

## Verified behavior

- Runtime: all 46 tests pass, including three new proxy tests. Explicit video
  selections preserve the original render plan, geometry and audio. A lossless
  half-resolution fixture uses original video stream 1, proxy stream 0 and original
  mono PCM. Trimmed forward/backward reads match HiRes in fit/fill/no-scaling;
  session replacement rejects old epochs and invalid metadata preserves the old
  epoch/cache. Solid-color geometry fixtures expose wrong temporal selection and
  no-scaling extent; they do not qualify perceptual quality on detailed footage.
- Controller: independent FFmpeg RGB captures match original and intentionally
  distinct proxy picture at 0.5 seconds/frame 12, then restored HiRes. Every byte
  is within two levels. Playback switches leave the document and original-only
  render command unchanged. Actual native sample-clock playback, stable pause,
  edited-plan seek/replay and deactivation pass.
- Lifecycle: injected delayed backends check nonzero playhead preservation, immediate
  pause on switching, resolved status, cancellation on rapid toggles and hiding,
  and reactivation with the latest preference. Decoder/scope ownership drains
  through awaited shutdown. Native close now waits for serial decoder teardown;
  concurrent/cancelled close callers share the same drain barrier. Blocked-read
  tests prove decoder release occurs before close returns.
- Resolver: real generated ProRes proxy checks pass with nonzero source ranges,
  persistence, original preference and no document mutation. Missing/stale/modified
  files, legacy hashes, missing originals, uncovered tails, wrong source streams,
  mismatched aspect and cancellation fall back to originals or reject cancellation.
  Unused missing bin media is ignored. Integrity streams bounded chunks off the
  main actor, one file at a time; original freshness uses size/modification time.
- Repository verification: 44 Python tests (eight optional skips), 93 XCTest cases
  (two optional skips), 82 Swift Testing cases, workspace policy smokes and unsigned
  Debug build pass. The isolated actual SwiftUI workspace links the native runtime
  and builds successfully. Release validation is recorded in the build summary.

## Reproduction

```sh
scripts/verify.sh
scripts/proxy-workspace-smoke.sh
python3 scripts/sequence-monitor-native-smoke.py \
  --pkg-config /opt/homebrew/bin/pkg-config \
  --ffmpeg /opt/homebrew/bin/ffmpeg \
  --output /private/tmp/afc-sequence-proxy-proof --build-workspace
```

Native SwiftPM testing requires explicit pkg-config compiler/linker flags for
libavformat, libavcodec, libavutil, libswscale and libswresample, as documented in
[the package instructions](../../../Packages/NativePlaybackProof/README.md).
Use a new output directory. macOS bookmark/audio services and Xcode package caches
need host access under a restricted tool sandbox. Initial sandbox runs reached
core tests/builds but could not use the package caches/audio device; host reruns pass.

The native controller fixture intentionally substitutes a different lossless FFV1
picture to detect accidental original decoding. It is a test representation,
not qualification of the ProRes generation pipeline; the resolver/workspace smoke
uses real generated ProRes Proxy MOVs. Full logs and generated media are retained
locally under `/private/tmp/afc-sequence-proxy-drain-20261013`; checked-in logs are
selected summaries, not complete transcripts.

## Scope

Qualified imported picture metadata, matching source/proxy/sequence cadence,
zero stream offsets, complete trim coverage, matching aspect ratio and rasters
bounded to 4096 pixels are required. Older metadata, unsupported selections or
renditions fall back visibly to originals. Original audio remains authoritative;
sequence playback requires originals rather than silently dropping missing audio.
Verification does not monitor or lock files after selection. Lower proxy resolutions
preserve framing but do not guarantee identical fine-detail pixels. Mixed cadence,
VFR, HDR/rotation/anamorphic media, broad compressed audio/resampling, offline
proxy-only sequence playback and shipping dependency packaging remain unqualified.
