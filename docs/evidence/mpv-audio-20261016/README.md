# MPV decoded source audio — 2026-10-16

The cached CoreAudio-fixed MPVKit candidate does **not** pass the full generated
source-audio matrix. The retained AddressSanitizer run intentionally returns
nonzero: 30 of 96 sample comparisons pass, while all 16 stream-identity rejections
pass. Ordinary application source playback remains AVFoundation.

`scripts/mpv-audio-proof.py` builds an isolated C libmpv client from the explicit
pinned checkout and extracted macOS artifacts. Its `on_preloaded` hook resolves
container `ff-index` plus audio kind before decoders are created, then verifies
the selected MPV audio ID after loading. Both audio streams are exercised in
containers ordered audio/video/audio, where container stream 2 is MPV audio ID 2.
Wrong-kind stream 1 and absent stream 99 must return an explicit identity
rejection before writing any audio. Output is captured through MPV's raw float32
PCM file sink; no system audio device is used.

The fixtures use independently seeded, nonperiodic signed-16-bit sample patterns
for each stream and channel. PCM, ALAC and AAC use MOV; MP3 uses Matroska. Each
codec has 44.1 kHz mono and 48 kHz stereo fixtures, with two selectable audio
streams. Independent external FFmpeg decodes each selected stream completely.
Each selection is compared across six fresh-player loads:

- Natural playback through EOF, compared with the entire FFmpeg decode.
- An explicit source range from zero through three seconds.
- 4,097 samples starting at source samples 1,023, 1,024 and 1,025.
- The final 4,097 samples of the nominal three-second source.

The 1,024-sample boundary targets AAC framing; these are fixed sample coordinates,
not a claim that every tested codec has the same packet size. Range loads use
MPV `start`/`end` options with 17-digit decimal coordinates. They do not qualify
an already-loaded player's asynchronous seek path.

Comparisons require identical sample counts, per-channel mean amplitude error
at most 0.000001 and peak amplitude error at most 0.00001, with full scale 1.0.
There is no offset fitting, padding, edge masking or relaxed lossy-codec bound.
Five Python regression tests reject missing samples, shifted content, wrong
streams, channel swaps, excessive means/peaks and malformed/nonfinite data.

All eight natural PCM/ALAC selections match their independent references exactly.
Across all ranges, PCM passes 12/24 and ALAC passes 18/24; some bounded ranges
produce one extra or missing sample, and the 44.1 kHz tails have content errors.
AAC and MP3 pass 0/24. Natural AAC output contains 133,120/144,384 samples per
channel versus FFmpeg's 132,300/144,000; natural MP3 output contains
133,406/145,105 versus 132,300/144,000. Bounded lossy cases also fail count or
content checks. Decoder logs identify the selected AAC decoder as FFmpeg `aac`,
not AudioToolbox. These observations locate qualification failures without
claiming their upstream cause or changing the application format policy.

Newly built client code uses AddressSanitizer; cached MPV/FFmpeg archives remain
uninstrumented. The client waits for normal EOF, verifies selection and destroys
MPV before reading the completed capture. Debug logs retain decoder, output
format, demux and EOF observations. The run reports its failed matrix honestly;
it is a completed diagnostic proof, not broad audio qualification. CoreAudio,
hardware clocks, live synchronization, proxy/original-audio composition, color,
signed sandbox access and distribution remain open.

`result.json` records exact commands, selected dependencies and hashes,
snapshotted source hashes, all comparisons and all rejections. Representative
logs are retained here; full fixtures, captures, references, executable and logs
remain under the temporary root in the report. All 100 Python tests pass with
eight optional skips. Independent review found no blocking harness issues.

## Reproduce

Use a new output directory and explicit cached dependencies; no downloads occur:

```sh
python3 scripts/mpv-audio-proof.py --sanitize-address \
  /absolute/path/to/MPVKit \
  /absolute/path/to/SourcePackages/artifacts/mpvkit \
  /absolute/path/to/ffmpeg /private/tmp/afc-mpv-audio-new
```

The broad matrix is expected to return exit 1 for this pinned candidate. Inspect
individual case results before making any qualification claim. Requires macOS 27,
Xcode and the pinned clean MPVKit checkout/artifacts used by the source proof.
