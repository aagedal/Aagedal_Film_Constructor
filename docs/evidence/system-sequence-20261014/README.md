# System preview codec and cadence checkpoint — 2026-10-14

Normal-build AVFoundation sequence preview passed 12 generated-media cases on
macOS 27.0.1 / Apple Silicon with Swift/Xcode 27 and FFmpeg 9.0.2. See the retained
[observations and fixture hashes](results.json).

Qualified fixtures: ProRes Proxy with stereo PCM, H.264 with three B-frames and
stereo AAC, and **closed-GOP** HEVC (`hvc1`) with B-frames and stereo AAC. Each was
checked at 24, 24000/1001, 30000/1001 and 60000/1001 fps.

Each case uses a generated eight-stripe barcode carrying the source frame number.
The production backend composes two trimmed, overlapping picture layers plus
original audio. Independent expected frame numbers check all 52 output frames
forward and backward, then eight repeated/random seeks (112 decoded checks per
case, 1,344 total). It checks leading/trailing black gaps, exact source in-points,
upper-layer precedence, a seek beyond the end, and live play/pause without reported
player errors. Grayscale stripe tolerance is 24 levels to accommodate codec and
system color conversion; this qualifies frame identity, not color accuracy.

Four **open-GOP HEVC** fixtures failed at the first trimmed upper-layer frame:
the system composition returned black rather than source frame 60, without a
player error. Changing only the encoder's `open-gop` setting to zero passed all
four rates. Do not consider open-GOP HEVC trimmed preview qualified. This test
cannot identify every problematic real-world stream from imported metadata;
proxy-mediated picture or the native engine remains the broader-format path.

Reproduce the passing matrix in a new absolute output directory:

```sh
python3 scripts/system-sequence-matrix.py /absolute/path/ffmpeg /private/tmp/afc-system-matrix
```

Add `--include-open-gop` to retain the four failure observations as well. That
run deliberately returns nonzero if any case fails, after writing all observations.
FFmpeg only generates fixtures; the backend runs through macOS media services.
Run outside a restrictive sandbox that blocks those services.

The backend now carries rational clip placement, source ranges and composition
boundaries into CMTime without a fixed 600,000-tick rounding step. Frame-end
clamping uses exact integer ceiling arithmetic. `system-sequence-smoke.sh` also
checks an audio-only nine-frame 24000/1001 sequence: scrubbing beyond its end must
display frame eight even though floating-point duration times rate exceeds nine.
Nonlinear audio envelopes retain their documented approximate volume ramps.

This is scoped synthetic seek/content and transport evidence. It does not measure
AAC/PCM waveform parity, sample-exact fades, hardware/display synchronization,
VFR/mixed cadence, HDR/color, arbitrary GOP structures, minimum-OS support, or
signed sandbox media grants. Those acceptance items remain open.
