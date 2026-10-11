# Project-bin proxies

Select one or several video sources in the media bin (Command-click or Shift-click),
right-click a selected item, and choose **Create proxies…**. ProRes Proxy is the
default; H.264 is optional. Choose full, half (default), or quarter resolution,
then an output folder. Each batch runs sequentially, with at most two jobs admitted
across document windows. Additional concurrent requests report a busy error and
can be retried. Jobs report individual failures and
can be canceled. Successfully completed assets remain registered when a later
job fails or is canceled. Rerun creation to resume the remaining assets.

The application uses explicitly bundled FFmpeg/FFprobe helpers; ordinary builds
contain none. See [helper preparation](media-helper-packaging.md). H.264 requires
the selected build's `libx264` encoder, in addition to the baseline render-helper
capabilities. A missing encoder fails the job and leaves existing proxies intact.

Each output gets a unique MOV filename. Generation uses private staging, checks
the result, and publishes without replacing an existing file. An existing proxy
reference remains usable until the replacement has finished verification and
registration. Registration and its independent sandbox bookmark form one undoable
edit. Undo removes the reference rather than deleting generated media; old outputs
are retained so redo and earlier project versions can still reference them.

Use **Hires / Proxy** below the source monitor to switch all source previews in
the current document session. Switching preserves source position and forward
playback intent, including rapid switches while the new representation loads.
Proxy video is combined with original audio tracks, retaining their channels and
source offsets. Silent reverse transport remains available. Missing, stale, or
unusable proxies fall back to originals with visible status. Original media is
required to validate the source and provide audio. Proxy registration does not
change timeline edits, clip scaling, sequence settings, filmstrips or waveforms.
Rendered exports and FCPXML continue to reference originals.

Proxy references and separate file-access grants survive save/open. Relinking an
original clears its proxy reference in the same undoable action. Missing proxy
files can be regenerated; explicit proxy relinking and a persistent job queue
are not implemented. The hires/proxy choice is a session preference rather than
an edit saved in the project.

## Qualified subset

Generation selects the first imported video stream and verifies its probed index.
It requires constant frame rate, consecutive zero-based decoded timestamps, square
pixels, limited-range color, no rotation, and no HDR markers. Known SDR color tags
are preserved and verified. Full-range and `yuvj` sources remain unqualified.
Raster dimensions must divide exactly by
the requested scale and produce even dimensions. Unqualified sources fail rather
than receiving guessed frame mappings. Every original and proxy timestamp is
checked with exact rational arithmetic, along with codec/profile, raster, rate,
frame count, and available MOV source timecode. Proxies contain video only; audio
stream identity and channel selection remain on originals.

Source freshness uses file size and modification time, checked before and after
generation and when choosing playback. This is a metadata fingerprint, not a
content hash: replacement bytes with identical size and modification time are
not detected automatically. Explicit original relinking always invalidates the
proxy. Proxy files themselves are trusted after generation; external replacement
of a proxy is not detected by a stored output hash.

Source/frame probe output is limited to 2 MB per subprocess. Long sources can
exceed that limit and are rejected without publication. Generation scans all
decoded frame timestamps before encoding, so it is deliberately conservative and
does not yet provide a streaming qualification path for large media.

Run `scripts/proxy-service-smoke.sh` with explicit development helpers to exercise
real encoding, fractional-rate/timecode preservation, unsupported media rejection,
cancellation, failure and atomic publication. `scripts/proxy-workspace-smoke.sh`
exercises source composition, transport switching, grants, history, and reopen.
These tests use development helpers and unsigned runners; native dialog gestures,
hardware playback quality/sync, and signed sandbox grants across launches still
require manual qualification. Edited-sequence monitoring is not enabled.
