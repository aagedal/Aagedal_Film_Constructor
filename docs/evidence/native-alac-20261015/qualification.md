# Native ALAC qualification, 2026-10-15

The native FFmpeg bridge admits ALAC only with 16/24-bit source metadata,
canonical mono/stereo channels and 44,100/48,000 Hz sample rate. Existing guards
still require an absolute local regular file, seeking support, zero initial PTS,
no codec delay/padding or decoded skip-sample metadata, stable decoded shape and
a full-source exact, contiguous timestamp scan. AAC and MP3 remain rejected.

The direct ASan/UBSan run passed **313 checks**, including **68 rejections**, with
FFmpeg 9.0.2. Eight ALAC fixtures cover every rate/channel/depth combination. Each
has 20,037 samples per channel and verified packet starts at 0, 4096, 8192,
12288 and 16384, ending with a partial packet. Whole-file float output from the
explicit helper matches independent integer-pattern source data exactly.
The C bridge independently compares every whole-range sample with the same
mathematical source pattern; head/tail requests, every internal packet boundary
before/at/after, reverse and repeated reads, spans across three packets and
failed-request recovery also match exactly. Nonzero ALAC starts, a timestamp gap,
unqualified rates/channel counts, resampling and invalid ranges are rejected.
The existing PCM/video checks also pass. Sanitizers instrument the bridge and
check executable; the installed FFmpeg dylibs are not sanitizer builds.

The native sequence run also passed for two mono ALAC source streams at 48 kHz
in each qualified depth. Both variants preserve the fixture's 180 frames and
288,288 stereo output samples. Synchronous mixing, actor reads and offline
AVAudioEngine output differ from the independent PCM render by at most 0.5 of
one signed 16-bit unit. All 13 audio seek spans (including repeated/backward and
decoder reset), 10 video seek frames, and sequential native/actor captures pass.
The actor retains 122,880 bytes in its 128 KiB result cache and no pending requests.

This is offline image/audio qualification, not a measurement of live display,
CoreAudio synchronization or latency. Only the direct bridge matrix covers the
44.1 kHz and stereo source variants. The native sequence 24-bit fixtures preserve
16-bit sine source precision in a 24-bit ALAC encoding; the direct bridge's 24-bit
patterns exercise nonzero lower bits. No additional compressed codecs, rates,
channel layouts, offsets/gaps, resampling, malformed-file behavior or bundled
shipping dependencies are qualified.

Reproduce with explicit local helpers and new absolute output directories:

```sh
python3 scripts/render-plan-proof.py /opt/homebrew/bin/ffmpeg /opt/homebrew/bin/ffprobe /private/tmp/alac-barcode
python3 scripts/native-decoder-check.py /opt/homebrew/bin/ffmpeg /opt/homebrew/bin/pkg-config /private/tmp/alac-barcode /private/tmp/alac-decoder
python3 scripts/native-alac-sequence-proof.py /opt/homebrew/bin/ffmpeg /opt/homebrew/bin/pkg-config /private/tmp/alac-barcode /private/tmp/alac-sequence
```

The native sequence proof requires host CoreAudio access. The initial sandboxed
run aborted while instantiating AVAudioPlayerNode with `comp != nullptr`; the
recorded successful run used host access. Its failure log is retained alongside
the successful proof results. The direct sanitized check needs no audio device.
Fixture media, binaries, build caches and raw decoded captures remain in scratch
storage; this directory retains commands, source/tool/fixture identities, checks
and native capture manifests.
