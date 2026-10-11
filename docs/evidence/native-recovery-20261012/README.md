# Native live recovery policy and scripted output smoke

The standalone native monitor now pauses on audio starvation at its last accepted
sample position, flushes scheduled output and requires an explicit Play to restart.
It does not automatically conceal gaps or resume. A rejected clock is not read
again during failure handling, and manual Pause applies the same queue validation
before accepting its final sample position. Per-play observations include an
`underruns` counter.

The retained runtime log reports 32 passing tests in six suites, using the local
FFmpeg libraries identified in `manifest.json`. Injected output clocks cover both
polling starvation and starvation after an awaited refill decode, preserving the
last accepted sample and rejecting late scheduling. Tests also cover explicit
restart with a new output-clock epoch, qualified/rejected final Pause readings,
unexpected engine stops, configuration-change policy and monitor release after
its first tick/display. A deterministic blocked decoder proves Pause, seek-to-end,
project replacement, Close and caller cancellation prevent cancelled priming from
starting audio output. Cancellation cannot interrupt a libavcodec call already in
progress; it rejects completion and queued work.

The actual macOS audio-output smoke opened, played, sought to zero, paused, resumed
and closed. Both executable and observation-validation exit codes were zero.
Thirteen observation records ended with no errors, a paused transport at sample
70,656/frame 44 and last displayed frame 43. Final-play counters recorded 23,552
accepted render samples, 15 displayed frames, a maximum 4096 queued samples and
zero underruns, configuration changes or unexpected engine stops. Counters reset
on explicit Play, so they are not whole-run totals.

Reproduce the actual output run in a fresh directory:

```sh
python3 scripts/native-live-proof.py \
  --pkg-config /opt/homebrew/bin/pkg-config \
  --project /private/tmp/afc-native-geometry-final-20261012/baseline/project.json \
  --output /private/tmp/new-native-recovery-proof \
  --launch --scripted-duration 3
```

`manifest.json` retains the launch/build/test commands and executable, project and
library identities. `live-observations.jsonl` retains the action/clock history;
`runtime-tests.log` retains the test results. `recovery-source-sha256.json`
identifies the recovery implementation and regression sources. Builds and fixture
media remain temporary, under `/private/tmp/afc-live-recovery-qualified-20261012`.
The actual audio run required access to macOS audio services outside the restricted
sandbox.

The recovery cases use injected clocks and device policy, not physical device
switching or a measured hardware starvation event. The successful output smoke
encountered no underrun. No acoustic arrival, display refresh, A/V synchronization,
latency or automatic recovery qualification is claimed; `hardwareQualified` stays
false. This engine remains separate from the shipping app. Homebrew FFmpeg 9
libraries target the local macOS 27 development host and do not qualify a signed
macOS 14 shipping dependency bundle.
