# Private asynchronous MPV source bridge — 2026-10-16

The pinned cached MPVKit runtime now passes a Swift 6 main-actor client through
an opaque C source bridge. This is a development prerequisite for a future source
backend; ordinary app builds continue to use AVFoundation.

The private dylib exports exactly nine `afc_mpv_bridge_*` functions. No MPV or
FFmpeg symbols or borrowed event/node/pixel allocations cross its public ABI.
Loads, explicit track selection, exact seeks and pause commands use asynchronous
MPV requests with distinct internal IDs and caller correlation. Container stream
indices resolve by both `ff-index` and media kind, then selected properties are
verified before opening completes. Commands admit at most 64 pending requests;
polling has explicit raw-event and copied-event budgets. Strings and screenshots
are bounded, with RGB bytes copied into caller-owned storage.

No foreign wakeup callback is installed. Swift polls nonblocking on one main
actor, copying events before MPV can invalidate their storage. Closing synchronously
joins MPV workers, discards pending work and supports repeated close/destroy.
An ordinary seek retains the last observed position until the runtime reports
another one; command acknowledgment alone does not mean decoding has finished.
Playback-restart events can coalesce and deliberately carry no invented request
correlation. The client checks both restart and target position, followed by
independent decoded-frame comparison.

The retained AddressSanitizer run passes:

- 12 create/open/play/pause/destroy cycles, alternating MOV and audio-first MKV.
- 60 exact forward/backward/repeated seeks and decoded RGB captures, all within
  the unchanged mean/peak limits of 3/32. Maximum mean error is 1.8199132 and
  peak component error is 3; no edges or components are excluded.
- 36 rapid seek/pause/seek commands with one correctly correlated reply each,
  duplicate-ID rejection and final-coordinate acceptance.
- 64 pending commands, rejection of the next request, reply draining and reuse.
- Natural EOF with invalidated position followed by paused exact-seek recovery.
- Explicit audio-only/video-only selection, including screenshot refusal with
  picture disabled; six missing/wrong-kind rejections and corrupt-file failure.
- Six closes during pending loads and six during pending seeks, plus repeated
  close/destroy and refusal of commands after closing.

The EOF exercise caught a stale position-cache issue. The rapid-command exercise
also caught invalidating an unchanged observed coordinate when MPV coalesced
seeks; both regressions are covered by the real runtime harness.

AddressSanitizer instruments the new bridge and Swift client, not the prebuilt
dependency archives. This finite run does not establish callback lifetime safety
because it installs no callbacks. Null output sinks do not qualify decoded MPV
audio, CoreAudio, GPU presentation, physical synchronization, color agreement,
proxy picture with original audio, signed sandbox grants, library unloading or
application integration. The prior colored source matrix still fails. Native
runtime coexistence remains a separate proof; this new bridge has the same private
export constraint but has not been integrated with Swift sequence coordination.
Redistribution, notices, release signing and packaging remain open.

`result.json` retains commands, dependency/source/helper/executable hashes,
Swift coverage counts and every decoded comparison. Full fixtures, source
snapshots, logs and binaries remain at its recorded absolute temporary path.

## Reproduce

Supply a clean pinned checkout, its extracted artifact cache, an explicit FFmpeg
executable and a new output directory. No downloads or app changes occur:

```sh
python3 scripts/mpv-async-source-proof.py --sanitize-address \
  /absolute/path/to/MPVKit \
  /absolute/path/to/SourcePackages/artifacts/mpvkit \
  /absolute/path/to/ffmpeg /private/tmp/afc-mpv-async-new
```

Requires macOS 27 and Xcode. Omit `--sanitize-address` for an uninstrumented run.
