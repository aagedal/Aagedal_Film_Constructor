# Headless runtime MPV proof

Development evidence from 2026-10-09. These files contain no shipping media
helpers. Absolute paths in manifests identify the original temporary runs; use
the [audit reproduction commands](../../media-engine-audit.md#runtime-track-resolution-sequential-parity-and-seek-failure-2026-10-09)
to regenerate media, reference RGB/PCM, and all captures in new directories.

- `build/`: MPV snapshot source hashes, dirty state, commands, versions, linkage
  and executable hash. The build uses local Homebrew libraries.
- `render/`: independent FFmpeg compiler proof, helper versions and hashes.
- `sequential/`: actual loaded tracks, resolved graph, capture command/log and
  result. All 180 frames and 288,288 stereo samples pass.
- `seek/`: actual tracks, resolved graph, command/log, helper hashes and result.
  Three initial seeks pass; later/backward seeks and graph rebuilding fail.

Selected screenshots are actual displayed MPV video frames: operation 01 targets
sequence frame 0 (passes), 04 targets frame 60 (fails), 09 seeks backward to frame
15 (fails), and 10 rebuilds at frame 15 (fails). The binary stripes encode frame
number/source identity. All screenshot comparisons and time positions are in
[`seek/result.json`](seek/result.json).

Native display, CoreAudio, audio seeks and real-time synchronization were not
tested. A passing sequential capture does not qualify interactive editing.
