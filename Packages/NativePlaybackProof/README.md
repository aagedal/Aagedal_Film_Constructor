# Native sequence engine experiment

Development macOS runtime linking FFmpeg 9.0.2 statically from the pinned
[aagedal/MPVKit](https://github.com/aagedal/MPVKit) GPL build (`MPVKit-GPL`).
It is deliberately separate from the app and its EditorCore dependency graph.
No local FFmpeg installation or pkg-config is used.

The `editor.1` release adds editorial demuxers and decoders to MPVKit's
playback-oriented FFmpeg: PNG/JPEG/TIFF/DPX/EXR pipes, NUT, GXF and W64, plus DV,
v210, r210, CineForm, QuickTime RLE, UT Video, TIFF and JPEG 2000. Builds without
the PNG/JPEG pipe demuxers open stills through `image2`; the decoder accepts that
only with a matching file signature and exactly one parsed image.

The `CNativeDecoder` bridge owns a serial libavformat/libavcodec context for each
exact container stream. It qualifies all presentation timestamps on first use,
seeks backward with decoder flushing, decodes forward to exact source frames or
qualified audio sample ranges, and converts to RGB24 or interleaved float without resampling.
Audio supports PCM plus 16/24-bit ALAC with canonical mono/stereo layouts at
44.1/48 kHz. VFR, nonzero offsets, inferred timestamps, unsupported geometry,
lossy audio, and other ALAC formats fail explicitly. Full-stream qualification is intentionally expensive;
it is evidence gathering, not the final startup strategy.

The [ALAC evidence](../../docs/evidence/native-alac-20261015/qualification.md)
retains 313 ASan/UBSan checks with independent exact sample patterns, packet-edge
and reverse/repeated seeks, plus native sequence/offline audio-engine parity.
Reproduce the optional runtime proof with `scripts/native-alac-sequence-proof.py`
and explicit local tools. Live synchronization and resampling remain unqualified.

`NativeSequenceProof` consumes EditorCore's stateless `NativePlaybackPlan`.
The monitor composites still-image layers over the first visible opaque video
layer, leaves gaps black, mixes explicit
source channel/routing/gain contributions with clip-relative linear or equal-power
edge fades and linked audio crossfades, creates CGImage/PNG captures, and
schedules bounded buffers at AVAudioPlayerNode sample times in offline mode.
Successful plan replacement invalidates source state; failed replacement leaves
the previous plan usable. Video uses the clip's fit/fill/none setting: bicubic
spatial scaling followed by centered RGB padding/cropping, with black padding.
Source, sequence and intermediate dimensions are limited to 4096 in each
direction; extreme fill aspect ratios can exceed this limit and fail explicitly.
Odd spare pixels are assigned to the bottom/right. Audio must have the same sample
rate. Still originals are single-frame PNG/JPEG files with one image stream;
animated/multiple-frame images and containers disguised as images fail explicitly.
Synthetic still source trims always select the same image. PNG alpha is retained
through bicubic RGBA scaling and transparent padding, then composed over lower
layers using straight alpha with nearest integer rounding. Alpha-bearing motion
video fails explicitly. General image formats, linear-light color composition,
color management, proxies and live A/V clocking await qualification. Explicit
buffers/decoder counts have development limits; FFmpeg
probing/indexing and codec memory have not been comprehensively profiled.
The live session's 8 MB frame/audio cache is separate from retained source decoder
state. `NativeMonitor(project:decoderLimits:)` defaults to an LRU of 16 active
stream decoders and a 128 MiB retained source byte budget. The async
`NativePlaybackSession` initializer forwards the same optional `decoderLimits`.
`NativeDecoderLimits`
accepts 1...64 active decoders and a nonnegative byte budget (zero disables
retention). Distinct sources are unlimited across a sequence: opening a new source
closes the least recently used context when the active bound is reached. After
each source operation, including failures, contexts are evicted until retained
decoded frame buffers and allocated float conversion capacity fit the byte budget.
A source larger than that budget can still be decoded; its context is closed
after the operation. Eviction preserves exactness by reopening and requalifying
the source on its next request, which can add substantial latency. Source
operations pin one context until completion, so the byte budget describes idle
retention and does not bound transient decode/output allocations. Accounting counts
AVFrame buffer references conservatively, and excludes codec reference frames,
demuxer/probing/indexing state, packets, scaler/resampler state and caller output.
These limits do not claim a total process RSS bound. Input probing occurs before
the codec raster limit and its allocations are outside these explicit bounds.
Runtime retention regressions decode actual PNGs across 65 distinct sources and
reverse revisits, verify LRU reuse and decoder release with weak references,
exercise byte-budget eviction after success/failure, and compare reopened PCM16
WAV ranges against an independent exact sample oracle. Invalid async-session
retention limits fail at construction rather than on first playback.

Use [the repository proof runner](../../scripts/native-sequence-proof.py) with
explicit FFmpeg, FFprobe, completed barcode-fixture and fresh output
paths. It records the pinned MPVKit revision supplying the linked FFmpeg, commands, source identities,
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

Use `--geometry-only` for baseline plus nine video fit/fill/none variants with
smaller, larger and odd-sized source rasters. It retains active-picture comparisons
that exclude black padding, and exercises seeks, PNG capture and primed plan
replacement. See [the spatial evidence](../../docs/evidence/native-geometry-20261012/README.md).
Use `--stills-only` for baseline plus twelve PNG-alpha/JPEG fit/fill/none
variants with smaller/larger images, primed plan replacement and reverse/repeated
seeks. Independent no-scaling PNG oracles check transparent, partial and opaque
coverage separately against separately decoded barcode frames; FFmpeg export
parity also checks every frame, asynchronous capture and native PNG seek capture.
See [the still evidence](../../docs/evidence/native-stills-20261012/README.md).
The default runner includes stills, geometry and the original timeline cases.

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
runner executes runtime tests and captures every asynchronous frame and
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
Pause retains the final observed sample-clock position. Audio starvation flushes
output and pauses at the last accepted transport sample;
explicit Play starts a fresh clock epoch. A missing clock stops playback with an
explicit error. Automatic recovery remains unfinished. Final Pause readings use
the same queue validation, and cancellation covers priming, audio pumping and
video display tasks.
Audio-engine configuration changes and unexpected engine stops also flush pending
work and pause at the last accepted transport position. The monitor reports the
interruption and requires explicit Play to restart; it never submits a reset
node's clock as if it belonged to the previous playback epoch. Closing or
releasing the monitor removes its configuration observer.

Build and test against the pinned MPVKit FFmpeg, capturing its revision
and command logs into a fresh directory:

```sh
python3 scripts/native-live-proof.py \
  --project /absolute/path/proof-project.json \
  --output /absolute/path/fresh-live-proof
```

Add `--launch` to open the window and retain `live-observations.jsonl` plus a final
observation summary in `manifest.json`. JSON records include elapsed uptime,
transport sample/frame, the last displayed frame, per-play-epoch scheduling and
lifecycle counters, and retained errors. `--observation-interval` sets periodic
sampling (default 0.5 seconds). The project can be a completed native sequence
proof's generated JSON.
The build-only runner prints the exact executable invocation for later inspection.
The runtime tests cover bounded scheduling, refill admission, starvation,
regressing clocks, partial final blocks, overshoot, RGB payload validation,
geometry, observer scoping/cleanup, and lifecycle-statistics serialization.

For a repeatable exercise, add `--launch --scripted-duration 3`. This runs play,
seek to frame zero, pause, resume and close, retaining each action. The duration
excludes decoding/priming time. Errors or missing final records cause a failing
harness exit status. Scripted runs must complete every action in order; early
window close is a failure. Build-only operation opens no window. Direct executable use
accepts `--observations /new/path.jsonl` and refuses to overwrite existing files.
Observations describe the player node's render clock; they do not measure acoustic
arrival or display refresh and never set `hardwareQualified`.

Negative startup node sample times are treated as preroll until the first
nonnegative tick, under the two-second clock deadline. Negative clocks after
startup and changed sample rates still fail explicitly.

This implementation has compiled and its 32 runtime tests have passed on the
current development host. A [scripted local output smoke](../../docs/evidence/native-live-20261012/README.md)
completed play/seek/pause/resume without errors. [Recovery regressions](../../docs/evidence/native-recovery-20261012/README.md)
cover injected starvation during polling and refill, explicit restart, interruption
policy, priming cancellation and release after pumping begins. The actual output
smoke encountered no underrun. Hardware synchronization and recovery have
**not** been qualified.
The player-node clock measures rendered samples, not acoustic speaker arrival;
output latency is not compensated. The display is polled at 5 ms and can drop
frames when decode finishes late; it is not synchronized to display refresh.
There is no measured A/V sync or automatic device-change/underrun recovery,
real-time decoding guarantee, or signed redistributable FFmpeg bundle. This executable remains disconnected from the shipping app.

The live monitor accepts only canonical mono/stereo layouts and rejects a player
clock whose sample rate differs from the sequence grid. Before priming, again
after priming, and after the engine starts but before the player starts, it
checks the hardware output channel count against the sequence. Mono/stereo count
changes, surround devices, and explicit noncanonical speaker layouts fail with
an instruction to choose a compatible route; no downmix or upmix is inferred.
Canonical metadata can be a mono/stereo layout tag or explicit named descriptions:
one Mono/Center channel, or Left then Right. Reordered, unknown and discrete
descriptions are rejected. The local stereo device exposes Left/Right descriptions
rather than the Stereo tag, so checking tags alone would reject that valid route.
AVAudioFormat permits absent speaker metadata for one/two channels, which this
proof accepts as conventional mono/stereo. Device sample-rate conversion remains
AVAudioEngine's responsibility; the player clock must still match the sequence.
Runtime regressions cover route rejection without losing the paused position,
restart after choosing a compatible route, and route changes during priming.
See [the route evidence](../../docs/evidence/native-output-route-20261012/README.md)
for the runtime test results and scripted local output run.
This is conservative admission checking, not a hardware speaker-identification
or device-change qualification. It permits validated
`replace(project:)` edits with an unchanged audio output format, resets and pauses
the transport, then displays the replacement's first frame. Audio format changes
require creating a new live monitor. Surround routing and hardware layout
adaptation have not been qualified.

## Relocated development app bundle

The opt-in controller runner can now make a separate self-contained development
app with explicit notices and provenance. Add `--package-runtime-notices` and
`--package-runtime-provenance` to `scripts/sequence-monitor-native-smoke.py` (with
`--build-workspace` for the editor). `scripts/package-native-runtime.py` discovers
and relocates the complete dylib closure into `Contents/Frameworks`, removes local
rpaths, records hashes/architectures/deployment versions and ad-hoc signs the
bundle. A second controller smoke runs with developer loader paths cleared and
checks actual dyld load observations. It never replaces shipping dependencies.
See [packaging evidence](../../docs/evidence/native-runtime-packaging-20261014/README.md).
With MPVKit's static FFmpeg the closure is the runtime dylib alone. Its
attribution/notices remain unreviewed; a compatible attributed distribution
remains required.
