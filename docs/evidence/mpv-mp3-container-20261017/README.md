# MP3 same-packet container and loading-range diagnostic — 2026-10-17

The preceding [AAC PNS checkpoint](../mpv-aac-pns-20261017/README.md)
left MP3 absolute-PTS loading ranges at 4/24. This checkpoint adds an explicit
`--mp3-container matroska|mov-remux` fixture control. Default preserves the
original commands. MOV mode first generates the original Matroska fixture,
then remuxes all three streams with `-map 0 -c copy`. It requires an explicit
`--ffprobe` and rejects changed stream identities, formats or ordered packet
payloads before decoding. No production source backend or format admission changes.

Three complete AddressSanitizer matrices retain 288 decoded comparisons and
48 successful missing/wrong-kind stream rejections. All use forced lavf and
basic MOV edit-list handling. Two use absolute-PTS filtering with 500 ms loading
preroll; the third uses integer sample filtering from source zero. Exact counts
and per-channel mean/peak amplitude limits remain 1e-6/1e-5. Captures are never
aligned, padded, trimmed or repaired by the comparator.

Matroska repeats 68/96: PCM and ALAC each 24/24, AAC 16/24 and MP3 4/24.
MOV with absolute-PTS filtering passes 82/96: MP3 improves to 18/24, while all
other codec results remain unchanged. All 18 passing MP3 captures are byte-exact
against fresh independent FFmpeg references decoded from the MOV fixtures.
Four natural MOV MP3 outputs fail counts, and both 44.1 kHz nonzero tail seeks
fail content (peak errors approximately 0.446 and 0.410). The 48 kHz tail seeks pass.

MOV with sample filtering from zero passes 68/96: PCM and ALAC each 24/24,
AAC 20/24, MP3 0/24. Every bounded MP3 count is exact but content fails; natural
counts fail as in the PTS control. This distinguishes the loading/filter controls,
but does not establish a generally correct MP3 trim or random-access strategy.
Every matrix intentionally exits 1 for incomplete broad audio qualification.

## Packet identity and boundary confounds

Both MOV matrices verify identical ordered `(size, SHA256)` packet sequences for
all three streams, including both MP3 identities at ff-index 0 and 2. Each audio
stream contains 116 packets at 44.1 kHz or 126 at 48 kHz. Audio timebases change
from Matroska's 1/1000 to MOV's 1/44100 or 1/48000. Full packet manifests retain
PTS, DTS, duration, payload hashes and side data; the result reports also retain
first/last packets and stream timebases.

The control changes gapless metadata as well as timestamp representation.
At 44.1 kHz the first packet's skip count changes from 1105 to 1103 and the last
discard count from 227 to 228. At 48 kHz the skip changes from 1105 to 1104 and
the final discard of 47 is absent. These observations hold for both selected
streams. External FFmpeg reference counts consequently change from 132300 to
132301 at 44.1 kHz and from 144000 to 144048 at 48 kHz. The reports explicitly
record failed MOV-versus-original exact-count comparisons and both reference hashes.

Natural MPV MOV output contains 133632 samples/channel at 44.1 kHz and 145152 at
48 kHz, exceeding its corresponding external reference by 1331 and 1104 samples.
This is a same-packet container diagnostic, not a pure timebase isolation or a
repair for existing sources. It supports container-dependent boundary behavior;
it does not establish timestamp quantization alone as the cause of all failures.
Natural EOF, faithful nonzero MP3/AAC seeks, arbitrary media, asynchronous seeks,
CoreAudio/GPU presentation, hardware synchronization, proxy composition, signed
sandbox access and distribution remain unqualified. App playback uses AVFoundation.

## Reproduction and verification

```sh
python3 scripts/mpv-audio-proof.py --sanitize-address \
  --range-mode pts-filter --filter-preroll 0.5 \
  --demuxer lavf --mov-edit-list basic \
  --mp3-container mov-remux --ffprobe /absolute/path/to/ffprobe \
  /absolute/path/to/MPVKit \
  /absolute/path/to/SourcePackages/artifacts/mpvkit \
  /absolute/path/to/ffmpeg /private/tmp/afc-mpv-mp3-mov-new
```

Repeat with `--mp3-container matroska` for the baseline. For the MOV from-zero
control, replace `--range-mode pts-filter --filter-preroll 0.5` with
`--range-mode sample-filter`. Always use a fresh output directory.

Retained reports contain exact commands, fixture/runtime/source hashes,
independent-reference comparisons and every case/rejection. Packet manifests,
capture hashes and representative logs accompany them; full artifacts remain at
the absolute report paths. Representative logs have trailing whitespace removed.
AddressSanitizer instruments the proof client, not cached dependency archives.

Verification: 111 Python tests pass (eight optional skips), all three runtime
matrices finish without client failures, all 48 selection rejections pass,
snapshotted source hashes match the tested workspace, and independent implementation
review and diff checks pass. Packet-order, payload, missing-data, format and
stream-identity regression cases reject invalid evidence.

Further diagnosis needs to preserve gapless metadata while varying timing, and
separately explain the 44.1 kHz nonzero tail content failure and MOV natural EOF.
