# Native live output route admission

The standalone monitor now admits matching mono/stereo hardware channels before
priming, after priming, immediately before engine startup and again after startup
before starting the player node. Surround or mismatched channel counts and
noncanonical speaker descriptions fail with an instruction to select a compatible
route. A rejected Play preserves the paused transport position; restoring a
compatible route permits explicit Play. Changes during blocked priming stop and
flush prepared buffers without starting output, and can also be explicitly retried.

Canonical metadata includes the Mono/Stereo layout tags, an explicit single Mono
or Center description, or two descriptions in Left/Right order. Unknown, discrete,
reordered and other named descriptions are rejected. Missing layout metadata is
accepted only for one/two channels. Hardware rate conversion remains delegated to
AVAudioEngine; the player sample clock must match the sequence rate.

The initial tag-only implementation passed 42 runtime tests but rejected the local
device during the scripted output run. The retained initial manifest and
observations show the error and incomplete actions: executable exit 0, observation
validation exit 1. An independent engine-format query reported 48 kHz stereo with
UseChannelDescriptions (tag 0), explicitly Left (1) then Right (2). Supporting this
exact canonical representation fixes the rejection without inferring channel maps.
The query is retained in `observed-route.json`; it is separate from the smoke's
per-action observations.

The final build and all 43 runtime tests in seven suites passed. Description tests
cover accepted stereo and both mono labels, plus reordered, unknown, discrete and
wrong labels. Lifecycle regressions verify paused position preservation and
explicit restart after route rejection, including a route change during priming.
`runtime-tests-summary.log` retains test results; `source-sha256.json` identifies
the implementation and regression sources.

The final actual macOS audio run completed play, seek to zero, pause, resume and
close in order. Both executable and observation-validation exit codes were zero.
Thirteen observations ended with no errors, at sample 70,656/frame 44 and last
displayed frame 43. Final-play counters recorded 24,064 accepted render samples,
15 displayed frames, at most 4096 queued samples, and zero underruns,
configuration changes or unexpected engine stops. Counters reset on explicit Play.
`manifest.json` records commands, executable/project/library hashes and the final
result; `live-observations.jsonl` records action and clock history.

Reproduce using the existing fixture and a fresh output directory:

```sh
env PKG_CONFIG_PATH=/opt/homebrew/Cellar/ffmpeg/9.0.2_1/lib/pkgconfig \
  python3 scripts/native-live-proof.py \
  --pkg-config /opt/homebrew/bin/pkg-config \
  --project /private/tmp/afc-native-geometry-final-20261012/baseline/project.json \
  --output /private/tmp/new-native-output-route-proof \
  --launch --scripted-duration 3
```

A preceding build completed its 43 tests, but could not collect dependency metadata
while local Homebrew FFmpeg was changing from revision 9.0.2 to 9.0.2_1. It did not
launch. The final retained run explicitly selects revision 9.0.2_1; its artifacts
remain in `/private/tmp/afc-native-route-qualified-20261012`. The actual output run
required host access to macOS audio services.

These checks conservatively admit a route; they do not identify physical speakers,
qualify actual device switching or measure acoustic arrival, display refresh,
A/V synchronization, latency or automatic recovery. `hardwareQualified` remains
false. The monitor is separate from the shipping app, and the local FFmpeg dylibs
target macOS 27 rather than the package's macOS 14 deployment floor. No signed,
redistributable dependency bundle is qualified.
