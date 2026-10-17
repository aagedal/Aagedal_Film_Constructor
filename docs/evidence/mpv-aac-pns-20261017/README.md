# AAC perceptual noise substitution and nonzero loading seeks — 2026-10-17

The preceding [absolute-PTS diagnostic](../mpv-pts-seek-20261016/README.md)
obtained exact AAC counts but divergent content after nonzero tail seeks. This
checkpoint varies AAC fixture encoding with `--aac-pns default|on|off`, leaving
MPV decoding, source PCM patterns, stream selection, range coordinates and
comparison policy unchanged. Explicit modes pass `-aac_pns 1|0` to the external
FFmpeg encoder. Default preserves the original command. Other codecs are unaffected.
This is an encoder control, not an MPV decoder correction or a source admission rule.

Three complete AddressSanitizer matrices retain 288 comparisons and 48 successful
missing/wrong-kind stream rejections. All use forced lavf, basic MOV edits,
absolute-PTS filtering, 500 ms loading preroll, two audio stream identities,
44.1 kHz mono and 48 kHz stereo. Each independent external FFmpeg reference is
decoded from that run's encoded fixture. Exact counts and per-channel mean/peak
amplitude bounds remain 1e-6/1e-5, with no alignment, padding or capture repair.

Default and explicitly enabled PNS each pass 68/96: PCM 24/24, ALAC 24/24,
AAC 16/24 and MP3 4/24. Their AAC fixture hashes and all 24 AAC capture hashes
are identical. Disabling PNS passes 72/96, with AAC improving to 20/24. All
20 bounded PNS-off AAC ranges match the independent reference byte for byte,
including the four tail ranges whose playback starts are strictly greater than
zero. Default/on tail peak errors remain approximately 0.109–0.182.

This isolates PNS-enabled fixture seek divergence. The result supports a
decode-history explanation for those content errors, but does not establish a
fixed sufficient preroll, qualify arbitrary AAC bitstreams or repair existing
media. Turning PNS off changes the compressed source and the corresponding
reference; it does not make the original failing source pass.

All four natural AAC outputs still fail exact counts in every mode: 820 extra
samples at 44.1 kHz and 384 at 48 kHz. MP3 failures remain unchanged. Every matrix
therefore intentionally exits 1. No application code, backend selection, tolerance
or production format admission changes. CoreAudio/GPU presentation, hardware
synchronization, proxy composition, signed sandbox access and distribution remain
open. Application source playback continues to use AVFoundation.

## Reproduction

```sh
python3 scripts/mpv-audio-proof.py --sanitize-address \
  --range-mode pts-filter --filter-preroll 0.5 \
  --demuxer lavf --mov-edit-list basic --embedded-reference --aac-pns off \
  /absolute/path/to/MPVKit \
  /absolute/path/to/SourcePackages/artifacts/mpvkit \
  /absolute/path/to/ffmpeg /private/tmp/afc-mpv-pns-off-new
```

Repeat with `--aac-pns default` and `--aac-pns on`, using fresh output directories.
Reports retain commands, explicit fixture controls, source/executable/dependency
hashes, fixture hashes and every passing/failing comparison. Capture hashes and
representative logs are retained here; full artifacts remain at the report paths.
Representative logs have trailing whitespace removed. AddressSanitizer instruments
the proof client and embedded reference, not the cached library archives.

Verification: 109 Python tests pass (eight optional skips); all three complete
runtime matrices finish without client failures. Source hashes match the tested
workspace, all 48 selection rejections pass, default/on AAC fixture/capture
identities pass, and all 20 bounded PNS-off AAC outputs are byte-exact. Independent
implementation review and diff checks pass for this diagnostic scope.

A separate review of the earlier MP3 captures found exact content shifted by small
sample offsets and millisecond Matroska packet timestamps. A same-packet container
timebase control is a useful next diagnostic; timestamp quantization is currently
a hypothesis, not a qualified cause or correction. Natural AAC EOF and faithful
seeking of existing PNS-enabled AAC remain unresolved.
