# MPV Source viewer on n9.0.2 — 2026-10-31

The Source viewer's libmpv backend (`NativeSourcePlayer`, `CNativeDecoder/NativeSourcePlayer.c`)
links MPV 0.41 and FFmpeg n9.0.2 from the pinned MPVKit fork (`7f5d3f5`,
`aagedal-1.1.0-n9.0.2-editor.1`), statically, in the same `libNativePlaybackRuntime.dylib`
as the native sequence engine. This rechecks the two problems the 8.1.2-era proofs found
(colour and AAC/MP3 seeking) against the build the app now links.

## Frame identity (what the Source viewer needs)

Fixture frames carry FFmpeg's own frame index in their luma (`geq=lum='16+4*N'`), so the
rendered picture names the frame on screen. Every check also compares it with FFmpeg's
decode of that index (`select=eq(n,k)`), mean RGB error below 3.

- `SourcePlayerTests` (package): NUT FFV1 at 24000/1001, MXF DNxHR LB at 25, and a NUT whose
  picture starts 0.52 s after its sound in a clock beginning at 10 s. Mid-frame requests show
  the frame covering them; the reported time is that frame's timestamp in asset time, and a
  mark rounded from it is the same frame index. Audio-first stream order resolves by kind and
  `ff-index`, wrong-kind and missing streams are rejected, and a generated ProRes proxy plays
  with the original's audio stream 2 (an external file, shifted by −10 s to the proxy's zero).
- `scripts/source-viewer-native-smoke.py` (app `EditorStore`): unconverted NUT 25, MXF and NUT
  23.976 imports install the libmpv backend; scrub, ±frame steps, In/Out marks (frames 13..<23
  as exact rationals), play/pause, reverse, Out at the asset end, switching to an AVFoundation
  asset (which closes the libmpv player), and proxy ↔ original switches keeping the paused frame.

## Colour

`colourAgainstFFmpegConversion` compares MPV's software render with FFmpeg's own RGB conversion
(`scale` with the tagged matrix, limited→full range, full chroma interpolation) of the same
decoded 4:2:2 frame:

| Fixture | Mean RGB error | Peak | Components > 32 | Flat areas: mean / peak |
| --- | --- | --- | --- | --- |
| SMPTE HD bars, BT.709, 1280×720 | 0.48 | 176 | 0.51% | 0.003 / 3 |
| testsrc2, BT.709, 1280×720 | 1.74 | 198 | 1.74% | 0.004 / 3 |
| SMPTE bars, SMPTE 170M, 640×480 | 1.03 | 130 | 1.12% | 0.005 / 2 |

"Flat areas" are pixels whose 5×5 reference neighbourhood is one colour. Matrix and range agree
there essentially exactly; the large peaks sit on chroma edges, where MPV's chroma upsampling
filter differs from FFmpeg's. The test asserts mean < 3 and flat-area peak ≤ 4. This replaces
the 8.1.2 result (all colored captures failing, mean up to 5.29, untagged ProRes guessed as
BT.601) for tagged media. Untagged media still depends on MPV's matrix guess. This is a viewer
check, not export parity.

## AAC/MP3 seeking (unchanged proof, n9.0.2 runtime)

`scripts/mpv-audio-proof.py` now accepts the n9.0.2 pin. The fixtures, controls and exact
comparison policy are unchanged; the retained `audio-*-result.json` files hold every case.

| Control | 8.1.2 | n9.0.2 | PCM | ALAC | AAC | MP3 |
| --- | --- | --- | --- | --- | --- | --- |
| Timestamp seeks, automatic demuxer (the Source viewer's mode) | 30/96 | 30/96 | 12/24 | 18/24 | 0/24 | 0/24 |
| Absolute-PTS filter, 500 ms preroll, lavf, basic MOV edit lists | 68/96 | 72/96 | 24/24 | 24/24 | 20/24 | 4/24 |
| As above, MP3 remuxed to MOV | 82/96 | 86/96 | 24/24 | 24/24 | 20/24 | 18/24 |

All 16 wrong-kind/missing-stream rejections pass in every run. On n9.0.2 the four natural AAC
outputs now have exact sample counts (the 820/384-sample excess is gone); the four nonzero AAC
tail seeks still fail on content, as with PNS-enabled fixtures before. MP3 is unchanged. Every
run exits 1, as intended for the broad qualification.

For the Source viewer this means: PCM/ALAC sound, which is all unconverted FFmpeg imports can
carry, starts sample-exactly only with the filter controls, which an interactive viewer cannot
use. With the timestamp seeks it does use, PCM passes 12/24 and ALAC 18/24, so source audio
after a seek is a monitoring approximation (not listened to or measured further here). AAC/MP3
reaches the Source viewer only from MOVs that AVFoundation reads but cannot decode the picture
of, and is not sample-exact either. Marks on media with picture follow the picture frame grid.
Export and the Sequence monitor do not use MPV audio.

## Reproduce

```sh
export PATH="$(dirname "$(xcrun --find swift)"):$PATH" SDKROOT=$(xcrun --show-sdk-path)
swift test --package-path Packages/NativePlaybackProof --filter SourcePlayerTests
python3 scripts/source-viewer-native-smoke.py --output /tmp/source-viewer-smoke
P=Packages/NativePlaybackProof/.build   # after one swift build, for the pinned checkout and artifacts
python3 scripts/mpv-audio-proof.py "$PWD/$P/checkouts/MPVKit" "$PWD/$P/artifacts/mpvkit" /opt/homebrew/bin/ffmpeg /tmp/a1
python3 scripts/mpv-audio-proof.py --demuxer lavf --mov-edit-list basic --range-mode pts-filter \
  --filter-preroll 0.5 "$PWD/$P/checkouts/MPVKit" "$PWD/$P/artifacts/mpvkit" /opt/homebrew/bin/ffmpeg /tmp/a2
python3 scripts/mpv-audio-proof.py --demuxer lavf --mov-edit-list basic --range-mode pts-filter \
  --filter-preroll 0.5 --mp3-container mov-remux --ffprobe /opt/homebrew/bin/ffprobe \
  "$PWD/$P/checkouts/MPVKit" "$PWD/$P/artifacts/mpvkit" /opt/homebrew/bin/ffmpeg /tmp/a3
```
