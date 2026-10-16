# MPV audio range and demuxer controls — 2026-10-16

The original decoded-audio failures are preserved. Explicit controls separate
lossless timestamp clipping from demuxer-dependent compressed-audio behavior;
no application source backend or format policy changes.

The same pinned MPVKit closure, independent external FFmpeg references, two
selected streams, rates/layouts, six ranges, exact sample counts and amplitude
limits from the [original proof](../mpv-audio-20261016/README.md) are used.
The script now accepts two independent switches:

- `--range-mode timestamp` (default) uses the original decimal `start`/`end`
  options. `--range-mode sample-filter` leaves these options unset and uses
  `lavfi=[atrim=start_sample=N:end_sample=M]` for bounded ranges. This actually
  filters inside MPV before the PCM sink; captures are never trimmed, padded,
  aligned or repaired by the comparator. Natural EOF cases use neither trim.
- `--demuxer auto` (default) retains automatic selection. `--demuxer lavf`
  explicitly selects MPV's FFmpeg demuxer before loading, preserving container
  `ff-index`/kind selection and post-load MPV audio-ID verification.

Four complete AddressSanitizer runs retain both controls independently:

- Timestamp/automatic repeats the baseline: PCM 12/24, ALAC 18/24, AAC 0/24,
  MP3 0/24; 30/96 comparisons pass.
- Timestamp/lavf: PCM 12/24, ALAC 18/24, AAC 0/24, MP3 4/24; 34/96 pass.
  All four natural MP3 selections now match reference samples exactly.
- Integer filter/automatic: PCM 24/24, ALAC 24/24, AAC 0/24, MP3 0/24;
  48/96 pass. All lossless ranges match reference samples exactly.
- Integer filter/lavf: PCM 24/24, ALAC 24/24, AAC 0/24, MP3 24/24;
  72/96 pass. All accepted PCM/ALAC/MP3 samples match exactly, with zero error.

All four matrices retain their nonzero qualification result because AAC fails.
All 64 wrong-kind/missing-stream selections are rejected before output.
The client and C argument parsing are built with AddressSanitizer; cached
media-library archives remain uninstrumented. All 102 Python tests pass with
eight optional skips. Independent review found no blocking implementation issues.

The integer filter is a bounded offline control, **not a random-access fix**:
it decodes all preceding samples from source zero. It does not qualify an
already-loaded player's asynchronous seeking, interactive latency, CoreAudio,
GPU presentation, clocks or proxy/original-audio composition. No PCM/ALAC/MP3
production admission expands based on this proof. The reports' common
start/end-loading limitation refers to the timestamp control; integer-filter
reports additionally record their decode-from-zero limitation.

Forcing lavf establishes a demuxer-dependent MP3 difference without claiming
all Matroska or compressed-audio priming is resolved. Retained `packet-edges.json`
records the first/last audio packets from external FFprobe 9, stream metadata,
fixture hashes and exact commands. Its MP3 first-packet `skip_samples` is 1105;
AAC final-packet discard padding is 820/384 at 44.1/48 kHz. This metadata comes
from the independent FFmpeg 9 tool, not MPV's embedded FFmpeg 8.1.2 demuxer.
AAC still has both sample-count and content errors; neither these controls nor
packet metadata establish the upstream cause or a faithful AAC playback path.

Each named result JSON retains the source/dependency/executable/fixture hashes,
exact compile/run commands, unchanged comparisons and stream rejections.
Representative logs retain the active filter and demuxer decisions. Complete
fixtures, captures and remaining logs stay in the temporary roots in the reports.

## Reproduce

Use a fresh output directory for each of the four switch combinations:

```sh
python3 scripts/mpv-audio-proof.py --sanitize-address \
  --range-mode sample-filter --demuxer lavf \
  /absolute/path/to/MPVKit \
  /absolute/path/to/SourcePackages/artifacts/mpvkit \
  /absolute/path/to/ffmpeg /private/tmp/afc-mpv-audio-controls-new
```

Requires the same explicit cached dependencies and macOS 27/Xcode environment
as the original proof; no dependencies are downloaded. Each broad run is
expected to exit 1. Inspect per-codec cases rather than treating that exit as
a harness failure or claiming full source qualification.
