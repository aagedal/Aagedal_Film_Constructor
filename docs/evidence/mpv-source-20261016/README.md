# MPVKit source transport qualification — 2026-10-16

The isolated source proof links the locally cached CoreAudio-fixed MPVKit revision
`400202b687841fb394cbf0ef59ad8c6fcfc1275b`. It does not link or change the app's
playback engine. The runner requires explicit dependency/helper paths, makes no
downloads, and records every linked archive's SHA-256, compiler command, executable
hash, fixture hashes and source revision. Declared upstream zip checksums are
recorded separately; this run hashes extracted bytes, not the original zip.

The grayscale timing matrix passes 24 create/load/play/pause/destroy cycles,
120 exact seek-coordinate checks, and 100 decoded RGB frame comparisons against
independent FFmpeg decoding. Each cycle seeks forward, backward and repeatedly
across GOP boundaries at 0, 1.5, 0.25, 2 and 0.5 seconds. Fixtures include
ProRes/PCM MOV, audio-first ProRes/PCM Matroska, H.264 with B-frames/AAC, and
open-GOP HEVC/AAC. Separate video-only/audio-only selections verify disabled tracks.
The selected second audio stream is resolved by its container `ff-index` and
kind to its actual MPV ID; enumeration order is never used. Missing and wrong-kind
stream selections are explicitly rejected in 12 additional negative cases.

Maximum grayscale mean RGB error is 1.8199132 and maximum individual component
error is 3, under unchanged bounds of mean 3 and peak 32. All time coordinates
stay within one 24 fps frame. Audio-first Matroska makes picture stream index 1
and audio indices 0/2; MPV picture ID is still 1 and selected audio ID is 2.

The same colored matrix **fails all 100 pixel comparisons**, with maximum mean
RGB error 5.2922454 and peak 255. These failures are retained, and the diagnostic
exits nonzero. They do not justify color qualification. Grayscale deliberately
isolates frame identity from the unresolved chroma/color conversion difference;
it is not general preview/export parity.

This cache cannot supply the attempted PNG screenshot path. Encoder-free
`screenshot-raw video bgr0` captures the decoded source frame instead, with bounded
shape/stride/payload validation and explicit packed RGB24 output. The proof uses
null video/audio sinks: CoreAudio, decoded audio fidelity, GPU presentation,
physical A/V synchronization, asynchronous callback lifetime, proxy picture with
original audio, signed media grants and application integration remain untested.
The static FFmpeg 8.1.2 closure also needs explicit symbol isolation/coexistence
qualification with the native timeline runtime's FFmpeg 9.0.2 before app linking.
No broader import formats or default backend changes are claimed.

## Reproduce

Supply the clean pinned checkout, its extracted artifact cache, explicit helper
executables, and a new absolute output directory:

```sh
python3 scripts/mpv-source-proof.py \
  /absolute/path/to/MPVKit \
  /absolute/path/to/SourcePackages/artifacts/mpvkit \
  /absolute/path/to/ffmpeg /absolute/path/to/ffprobe \
  /private/tmp/afc-mpv-source-new
```

Repeat with `--color-fixtures` before the positional arguments for the negative
color matrix. The runner retains reports on failure and exits nonzero; it never
widens comparison bounds. Requires macOS 27/Xcode and the complete cached static
artifact closure. Production builds never discover helpers through `PATH`.

`grayscale-result.json` and `color-result.json` retain commands, hashes,
per-cycle transport observations and every comparison. Representative loaded
track lists for each fixture/selection, link output and helper version are
retained alongside them. Full generated media/raw frames remain in the absolute
temporary directories recorded in each report.
