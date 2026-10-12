# Native decoder retention qualification

Source decoders now use a configurable LRU: at most 16 retained contexts and
128 MiB of decoded source buffers by default. `NativeMonitor` and
`NativePlaybackSession` accept independent `NativeDecoderLimits`. A stream that
exceeds the byte budget can finish a request, then releases its decoder. More
than 64 sources can be visited over time. Evicted streams requalify and seek
when reopened, so eviction may add decoding latency.

The C bridge counts AVFrame fixed/extended buffer references and allocated PCM
conversion capacity. Aliased buffers may be counted more than once. These
bounds exclude codec reference frames, probing/indexing, packets, scaler and
resampler internals and transient returned output. They are not total RSS limits.
The session's returned-payload cache remains separate.

Verification on 2026-10-12 passed 39 runtime tests and the complete 13-variant
still suite and 10-variant geometry suite. New PNG/WAV tests cover LRU refresh,
byte eviction, failures, lifetime release, reverse/repeated exact PCM reads,
invalid session limits and 65 distinct sources followed by reverse revisits.
Each parity variant checks every synchronous/asynchronous frame and audio
sample plus video/audio seeks and primed plan replacement.

The [summary](summary.json) retains counts, error measurements and hashes of
full transient result files. Run the existing `native-sequence-proof.py` with
`--stills-only` or `--geometry-only` following the native package instructions.
Proof runners used explicit locally installed FFmpeg 9.0.2 libraries and
approved host access to macOS audio services. Sandbox-only offline audio
initialization failed before parity assertions; the host-access runs passed.
Hardware latency, synchronization and shipping dependency packaging remain open.
