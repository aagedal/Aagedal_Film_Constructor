# Integer and fractional rendered export proof

The 2026-10-12 development run passed four persisted-project exports through
`TimelineRenderPlan` and `FFmpegRenderCompiler`, followed by independent FFprobe,
raw RGB and PCM decoding. The fixture compiler is the existing `RenderPlanProof`
executable. No production compiler changes were needed.

| Rate | Mode / read-back start | Decoded frames | Samples per channel | Active audio samples (end exclusive) |
| --- | --- | ---: | ---: | --- |
| 24/1 | NDF `01:00:00:00` | 180 | 360,000 | 60,000–300,000 |
| 24000/1001 | NDF `00:59:59:22` | 180 | 360,360 | 60,060–300,300 |
| 30000/1001 | DF `00:00:59;28` | 180 | 288,288 | 48,048–240,240 |
| 60000/1001 | DF `00:00:59;56` | 180 | 144,144 | 24,024–120,120 |

The [machine-readable result](evidence/fractional-export-20261012/result.json)
records executable versions and SHA-256 fingerprints, exact counts and measured
channel amplitudes, leakage and sample phase error. Full transient artifacts
(source media, project/command manifests, probe JSON, raw decodes and logs) are in
`/private/tmp/afc-fractional-export-20261012-final` on the development machine.

## Assertions

- All 180 frames in each output decode to independent ten-stripe binary IDs:
  lower source frame `n + 30`, upper source frame `n + 57` on sequence frames
  3 through 119. The source bit distinguishes identical frame numbers from
  different sources. Stripe values must stay within 12 RGB levels of the
  independently calculated reference. This checks source in-points, every
  frame, cut boundaries and upper-layer priority.
- Every decoded frame presentation timestamp equals `n × denominator / numerator`
  using integer PTS and the probed rational time base. No rounded decimal
  timestamp comparison or compiler-provided frame count serves as the oracle.
- Output is 160×90, square-pixel ProRes HQ at the exact rational frame rate with
  stereo 48 kHz PCM s24 audio. Decoding to interleaved s16 verifies the exact
  independent sample count.
- Audio is byte-zero outside its exact sample-aligned placement. The left
  channel contains the second source audio stream (880 Hz) and the right
  contains the first (440 Hz), both at gain 0.5. Fourier measurements at the
  beginning, middle and end check amplitude and opposite-frequency leakage.
  Comparing 480 PCM samples at each window to the known sine phase checks
  source in-point and sequence placement; maximum permitted s16 error is 4.
- FFprobe reads the expected start timecode tag. Independently inspecting the
  four-byte MOV `tmcd` packet verifies start frame count and exact packet
  duration. DF cases start just before the first skipped-label minute boundary;
  the NDF fractional case crosses a minute boundary. Together with exact frame
  timestamps this establishes the stored origin and timing correspondence.

## Reproduction

Use explicit executable paths and a new absolute output directory:

```sh
python3 scripts/fractional-render-plan-proof.py \
  /opt/homebrew/bin/ffmpeg /opt/homebrew/bin/ffprobe \
  /private/tmp/afc-fractional-export-new-run
```

Python assertions are part of this proof; run without `-O`. The runner builds
EditorCore in its output directory, synthesizes lossless CFR qtrle source media
and tone streams, writes rate-specific projects, compiles and runs the actual
export command, and verifies the decoded output. Tool fingerprints make a run
auditable rather than assuming a particular installed FFmpeg version.

## Remaining qualification

This evidence covers the fixed MOV/ProRes HQ/PCM development workflow and the
listed CFR fixture rates. It does not qualify native player/editor import,
preview/export parity, arbitrary codecs or containers, VFR, mixed source rates,
source rotation/color metadata, scaling from differing rasters, channel layouts
beyond this stereo route, or stream-copy export. MOV carries a start timecode
packet, not per-frame labels; native receiver handling of skipped DF labels
still requires a real receiver check. Milestone 5's native import and broader
source/container acceptance remain open.
