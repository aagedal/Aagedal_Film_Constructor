# Standalone audio fade parity proof

Retained from `/private/tmp/afc-fades-native-20261011` on 2026-10-11.
Reproduce with `scripts/render-plan-proof.py` using explicit FFmpeg/FFprobe
paths and a fresh absolute fixture directory, then `scripts/native-sequence-proof.py`
with explicit FFmpeg/FFprobe/pkg-config paths, that fixture, and a fresh output
path. Full media and decoded buffers remain temporary artifacts; retained
commands, source/dependency hashes, results and fade manifests identify the run.
The final `TimelineEditEngine.swift` adds one split documentation comment after
source hashes were captured; executable proof sources are otherwise unchanged.

All five variants pass 180 frames and 288,288 stereo samples per channel in
synchronous, asynchronous and AVAudioEngine offline scheduling paths, plus ten
video and eight audio seeks each. The new `overlapping-edge-fades-rebuild`
variant replaces a primed baseline plan with overlapping audio clips carrying
linear and equal-power edges. Each pair of edge fades overlaps within its clip;
one duration is 250001/96000 seconds, a fractional sample. Routing and static
gain remain active. Sequential and seek audio match an independent FFmpeg
render within 1.0 s16 unit; maximum mean RGB error is 2.0. Every variant passes
282 offline clock observations, retains 90,112 cache bytes under a 131,072-byte
limit, and finishes with zero pending requests. Nine runtime tests pass.

Native envelopes use the clip-relative sample index, and FFmpeg evaluates the
same ramps after source trim and before timeline delay. Equal-power uses
`sin(progress * pi / 2)`; overlapping edges multiply. Fade out evaluates remaining
clip time, so the final included sample can remain nonzero. Output PCM rounding
accounts for the permitted one-unit difference. No limiter or normalization is
applied. Core regressions separately check endpoints, both curves, fractional
samples, invalid values, persistence and envelope-preserving edits.

This qualifies the development subset: matching-rate PCM, matching-raster CFR
video and mono/stereo output. The app source monitor still previews originals.
Live sequence output, hardware A/V sync, linked crossfades, compressed-audio
resampling, color/geometry coverage, proxies and production export remain open.
Local Homebrew dependencies target newer macOS and are not a shipping bundle.
Native fade gestures, focus and inspector layout still need manual UI testing.
