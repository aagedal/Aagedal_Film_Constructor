# MPV basic MOV edit-list control — 2026-10-16

This continues the [AAC priming/frame-duration diagnosis](../mpv-aac-preroll-20261016/README.md)
with an explicit option inside the actual MPV runtime. Application source playback
remains AVFoundation.

`--mov-edit-list basic` passes `advanced_editlist=0` through MPV's
`demuxer-lavf-o`. This preserves basic MOV edit-list processing; it does not set
`ignore_editlist`. The control requires `--demuxer lavf`, is reported by the C
client, and is checked by the Python runner. The default leaves this option unset.
The setting is supplied to lavf for the full matrix; MP3 Matroska does not use
MOV edit-list processing.

Two complete AddressSanitizer matrices use the same pinned MPVKit closure,
independent FFmpeg references, two selected audio streams, rates/layouts, six
ranges and unchanged exact sample counts and amplitude bounds (mean 1e-6,
peak 1e-5). Both use integer sample filters and forced lavf. The generated MOV
fixture hashes are identical between runs; independently generated MP3 Matroska
containers differ in hashes. Each report retains its own fixture hashes and
comparisons. No captures are trimmed, aligned, padded or repaired by the harness.

- Default mode repeats 72/96: PCM/ALAC/MP3 each 24/24; AAC 0/24.
- Basic mode passes 92/96: PCM/ALAC/MP3 each 24/24; AAC 20/24.
- All 32 missing/wrong-kind selections are rejected before output.
- Every bounded AAC whole/head/packet-edge/tail range passes. Maximum mean
  per-channel error is 5.13e-9 and maximum individual error is 8.95e-8.
- All four natural AAC outputs still fail exact count: 133120 instead of 132300
  samples at 44.1 kHz; 144384 instead of 144000 at 48 kHz. These are the same
  820/384 excess tails isolated by the previous explicit frame-duration control.

All 24 actual basic-mode AAC captures, including the complete excessive natural
tails, equal the corresponding unseeked embedded-decoder outputs byte for byte.
`capture-hashes.json` retains both hashes. This supports restored priming/sample
content for this fixture subset without treating direct-decoder trimming as a
repair to MPV output. The natural-tail failures remain intact, and both runners
intentionally exit 1.

Local FFmpeg 8.1.2 source inspection shows basic and advanced edit-list modes use
different index/priming representations. Basic mode adjusts initial DTS and private
`start_pad`; advanced mode rebuilds index timestamps and marks excluded packets
for discard. MOV seeking computes skip samples from that state. MPV's lavf
preroll uses public `codecpar.initial_padding`, which this AAC path does not set.
This is a source-based explanation to investigate further; packet-level causality
for the observed change is not established by this option comparison.

This qualifies a bounded offline control for generated simple MOV edits, not
complex/multiple/empty edit lists, efficient random access, asynchronous source
seeks, CoreAudio/GPU presentation, hardware sync, proxy composition, signed
sandbox access or distribution. Integer `atrim` still decodes from source zero.
Faithful natural AAC EOF remains unresolved inside MPV. No app backend or format
admission changes are made.

## Reproduction and verification

```sh
python3 scripts/mpv-audio-proof.py --sanitize-address \
  --range-mode sample-filter --demuxer lavf --mov-edit-list basic \
  --embedded-reference /absolute/path/to/MPVKit \
  /absolute/path/to/SourcePackages/artifacts/mpvkit \
  /absolute/path/to/ffmpeg /private/tmp/afc-mpv-basic-edit-list-new
```

Use a fresh output directory. Repeat with `--mov-edit-list default` for the
baseline. `basic-result.json` and `default-result.json` retain commands, source,
dependency/executable/fixture hashes and all comparisons. Representative logs
are retained here with trailing whitespace removed; complete fixtures, raw logs
and captures remain at report paths.
AddressSanitizer instruments the client and direct reference executables; cached
library archives remain uninstrumented. All tested script hashes match the
workspace. Verification includes 105 Python tests (eight optional skips), both
complete runtime matrices, independent implementation review and diff checks.
