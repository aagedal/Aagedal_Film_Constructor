# Asynchronous sequence playback proof

Development evidence from 2026-10-11, retained from
`/private/tmp/film-native-async-verified-20261011`. Full media and decoded buffers
remain temporary artifacts. Reproduce with the updated
[`native-sequence-proof.py`](../../../scripts/native-sequence-proof.py), supplying
explicit FFmpeg/FFprobe/pkg-config paths, a passing barcode render-plan fixture,
and a fresh absolute output directory.

All four variants pass 180 frames and 288,288 stereo samples per channel through
both the original synchronous monitor and the new asynchronous serial worker.
Ten video seeks and eight audio seeks per variant also match independent FFmpeg
renders. The edited-plan variant primes the old asynchronous decoder before
replacing its source in-point, gain and routing. Maximum per-frame mean RGB error
is 2.0; maximum audio error is 0.75 s16 units. Both remain within the original
proof tolerances. All 300 barcode frames in each source are authenticated first.

AVAudioEngine's offline sample clock supplies 282 observations per variant.
Python independently checks the transport frame as
`floor(presentedSamples * 30000 / (48000 * 1001))`. At the exact end, transport
stops with no current video frame and the full sample count. The shared LRU
finishes at 90,112 bytes in every variant, below the configured 131,072-byte cap,
with no pending requests. This bounds retained decoded payloads, not FFmpeg's
internal allocations or full-stream timestamp qualification.

Nine runtime tests exercise mixed-cache eviction, oversized/disabled caches,
in-flight seek invalidation, task cancellation, admission saturation, failed
replacement rollback, close, invalid requests, queued read rejection, repeated
replacement and cancellation during decoder construction. Synchronization
barriers hold the worker inside initialization or decoding to make races
reproducible. Cleanup jobs are coalesced; repeated close is idempotent.

The proof passed outside the tool sandbox because system audio-component
registration is unavailable inside it. It uses offline rendering and does not
play audio through hardware. Libraries are local development dependencies built
for macOS 27; shipping dependencies and macOS 14 compatibility remain open.
Live display refresh, output latency, underrun recovery, real-time A/V sync,
scaling/color, VFR, compressed audio/resampling, fades and proxies are unqualified.
Cancellation skips queued work and discards completed obsolete output; it cannot
interrupt a libavcodec call or timestamp scan already in progress.
