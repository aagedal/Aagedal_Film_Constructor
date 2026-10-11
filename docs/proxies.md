# Project-bin proxies

Select one or several video sources in the media bin (Command-click or Shift-click),
right-click a selected item, and choose **Create proxies…**. ProRes Proxy is the
default; H.264 is optional. Choose full, half (default), or quarter resolution,
then an output folder. Each batch runs sequentially, with at most two jobs admitted
across document windows. Additional concurrent requests report a busy error and
can be retried. Jobs report individual failures and can be canceled. Successfully
completed assets remain registered when a later job fails or is canceled.

The **Proxies** toolbar menu opens the persistent queue. Jobs save their codec,
resolution, source snapshot/fingerprint, unique destination and output-folder
access grant with the project. Closing the queue leaves generation running;
closing the document cancels it. After save/reopen, running jobs become interrupted
and nothing starts automatically. Choose **Resume queue** for unfinished jobs,
or **Retry** for one job. Source changes require a new job. Remove unwanted entries
or clear completed entries without deleting files or registered proxies.

An interrupted job can recover an already published output only when its saved
verified metadata matches the file's exact bytes. If an existing output has no
saved verification record, it is retained and the job fails. **Retry to new file**
chooses another unique destination. Queue state follows normal document save and
autosave; it is not a separate crash journal. An unsaved publication can therefore
leave an orphan file requiring that explicit retry. Queue status and progress stay
outside timeline edit undo; successful proxy registration remains undoable.

The application uses explicitly bundled FFmpeg/FFprobe helpers; ordinary builds
contain none. See [helper preparation](media-helper-packaging.md). H.264 requires
the selected build's `libx264` encoder, in addition to the baseline render-helper
capabilities. The creation dialog disables H.264 when the prepared helper bundle's
verified encoder listing lacks `libx264`.

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
original clears its proxy reference in the same undoable action. To relocate a
generated proxy, right-click its source and choose **Relink proxy…**, then select
the moved MOV file. Relinking verifies its recorded byte identity asynchronously
before changing the reference and sandbox grant in one undoable action. A different
file is refused even if its dimensions and duration match. The original must remain
available and unchanged. Regenerate older proxies that have no recorded hash before
relinking them. Missing proxies can also be regenerated. The hires/proxy choice is
a session preference rather than an
edit saved in the project.

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
proxy. Newly generated proxies record their file size and SHA-256 hash. Choosing
proxy playback checks the file in bounded chunks off the main actor; a mismatch
falls back to originals with a visible modified-proxy status. This detects changed
bytes even when size and modification time are preserved. Legacy unhashed proxies
remain playable with the earlier trust model until regenerated. Verification occurs
when loading the representation; it does not continuously monitor a file during
playback or prevent external changes after verification.

Source/frame probe output is limited to 2 MB per subprocess. Long sources can
exceed that limit and are rejected without publication. Generation scans all
decoded frame timestamps before encoding, so it is deliberately conservative and
does not yet provide a streaming qualification path for large media.

Run `scripts/proxy-service-smoke.sh` with explicit development helpers to exercise
real encoding, fractional-rate/timecode preservation, unsupported media rejection,
cancellation, failure and atomic publication. `scripts/proxy-workspace-smoke.sh`
exercises source composition, transport switching, grants, history, and reopen.
`scripts/proxy-queue-smoke.sh` covers persisted jobs, manual resume, interrupted
publication recovery, destination conflicts, single-job retries, stale sources,
cancellation, legacy documents and queue/undo separation.
These tests use development helpers and unsigned runners; native dialog gestures,
hardware playback quality/sync, and signed sandbox grants across launches still
require manual qualification. Edited-sequence monitoring is not enabled.
