# MPV timestamp-range seek preroll — 2026-10-16

This follows the [basic MOV edit-list control](../mpv-mov-edit-list-20261016/README.md).
That earlier 92/96 result uses integer filtering after decoding from source zero.
This experiment instead asks MPV to load timestamp start/end ranges, with explicit
high-resolution demuxer seek preroll. Application source playback stays AVFoundation.

The new `--seek-offset SECONDS` control sets `hr-seek=yes` and
`hr-seek-demuxer-offset` before initialization. It is accepted only in timestamp
mode, requires finite nonnegative seconds within the finite C float range, and retains
MPV's observed offset in every successful case. The runner checks that readback
against the requested value converted to MPV's float storage exactly; for example,
0.1 reads back as 0.10000000149011612. Defaults leave both options unset. Invalid
stream selections still reject before audio output.

All runs force lavf and basic MOV edit-list handling. Each complete matrix uses
the pinned cached MPVKit candidate, two audio stream identities, 44.1 kHz mono and
48 kHz stereo, PCM/ALAC/AAC/MP3, and the same six ranges. Independent FFmpeg
references, exact counts and unchanged per-channel mean/all-sample peak bounds
(1e-6/1e-5) apply. No capture is aligned, trimmed, padded or repaired. Natural
playback has no start/end limit or filter, so excess EOF samples remain visible.

With zero preroll, PCM passes 12/24, ALAC 18/24, AAC 4/24 and MP3 4/24: 38/96.
At 100 ms, AAC improves to 6/24 and the other codec totals remain unchanged:
40/96. The two new passes are the 44.1 kHz selected-stream ranges starting at
sample 1024. Their peak errors fall from approximately 0.29 to below 6e-8.
At 500 ms, the matrix remains 40/96 with the same codec totals.
Both rates' later AAC tail ranges still have large content errors despite matching
counts. Timestamp boundaries also retain one-sample count differences in several
PCM/ALAC/AAC cases. Increasing decoder preroll alone does not establish exact
sample-range output.

The four natural AAC outputs continue to emit 820 extra samples at 44.1 kHz and
384 at 48 kHz. The earlier direct embedded-decoder frame-duration control remains
a separate diagnostic; it never repairs these MPV captures. These timestamp
results do not invalidate the prior bounded integer-filter qualification.

Local MPV v0.41.0 source inspection guided this control: `player/playloop.c`
subtracts the configured offset from the demuxer seek target while retaining the
requested playback target; `player/audio.c` clips audio to target timestamps.
`demux/demux_lavf.c` derives automatic audio preroll from public initial-padding
metadata. The cached source is investigative context, not authentication of the
prebuilt archives or proof of the exact cause of remaining content/count errors.

Natural AAC frame-duration handling, sample-exact efficient random access,
asynchronous in-place seeks, broader edit lists, hardware presentation/sync,
proxy composition, signed sandbox and distribution remain open. This control
changes the development proof only.

## Reproduction

```sh
python3 scripts/mpv-audio-proof.py --sanitize-address \
  --range-mode timestamp --demuxer lavf --mov-edit-list basic \
  --seek-offset 0.1 --embedded-reference \
  /absolute/path/to/MPVKit \
  /absolute/path/to/SourcePackages/artifacts/mpvkit \
  /absolute/path/to/ffmpeg /private/tmp/afc-mpv-seek-preroll-new
```

Use a fresh output directory, and repeat with offsets 0 and 0.5. Reports retain
commands, fixture/dependency/executable/source hashes, observed options and all
failing comparisons. Representative logs here have trailing whitespace removed;
full fixtures and captures remain at report paths. MOV fixture hashes match across
all three controls; MP3 Matroska retains independently generated container hashes.
`capture-hashes.json` records all 288 captures and confirms byte-identical natural
AAC outputs across controls. AddressSanitizer instruments
the client and direct embedded-reference executable; cached library archives
remain uninstrumented. Broad qualification exits 1 intentionally.

Verification: all 288 runtime decodes complete and all 48 invalid-stream
rejections pass across the three AddressSanitizer matrices. Tested source hashes
match the workspace. All 107 Python tests pass (eight optional skips), independent
implementation review finds no blocking issue, and diff checks pass.
