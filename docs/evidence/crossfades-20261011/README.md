# Linked audio crossfade parity evidence — 2026-10-11

The development proof passed all eight variants: baseline, linked overlap
(equal-power), linked adjacent cut (equal-power and linear), gaps/audio overlap,
standalone edge fades, reordered interframe video, and ordinary plan replacement.
Crossfade fixture relations are created by the actual `TimelineEditEngine`
`.setAudioCrossfade` action on compatible sibling tracks. Editorial clip ranges
remain intact; the render plan resolves source handles around adjacent cuts.

Each variant compares all 180 video frames and 288,288 stereo samples per channel
against an independently compiled FFmpeg render. Synchronous mixing, asynchronous
cache output, AVAudioEngine offline scheduling, 10 video seeks and 13 audio seeks
pass, including repeated/reverse seeks, transition boundaries/interior, decoder
rebuilds and primed plan replacement. All 282 output clock observations pass per
variant. Maximum mean RGB error is 2.0 and maximum audio error is 1.0 s16 unit.

All three linked variants also check every rendered sample against an independent
source waveform oracle. Equal-power uses `cos(progress*pi/2)+sin(progress*pi/2)`
for this deliberately correlated continuous-source fixture, exposing the expected
midpoint gain increase. Linear sums to unity. Overlap spans samples
`[144144,192192)`; centered adjacent source extensions span `[120120,168168)`.
The maximum oracle error is below 1.0 s16 unit. No limiter or normalization is
added. Three compiler/native-plan tests also qualify odd-sample adjacent handles,
complementary envelopes, exact source requests, unchanged duration and seeks.

Reproduction commands:

```sh
python3 scripts/render-plan-proof.py /opt/homebrew/bin/ffmpeg /opt/homebrew/bin/ffprobe /private/tmp/crossfade-render-20261011
python3 scripts/native-sequence-proof.py /opt/homebrew/bin/ffmpeg /opt/homebrew/bin/ffprobe /opt/homebrew/bin/pkg-config /private/tmp/crossfade-render-20261011 /private/tmp/crossfade-native-final-20261011
```

Both output directories must be new. The native command required execution outside
the filesystem/process sandbox: the sandbox run aborted during AVAudioPlayerNode
initialization because its CoreAudio component was unavailable. The passing run
uses local development FFmpeg 9.0.2 dylibs, with exact executable/library/source
hashes recorded here. These libraries target a newer macOS version than the
package's macOS 14 deployment target; they do not qualify a shipping distribution.

Retained files contain results, commands, identities, runtime/unit test logs,
and the three linked variants' projects, compiler graphs, native requests and
clock manifests (about 500 KB total). Generated media, decoded sample buffers,
build products and intermediate captures remain under the temporary run directory;
the result records their SHA-256 identities. Every source-manifest hash matched
the checkout after the passing run. Hardware output, live display, latency,
underrun recovery, video transitions and wider format/geometry coverage remain
unqualified. The shipping source monitor still plays original media.
