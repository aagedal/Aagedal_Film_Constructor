# Stream-copy assessment

EditorCore now includes `StreamCopyAssessment`, a pure assessment of picture and
audio independently. It is a foundation for the planned **Copy original streams**
workflow. The app still exports rendered ProRes/PCM; no app stream-copy export command
or importer-connected packet verifier is implemented.

The initial assessment accepts at most one component of each kind, covering the
whole sequence without generated gaps or duration changes. It checks original
stream identity, source offsets, raster, square pixels, rotation, exact frame rate,
audio layout/sample rate, whole-stream channel selection, routing, gain and fades.
It rejects stills, multiple components and unsupported transformations with typed
reasons. Edited audio can be rejected independently while picture remains eligible
under the evidence contract.

Eligibility also requires fresh evidence supplied by a future packet verifier.
That evidence identifies the asset, original URL, source fingerprint, stream,
exact source range and destination container, and includes codec parameters and
known geometry/color metadata. The verifier must establish exact packet cuts,
independently decodable starts, complete outgoing dependencies, exact timestamp
rebasing, codec delay/padding and container preservation. Codec names and FFprobe
keyframe flags alone cannot supply this proof. The caller is responsible for
checking that the evidence still describes the current original bytes.

The current importer supplies none of this packet evidence, so its metadata alone
produces an ineligible assessment. A successful assessment is conditional on the
verifier's assertions; it is not a guarantee that an output has been qualified.
Actual remuxing still needs decoded boundary-frame, timestamp, duration, sync and
packet-payload comparisons. Cuts-only concatenation, multiple whole audio streams,
and copying picture while rendering audio remain future work.

Run the core suite with `swift test --package-path Packages/EditorCore`. The
assessment tests cover missing and mismatched evidence, independent picture/audio
results, packet/dependency failures, geometry/rate changes and edited audio.

## Bounded development remux proof (2026-10-12)

[`scripts/stream-copy-proof.py`](../scripts/stream-copy-proof.py) now qualifies
and actually remuxes one exact source range into a private scratch MOV. This is
standalone development evidence; it supplies no evidence to `StreamCopyAssessment`
and does not enable the app export mode.

The deliberately narrow input contract is QuickTime MOV with exactly one ProRes
HQ (`apch`, `yuv422p10le`) picture stream, one whole 48 kHz mono/stereo signed
16/24-bit little-endian PCM stream, and one explicit timecode track. Non-drop
labels are supported at every listed rate; drop-frame labels are supported at
30000/1001 and 60000/1001.
Supported rates are 24, 25, 24000/1001, 30000/1001 and 60000/1001. Sources must
have zero stream offsets, identical A/V extents, square pixels and no rotation,
side data, codec delay/padding, timestamp reordering or packet gaps. MOV edit
lists are inspected directly: nonzero media offsets, empty/preroll edits,
multiple edits and rate changes are rejected even when FFprobe presents a
zero-based stream. Sources are bounded to 60 seconds, 128 MiB, 640×360 pixels
and 5000 picture packets; these are proof limits, not product restrictions.

The verifier requires both cut boundaries to be existing complete video and
PCM packet boundaries using exact rational timestamps. It checks ProRes packet
headers and decodes the selected first/last compressed frames in separate fresh
decoder processes, for both source and output. It never infers safe dependencies
from the FFprobe keyframe flag. The restricted ProRes codec and actual independent
boundary decoding support this intra-frame experiment; they do not qualify
H.264/HEVC GOP boundaries or arbitrary intra codec variants.

