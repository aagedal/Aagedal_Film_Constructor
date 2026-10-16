# MPV absolute-PTS audio cuts after loading seeks — 2026-10-16

This follows the [timestamp seek-preroll diagnostic](../mpv-seek-preroll-20261016/README.md).
The earlier timestamp cuts pass only 40/96 comparisons with 500 ms demuxer preroll.
The new `--range-mode pts-filter --filter-preroll SECONDS` control separates the
requested output cut from MPV's playback start. It seeks to
`max(0, startSample / sampleRate - preroll)`, then applies
`lavfi=[atrim=start_pts=START:end_pts=END]:fix-pts=no`. No MPV end timestamp is set.
Natural cases still run without a start, end or filter.

MPV's audio lavfi input already uses `1/source_sample_rate` timestamps; the harness
does not install or measure that timebase. The generated fixtures use matching
source/output sample rates. Explicit `fix-pts=no` preserves incoming timestamps
instead of synthesizing sample positions from the start of the current decode.
The cached runtime lacks `asettb`; preliminary attempts to use that filter failed
and are excluded from the final matrices. Local MPV source inspection guided the
control, but does not authenticate the prebuilt archives or qualify arbitrary
source timestamps, discontinuities or complex edit lists.

The new preroll argument is required only for PTS-filter mode. Nonfinite, negative
and greater-than-one-hour values, other range modes, and combinations with the
separate timestamp-only `--seek-offset` are rejected before running. That older
option remains a demuxer offset; this experiment instead moves the playback start
and sets its additional demuxer offset to zero for bounded cuts. A bounded
nonblocking EOF log drain preserves decoder-selection evidence when MPV's
higher-priority EOF event overtakes buffered diagnostic messages.

Both complete AddressSanitizer matrices use forced lavf/basic MOV edit handling,
two audio stream identities, 44.1 kHz mono and 48 kHz stereo, and all six original
ranges. Every capture is compared to an independent FFmpeg decode with exact
sample counts and unchanged per-channel mean/all-sample peak limits of 1e-6/1e-5.
Captures are never aligned, padded, repaired or trimmed by the comparator.

Zero preroll passes 60/96: PCM 24/24, ALAC 24/24, AAC 8/24 and MP3 4/24.
At 500 ms, PCM/ALAC/MP3 stay unchanged and AAC improves to 16/24, totaling 68/96.
Every PCM and ALAC capture matches the reference bytes exactly, including all
nonzero tail seeks. This resolves the tested lossless timestamp-cut count failures
without changing either the fixtures' expected boundaries or the comparator.

The additional eight AAC passes are ranges starting at sample 1024 or 1025 at
both rates and both stream identities. All bounded AAC ranges now have exact
counts, but each nonzero tail seek still fails content parity (peak errors about
0.109–0.182 at 500 ms). The four natural AAC outputs remain byte-identical across
controls and retain 820/384 excess samples at 44.1/48 kHz. MP3 retains timestamp
count/content failures; its earlier decode-from-zero integer-filter result remains
a separate passing control. All 32 invalid-stream selections reject before audio
output. The MOV fixture hashes match across both controls.

Early cuts with 500 ms preroll clamp the playback start to zero. Only the later
tail ranges demonstrate nonzero loading seeks in that matrix. Passing fixtures
do not establish efficient arbitrary random access: this proof does not measure
work avoided inside the decoder, stops output through a filter rather than a
player end timestamp, and does not exercise asynchronous in-place seeking.
The source/audio timestamp relationship, AAC natural EOF, broader streams,
CoreAudio/GPU presentation, hardware synchronization, proxy composition,
signed sandbox access and distribution remain open. Application source playback
continues to use AVFoundation.

## Reproduction

```sh
python3 scripts/mpv-audio-proof.py --sanitize-address \
  --range-mode pts-filter --filter-preroll 0.5 \
  --demuxer lavf --mov-edit-list basic --embedded-reference \
  /absolute/path/to/MPVKit \
  /absolute/path/to/SourcePackages/artifacts/mpvkit \
  /absolute/path/to/ffmpeg /private/tmp/afc-mpv-pts-filter-new
```

Use a fresh output directory, and repeat with `--filter-preroll 0`. Reports retain
all commands, source/executable/dependency/fixture hashes, explicit controls and
failing comparisons. Each run retains its own independently generated MP3
Matroska fixture hashes. Representative logs here have trailing whitespace removed;
full fixtures/captures remain at the report paths. AddressSanitizer instruments
the proof client and embedded reference; cached libraries remain uninstrumented.
Broad qualification intentionally exits 1 while any audio comparison fails.

Verification: both complete final AddressSanitizer matrices retain 192 decoded
comparisons with no client failures and 32 successful invalid-stream rejections.
Snapshotted source hashes match the workspace. All 108 Python tests pass (eight
optional skips). Legacy timestamp and integer-filter AAC spot checks retain
byte-identical output. Independent implementation review and diff checks pass.
The first zero-preroll run exposed the EOF/log ordering issue and stopped at
57 comparisons; only the complete final runs after the bounded drain fix are
retained here.
