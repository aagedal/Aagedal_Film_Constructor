# Native sequence fallback proof

Development evidence from 2026-10-09. No helper binaries or full media fixtures
are retained here. Absolute paths identify the original temporary runs; regenerate
them using [the audit commands](../../media-engine-audit.md#native-sequence-fallback-proof-2026-10-09).

Four independent render/capture variants pass every one of their 180 video frames
and 288,288 stereo sample frames, ten video seeks and eight audio seeks:

- `baseline/`: original overlapping-video barcode and swapped mono-stream fixture.
- `gaps-and-audio-overlap/`: black video gaps and overlapping audio on a second
  routed track with independent gain and a different source in-point.
- `interframe-b-frames/`: the preceding edits using closed-GOP H.264 with B-frames.
- `edited-plan-rebuild/`: prime old video/audio decoder state, refuse an invalid
  replacement without changing the plan, then replace the plan with changed
  source in-point, gain and routing before capturing the full new sequence.

[`result.json`](result.json) records actual decoded comparisons and artifact
hashes. `commands.json`, helper/library identities, source hashes, linkage and the
build log identify the tested development build. Each variant retains its native
request manifest, persisted project, independently emitted export command and
selected actual CGImage/PNG captures. Frame 60 is a later seek; the last two PNGs
seek backward to frame 15 and then close/reopen the source decoders at frame 15.
Manifest coverage is required in its entirety before the proof can pass.

Maximum per-frame mean RGB error is 2.0 (tolerance strictly below 12). Mixed and
AVAudioEngine-scheduled audio differ from decoded 16-bit references by at most
0.75 sample units (tolerance 1). Both original sources are independently verified
against all 300 expected binary frame/source barcodes before testing the engine.

`decoder-check/` retains the separate direct C ASan/UBSan fixture/rejection
evidence. This finite matrix does not certify arbitrary source files.

The output path uses CGImage/ImageIO and AVAudioEngine offline rendering. Every
audio seek creates a fresh offline engine; cancellation of pending live buffers,
display refresh, hardware audio latency and real-time A/V sync remain untested.
First access scans all timestamps of each selected source stream. Shipping
dependencies, macOS 14 compatibility, color/scaling, VFR, resampling/compressed
audio, fades and proxies remain unfinished.
