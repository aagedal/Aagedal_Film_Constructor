# System still-image preview — 2026-10-15

Ordinary builds now preview a bounded PNG/JPEG subset through the production
AVFoundation sequence backend. ImageIO decodes one image off the main actor,
applies EXIF orientation and converts to sRGB. AVAssetWriter prepares a single
ProRes 4444 frame with alpha, exactly 1/24 second long. The composition inserts
its complete range and stretches it to the rational timeline hold; synthetic
still source In/Out points never seek into the prepared movie.

No FFmpeg playback runtime or new UI is required. FFmpeg generates the independent
red/blue video fixture used by the smoke. Tests compare decoded picture samples
with explicit expected geometry, colors and half-open cut visibility; they are
not a full-frame system-versus-FFmpeg color-parity qualification.

## Retained checks

On macOS 27.0.1 / Apple Silicon, the production backend passes 44 decoded seeks:

- Fit, fill and no scaling; leading black gaps and nonzero synthetic source trims.
- Repeated/backward seeks, exact still end cuts and lower-video visibility.
- Half-transparent green over red, and two stacked transparent stills over red.
  Image alpha and fit padding reveal lower picture; an opaque video layer stops
  composition below it, retaining its black fit bars.
- A clockwise EXIF 6 JPEG rotation with portrait fit geometry and expected color
  order; odd 81×53 crop and 41×21 pad boundaries without half-pixel translation.
- 24000/1001, 30000/1001 and 60000/1001 frame rates, including a single-frame
  60000/1001 hold shorter than the prepared movie.

The smoke also checks live play/pause across a still boundary, session cache
reuse, removal of prepared movies on close, malformed-image rejection, a 4097px
image refusal, an animated GIF refusal, pre-cancelled preparation and absence of
partial output. A separate helper experiment confirmed a 17×13 odd raster,
transparent pixels, and an exact 1/24-second decoded track duration.

Existing system video/audio sequence smoke, app file/import/bookmark smoke and
`scripts/verify.sh` pass. Verification includes 73 Python tests (eight optional
skips), 103 core XCTest tests (two optional skips), 87 Swift Testing tests,
workspace smokes and an unsigned Debug Xcode app build. Legacy AVFoundation APIs
produce macOS 27 deprecation warnings without build failures.

Reproduce with host media-service access:

```sh
scripts/system-still-smoke.sh /absolute/path/ffmpeg /private/tmp/afc-still-proof-new
scripts/system-sequence-smoke.sh /absolute/path/ffmpeg
scripts/app-file-smoke.sh
scripts/verify.sh
```

The optional second argument must be a new absolute output directory. Omitting it
removes generated media after the run. Fixture and source hashes plus the retained
passing message are in [results.json](results.json). Generated binaries/media stay
outside the repository.

## Bounds and remaining qualification

Each image is a single PNG/JPEG with dimensions at most 4096×4096. Preparation
has a 15-second encoder readiness/completion deadline, at most 512 distinct stills
and a 256 MiB session file budget. Images are prepared serially and reused by URL
for the immutable backend session. Closing or rebuilding releases its temporary
movies; failed/cancelled preparation removes its partial file. No cache persists
in the project document.

The test fixture and readback use explicit sRGB contexts and colors. DeviceRGB
fixture colors undergo profile conversion and cannot be treated as sRGB byte
values. Preview performs normal image-profile conversion; the canonical FFmpeg
export path does not qualify matching ICC behavior. Wide-gamut/HDR, arbitrary
ICC profiles, full-frame spatial/color parity, other EXIF orientations, animated
PNG, encoder timeout injection, maximum-cache exhaustion, signed sandbox encoder
access and hardware/display synchronization remain unqualified. The restrictive
tool sandbox cannot access the ProRes encoder; host runs pass, which does not
establish signed app sandbox behavior.