After remuxing with `-c copy`, every selected packet payload SHA-256, size, exact
PTS/DTS and duration must match the source after exact rebasing. The verifier
also compares all decoded picture-frame hashes, every decoded integer PCM
sample, channel layout, codec/geometry/color metadata, exact output frame rate,
stream duration and sync, and the MOV timecode packet's frame count and extent.
The timecode label advances by the exact source in-point frame count; it is not
copied unchanged. The actual MOV timecode sample description must agree with the
picture rate, nominal frame count and label's drop-frame mode. Counter and unknown
flags are rejected. These fields follow Apple's [timecode sample description](https://developer.apple.com/documentation/quicktime-file-format/timecode_sample_description)
and [flag definitions](https://developer.apple.com/documentation/quicktime-file-format/timecode_sample_description/flags).
Skipped drop-frame labels and a selected extent crossing midnight are rejected.
Seeking arguments are conservatively truncated to FFmpeg's
microsecond precision, but an output only passes if its rational packet times
are exact. No adjusted cut is accepted.

All subprocesses have a 60-second limit and bounded streamed stdout/stderr
capture. Hashes are computed in chunks. Scratch directories have mode 0700;
existing outputs are refused before launching FFmpeg and `-n` is also supplied.
The source fingerprint must be unchanged after verification. Failed output stays
in scratch for investigation and is never reported as qualified.

Example (the source must satisfy the full narrow contract):

```sh
python3 scripts/stream-copy-proof.py /absolute/ffmpeg /absolute/ffprobe \
  /absolute/source.mov 64064/3000 128128/3000 /absolute/new-private-scratch
```

Run the pure regressions normally, or set both executable paths to enable the
real media matrix:

```sh
STREAM_COPY_FFMPEG=/absolute/ffmpeg STREAM_COPY_FFPROBE=/absolute/ffprobe \
  python3 -m unittest discover -s scripts -p test_stream_copy_proof.py -v
```

[`result.json`](evidence/stream-copy-20261012/result.json) retains only the small
summary and helper version/fingerprint evidence. Generated barcode-picture and
stereo chirp sources, copied outputs and isolated packets are temporary. The
matrix qualifies exact nonzero ranges at all five rates and rejects non-frame
cuts, video-aligned but PCM-packet-unaligned cuts, closed/open-GOP H.264 and AAC.
Additional pure regressions reject hidden MOV offsets, timestamp gaps/reordering,
zero packet duration, delay/padding side data, excessive subprocess output and
existing destinations. Compressed/interframe copy,
VFR, HDR, larger/other raster formats, arbitrary MOV metadata,
source relocation races and app-level evidence freshness remain unqualified.

## Exact cuts-only concatenation development proof (2026-10-12)

[`scripts/stream-copy-concat-proof.py`](../scripts/stream-copy-concat-proof.py)
qualifies two to four ranges of compatible sources within the same narrow MOV
contract. Each range first passes the complete single-range proof. Source codec
parameters, color/geometry and audio format must match, and the assembled sequence
must remain within 60 seconds. Only generated relative names enter the FFconcat
manifest, so original paths never become concat directives. Existing scratch
contents and destinations are refused.

The concatenated output must preserve every compressed packet payload, exact
rebased PTS/DTS/duration at every join, all decoded video frames and integer PCM
samples, and the first selected range's advanced timecode across the full sequence.
The first/last frame of every segment, including internal joins, must decode
independently from the final output's isolated packets. Original fingerprints
are checked again after final decoding. A successful FFmpeg command alone does
not establish eligibility.

Create a JSON manifest with exact rational seconds, for example:

```json
[
  {"source": "/absolute/a.mov", "start": "8/3", "end": "16/3"},
  {"source": "/absolute/b.mov", "start": "0", "end": "8/3"}
]
```

```sh
python3 scripts/stream-copy-concat-proof.py /absolute/ffmpeg /absolute/ffprobe \
  /absolute/ranges.json /absolute/new-private-scratch
```

The expanded real-media suite passes 17 tests. Retained
[`result.json`](evidence/stream-copy-cuts-20261012/result.json) records nine
single-range cases (including both DF rates across ordinary/tenth-minute
boundaries), four two-source concatenations at 24, 24000/1001, 30000/1001 DF
and 60000/1001 DF, and explicit incompatible-audio/midnight rejections. Every
minute boundary through a full DF day is exercised by pure arithmetic tests.
Four additional pure tests cover the concat manifest and destination isolation.
This enables no app stream-copy mode or importer evidence. Mixed copied/rendered
streams, receiver conform, interframe/compressed audio, arbitrary metadata and
signed execution remain open.
