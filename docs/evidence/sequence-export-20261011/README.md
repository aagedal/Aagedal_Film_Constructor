# Sequence export checkpoint — 2026-10-11

The app exposes a development MOV/ProRes 422 HQ/PCM render workflow and a scoped
FCPXML interchange exporter. This checkpoint qualifies the fixture subset below;
it does not establish live edited-sequence playback or release distribution.

## Retained evidence

- `still-render-result.json`: 180 rendered frames with 54 independent RGB checks
  across fit/fill/none, transparent PNG compositing, synthetic source trims and
  half-open layer boundaries. An audio-only tail retains exactly 48001 samples
  while video covers 25 frames. The original rational-rate render fixture also
  passed 180 frames/288288 samples with cuts, routing, gain and timecode intact.
- `checkpoint.json`: test counts, helper input hashes, schema version and explicit
  qualification limits. The local static FFmpeg/FFprobe 9.0.1 pair was prepared
  with unknown source attribution and an unreviewed development notice fixture.
  It is a development packaging test, not a redistributable helper bundle.
- EditorCore passed 74 XCTest and 47 Swift Testing cases, including eight FCPXML
  cases. Generated layered video/audio XML passed Apple's 1.10 DTD at 24,
  23.976, 29.97 and 59.94 fps. Nine Python regressions, shortcut smoke, expanded
  app-file smoke, and unsigned macOS builds with and without helpers passed.
- The export-service smoke passed using the static 9.0.1 helpers: exact frame,
  sample, raster, rate, codec and timecode verification; existing destination
  protection; source index/kind and pixel-aspect refusal; bounded diagnostic
  retention while draining more than a pipe buffer; malformed verification
  refusal; cancellation and staging cleanup. A SIGTERM-ignoring helper was
  killed/reaped within five seconds and its PID no longer existed.
- Helper preparation/copy tests passed version/configuration and capability
  checks, system-only dependencies, supplied-file hashes, tamper rejection,
  stale-helper removal and ad-hoc signing with sandbox-inheritance entitlements.
  Homebrew's dynamically linked helper was refused by preparation.

## Reproduction

Run `scripts/verify.sh`, `scripts/app-file-smoke.sh`, and
`scripts/export-service-smoke.sh`. The export smoke takes explicit development
helper paths through `AFC_SMOKE_FFMPEG` and `AFC_SMOKE_FFPROBE`. See
`scripts/still-render-plan-proof.py --help` for the independent decoded proof,
[helper preparation](../../media-helper-packaging.md) and
[FCPXML validation](../../fcpxml-export.md) for optional packaging/schema checks.
Bookmark services and Xcode caches require access outside a restrictive tool
sandbox. No executable helpers are committed.

## Remaining qualification

Signed sandbox app export with real file-panel grants, physical UI interactions,
native Final Cut Pro/Resolve import, source geometry/color/VFR parity and verified
release source/notices remain open. Preflight refuses known rotation, non-square
pixels, HDR/wide-gamut markers, differing average/nominal rates, nonzero stream
offsets and stream-map mismatches; this is not an exhaustive VFR or color audit.
FCPXML explicitly refuses fades/crossfades, remaps and other unsupported edits.
