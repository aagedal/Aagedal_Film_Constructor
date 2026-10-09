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
source channel/routing/gain contributions, creates CGImage/PNG captures, and
schedules bounded buffers at AVAudioPlayerNode sample times in offline mode.
Successful plan replacement invalidates source state; failed replacement leaves
the previous plan usable. The raster must match the sequence and audio must have
the same sample rate. Color/scaling, fades, proxies and live A/V clocking await
qualification. Explicit buffers/decoder counts have development limits; FFmpeg
probing/indexing and codec memory have not been comprehensively profiled.

Use [the repository proof runner](../../scripts/native-sequence-proof.py) with
explicit FFmpeg, FFprobe, pkg-config, completed barcode-fixture and fresh output
paths. It captures the actual linked dylib hashes, commands, source identities,
output counts, sequential parity and complete seek/rebuild cases. See
[the audit](../../docs/media-engine-audit.md#native-sequence-fallback-proof-2026-10-09)
for reproduction and known runtime/packaging limitations.
