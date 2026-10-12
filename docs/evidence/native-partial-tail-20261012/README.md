# Native playback with a partial final video frame

`NativePlaybackPlan` retains the exact edit duration and rounds only the number
of output video frames upward, matching the render compiler. Sample-aligned audio
may extend past a frame-aligned picture cut. The uncovered final frame is black;
transport stops at the exact edit duration, rather than extending to the end of
the containing video frame. Video clip placements and ranges still require the
sequence frame grid, and audio components still require the sample grid.

Core regressions cover 24, 24000/1001 and 30000/1001, compiler/playback count
agreement, final-sample addressing, seek clamping and a one-sample audio-only
sequence. The full core suite passed 86 XCTest cases (two optional dependency
checks skipped) and 74 Swift Testing cases. All 43 native runtime cases passed.

The real media proof passes the baseline and a primed-plan replacement whose
audio ends one sample after picture frame 180: 181 video frames, 288,289 samples
per channel, exact duration 288289/48000 seconds. Sequential and asynchronous
native output match the independently rendered FFmpeg output, with maximum mean
RGB error 2.0 and maximum PCM error 0.5 s16 unit. The final native frame is exactly
black. Eleven video seeks and fourteen audio seeks include the partial final
frame and last audio sample, plus backward seeks and decoder rebuilding. Each
variant passes 282 AVAudioEngine offline clock observations; transport stops
without adding a video-frame interval to the audio duration.

Reproduce with a completed barcode render fixture and a new output directory:

```sh
python3 scripts/native-sequence-proof.py \
  /opt/homebrew/bin/ffmpeg /opt/homebrew/bin/ffprobe \
  /opt/homebrew/bin/pkg-config \
  /private/tmp/render-compiler-baseline-20261011 \
  /private/tmp/new-native-partial-tail-proof --partial-tail-only
```

`result.json` retains comparisons and artifact hashes, the per-variant manifests
retain clock/seek observations, and the source/helper manifests identify this
run. Full generated media remains in
`/private/tmp/afc-partial-tail-final-proof-20261012`. Offline audio rendering needed
host CoreAudio access; the sandbox could not instantiate AVAudioPlayerNode.
This is development evidence using local FFmpeg libraries. Shipping-app sequence
playback, live device/display timing, source resampling and release dependency
packaging remain unqualified.
