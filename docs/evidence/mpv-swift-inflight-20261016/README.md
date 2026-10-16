# Native in-flight payload rejection alongside MPV — 2026-10-16

The private Swift coexistence runner now qualifies sequence replacement, task
cancellation and session close at a deterministic decoded-payload boundary.
Ordinary app source playback continues to use AVFoundation.

The AddressSanitizer run repeats the earlier 120 native picture/audio pairs,
12 source lifecycles, 60 grayscale MPV captures and per-cycle timestamp overlap
checks. It then runs six additional interleavings in each of the native-only and
concurrent processes: replace/cancel/close, each with video or audio in flight.

A proof-only `@testable` wrapper calls the real `NativeMonitor` decoder and holds
its completed payload on `SerialDecodeWorker` before returning to the worker's
cancellation checks. A second request is admitted behind it. The test then:

- Replaces the sequence with a six-frame source trim, cancels both request tasks,
  or starts session close while the worker remains held.
- Completes MPV seeks and play/pause commands during the hold in concurrent mode.
- Releases the barrier and requires both obsolete requests to throw cancellation.
  The decoder call count must remain one, proving the queued request never
  reached the decoder. Pending requests and cached payload bytes must be zero.
- After replacement/cancellation, decodes fresh picture/audio. All four recovery
  pairs per process match independent FFmpeg exactly and match the native-only
  process byte for byte. Replacement uses source frame six; cancellation retains
  source frame zero.
- Checks that close waits for the held worker, rejects later requests and releases
  its decoder. Constructed/destroyed wrapper counts also verify final teardown
  after recovery: two decoders for replacement, one for cancellation/close.

All six cases pass in each process, with 12 obsolete requests refused per process.
The unchanged MPV grayscale bounds remain mean/peak 3/32; observed maximum mean
error is 1.8199132 and peak error is 3. The validator refuses missing interleavings,
wrong recovery frames, incomplete rejection, queued decoding, retained cache,
missing MPV transport and incomplete decoder cleanup. All 95 Python tests pass
with eight optional skips. Independent review found no remaining actionable issues.

This proves cancellation/epoch rejection after real decode and before payload
publication. It does not interrupt an active libavcodec call, prove simultaneous
codec execution during the held interval, or qualify unbounded edit stress.
The earlier timestamp-overlap checks continue to cover ordinary concurrent work.
No production API or app backend changed. Color parity, decoded MPV audio,
CoreAudio/GPU presentation, hardware sync, proxy composition, signed sandbox media
grants and distribution remain open. Prebuilt MPV/FFmpeg dependencies remain
uninstrumented; newly built bridge, clients and native targets use AddressSanitizer.

`result.json` retains exact commands, snapshotted source/dependency hashes,
prerequisite bridge results and all comparisons. The two `*-report.json` files
retain Swift observations. Full sources, binaries, media and logs remain at the
temporary paths recorded in the result. Source hashes were verified against the
workspace before retaining the reports.

## Reproduce

Use explicit local dependencies and a new output directory; no downloads occur:

```sh
python3 scripts/mpv-swift-coexistence-proof.py --sanitize-address \
  /absolute/path/to/MPVKit \
  /absolute/path/to/SourcePackages/artifacts/mpvkit \
  /absolute/path/to/ffmpeg /absolute/path/to/pkg-config \
  /private/tmp/afc-mpv-swift-inflight-new
```

Requires macOS 27, Xcode, the pinned cached MPVKit checkout/artifacts, and native
FFmpeg libraries discoverable by the selected pkg-config. The internal wrapper
uses the debug package's testing visibility without changing runtime sources.
