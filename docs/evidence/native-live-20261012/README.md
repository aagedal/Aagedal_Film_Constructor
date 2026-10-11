# Scripted native live monitor smoke

Retained from `/private/tmp/afc-live-scripted-preroll-20261012` using local FFmpeg
libraries and the passing barcode project's originals. Reproduce with:

```sh
python3 scripts/native-live-proof.py \
  --pkg-config /absolute/path/pkg-config \
  --project /absolute/path/barcode-proof/project.json \
  --output /absolute/path/new-live-proof --launch --scripted-duration 3
```

The standalone AppKit window opened, played, sought to frame zero, paused, resumed
and closed. Both executable and observation-validation exit codes are zero.
Thirteen JSON records retain transport, last displayed frame, action timestamps,
per-play scheduling counters and errors. The final record has no errors, a paused
transport at sample 70,656/frame 44, and last displayed frame 43. Final-play-epoch
counters include 23,552 observed render samples and 15 displayed frames; the
maximum queued audio was 4096 samples. Counters reset on each explicit Play and
are not totals across the whole run.

The first exercise exposed negative player-node sample times during startup and
stopped before progress. Its observations are retained separately. The fix waits
for the first nonnegative tick under the existing two-second startup deadline,
without clamping or advancing transport. Negative clock values after startup and
rate mismatches still fail explicitly. The rerun's 22 runtime tests passed, with
coverage for startup policy, geometry and observer scoping/cleanup.

This is a local hardware-output transport smoke, not synchronization qualification.
Observations use AVAudioPlayerNode's render clock and ordinary uptime; neither
acoustic speaker arrival nor display refresh was measured. Device switching,
interruptions, latency, real-time decoder deadlines, surround output and automatic
underrun recovery remain unqualified. `hardwareQualified` remains false in every
record. Configuration changes are covered by deterministic observer/policy tests,
not a physical device-switch exercise. The shipping app does not link this engine,
and these local FFmpeg dependencies do not qualify a macOS 14 shipping bundle.

`manifest.json` retains project/executable/library hashes and the launch command;
`live-observations.jsonl` contains the successful action history. Builds and media
remain temporary. macOS audio-component services required execution outside the
restricted tool sandbox.
