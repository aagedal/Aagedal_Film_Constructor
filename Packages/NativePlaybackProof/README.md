# Native sequence engine experiment

Development macOS executable using locally installed FFmpeg headers/libraries.
It is deliberately separate from the app and its EditorCore dependency graph.
No Homebrew library is selected, installed or bundled for the shipping app.

The `CNativeDecoder` bridge owns a serial libavformat/libavcodec context for each
exact container stream. It qualifies all presentation timestamps on first use,
seeks backward with decoder flushing, decodes forward to exact source frames or
PCM sample ranges, and converts to RGB24 or interleaved float without resampling.
VFR, nonzero offsets, inferred timestamps, unsupported geometry, and compressed
audio fail explicitly. Full-stream qualification is intentionally expensive;
it is evidence gathering, not the final startup strategy.

`NativeSequenceProof` consumes EditorCore's stateless `NativePlaybackPlan`.
The monitor selects the frontmost opaque layer, leaves gaps black, mixes explicit
source channel/routing/gain contributions with clip-relative linear or equal-power
edge fades and linked audio crossfades, creates CGImage/PNG captures, and
schedules bounded buffers at AVAudioPlayerNode sample times in offline mode.
Successful plan replacement invalidates source state; failed replacement leaves
the previous plan usable. The raster must match the sequence and audio must have
the same sample rate. Color/scaling, proxies and live A/V clocking await
qualification. Explicit buffers/decoder counts have development limits; FFmpeg
probing/indexing and codec memory have not been comprehensively profiled.

Use [the repository proof runner](../../scripts/native-sequence-proof.py) with
explicit FFmpeg, FFprobe, pkg-config, completed barcode-fixture and fresh output
paths. It captures the actual linked dylib hashes, commands, source identities,
output counts, sequential parity and complete seek/rebuild cases. The fade variant
compares overlapping edge envelopes, both curves and fractional sample durations
against independently rendered FFmpeg PCM after a primed plan replacement.
Linked transition variants use the actual EditorCore crossfade edit for existing
overlaps and adjacent-cut source extensions, check every decoded sample against
an independent waveform/envelope oracle, and seek at transition boundaries and
inside the pair. Both equal-power and linear adjacent transitions are qualified.
Use `--crossfades-only` to run these three variants plus baseline; the default
also retains gaps, standalone fades, interframe decoding and ordinary edit cases. See
[the audit](../../docs/media-engine-audit.md#native-sequence-fallback-proof-2026-10-09)
for reproduction and known runtime/packaging limitations.

`NativePlaybackRuntime` now separates the reusable development monitor from the
proof executable. `NativePlaybackSession` provides async `video`/`audio` requests
on a serial decoder queue, with bounded pending work and a shared video/audio
LRU byte budget. Call `invalidate()` before seeking and `replace(project:)` after
an edit. Returned values carry an epoch; check `accepts(value.epoch)` immediately
before presentation. `close()` cancels obsolete queued work and releases decoder
state. Cancellation cannot interrupt an already-running FFmpeg call.

EditorCore's `NativePlaybackTransport` consumes presented sample counts from the
output clock, supports exact play/pause/seek and rejects stale clock generations.
Decoding and scheduling do not advance it. The proof connects it to AVAudioEngine's
offline sample clock and independently checks frame selection in Python. The
runner now executes nine runtime tests and captures every asynchronous frame and
audio block, including seeks and primed plan replacement.

See [the 2026-10-11 evidence](../../docs/evidence/native-playback-20261011/README.md).
This does not qualify hardware clocking, live display, latency or underrun recovery.

`NativeLiveProof` is a standalone AppKit development window using the async
session, `NativePlaybackTransport`, a real-time AVAudioEngine/AVAudioPlayerNode,
and CGImage display. Space plays/pauses; left/right seek approximately one second.
Initial opening shows frame zero and waits for Space. Audio is primed before the
engine starts, scheduled at exact node sample times with at most 4096 samples of
look-ahead (four 1024-sample blocks, with a partial final block). Video decode has
at most one outstanding request. Seeks flush the node, invalidate decoder epochs,
and reject obsolete operation tokens immediately before scheduling or displaying.
Pause retains the final observed sample-clock position. Starvation or a missing
clock stops playback with an explicit error; automatic recovery is unfinished.

Build and test with explicitly selected local libraries, capturing dependency
hashes and command logs into a fresh directory:

```sh
python3 scripts/native-live-proof.py \
  --pkg-config /absolute/path/pkg-config \
  --project /absolute/path/proof-project.json \
  --output /absolute/path/fresh-live-proof
```

Add `--launch` to open the window and record its close-time scheduling/display
counters. The project can be a completed native sequence proof's generated JSON.
The build-only runner prints the exact executable invocation for later inspection.
The runtime tests cover bounded scheduling, refill admission, starvation,
regressing clocks, partial final blocks, overshoot, and RGB payload validation.

This implementation has compiled and its 14 runtime tests have passed on the
current development host. A hardware playback run has **not** been qualified.
The player-node clock measures rendered samples, not acoustic speaker arrival;
output latency is not compensated. The display is polled at 5 ms and can drop
frames when decode finishes late; it is not synchronized to display refresh.
There is no measured A/V sync, device-change recovery, interruption handling,
real-time decoding guarantee, or signed redistributable FFmpeg bundle. Local
FFmpeg dylibs can require a newer macOS version than this package's deployment
floor. This executable remains disconnected from the shipping app.

The live monitor accepts only canonical mono/stereo layouts and rejects a player
clock whose sample rate differs from the sequence grid. It permits validated
`replace(project:)` edits with an unchanged audio output format, resets and pauses
the transport, then displays the replacement's first frame. Audio format changes
require creating a new live monitor. Surround routing and hardware layout
adaptation have not been qualified.
