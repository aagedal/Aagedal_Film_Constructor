# Edited-sequence monitor

The workspace has Source and Sequence monitor modes. Sequence mode reads the
edited timeline, uses originals, forwards timeline seeks and frame stepping, and
routes K/L to sequence pause/play. Reverse sequence playback is unavailable.
Edits pause output, clear the previous image, close its decoder session, and rebuild
at the current playhead. Rapid seeks coalesce. Pause and scrubs during asynchronous
priming invalidate the pending play. Switching monitor modes or closing the
workspace shuts down sequence output; returning rebuilds at the preserved playhead.

## Default build and development runtime

The normal Xcode app does not link development FFmpeg libraries. Sequence mode
therefore explicitly reports that native playback is unavailable. Bundled FFmpeg
and FFprobe executables alone do not supply the FFmpeg-library runtime.

An opt-in development harness compiles the production controller against the
existing qualified `NativePlaybackRuntime` bridge, generates a two-second 80x48,
24 fps FFV1/48 kHz stereo PCM fixture, and exercises actual output. It can also
build an isolated unsigned copy of the actual SwiftUI workspace:

```sh
python3 scripts/sequence-monitor-native-smoke.py \
  --pkg-config /absolute/path/to/pkg-config \
  --ffmpeg /absolute/path/to/ffmpeg \
  --output /private/tmp/afc-native-workspace-proof \
  --build-workspace
```

Supply existing explicit tools; the script installs nothing. The output directory
must be new. Without `--build-workspace`, only the production-controller smoke is
built and run. macOS audio services and Swift macro services require host access
when running under a restricted agent sandbox.

The output includes the SwiftPM runtime build, controller smoke executable,
`fixture.nut`, a normal `fixture.afcproject`, and independent FFmpeg `seek.rgb` and
`edited.rgb` reference captures. With `--build-workspace` it also includes
`Native Sequence Workspace.app`. Launch the isolated app using the command emitted
by the script, for example:

```sh
open -n -a '/private/tmp/afc-native-workspace-proof/Native Sequence Workspace.app' \
  /private/tmp/afc-native-workspace-proof/fixture.afcproject
```

Click the timeline to select Sequence, or use the viewer header icon / Tab,
then play or seek in the timeline. This app uses
a distinct development bundle identifier. Its FFmpeg libraries remain at the
explicitly selected local paths and the runtime remains in the output build tree;
keep both available. It does not include executable media helpers, so workflows
that require bundled FFmpeg/FFprobe are unavailable in this isolated harness.
Do not distribute this app: no dependency collection, attribution qualification,
release signing, notarization, sandbox qualification, or minimum-OS acceptance is
performed. A local library may itself require a newer OS than the package target.

## Verification and limits

`scripts/sequence-monitor-smoke.sh`, included in `scripts/verify.sh`, compiles the
controller with Swift 6/default MainActor isolation. Its injected delayed backend
checks explicit missing-runtime state, scrub coalescing, pause during priming,
scrub plus pause during priming preserving the pending target, edited-plan
replacement and prior-backend closure, deactivation, and reappearance. The app-file
smoke checks that K remains enabled during preparation, L is disabled then, reverse
source transport is disabled in Sequence mode, and K rejects a delayed sequence play.

The native smoke uses actual decoded video and PCM audio through AVAudioEngine.
It requires the exact playhead callback at 0.5 seconds and displayed frame 12
before starting output. Every RGB byte of that frame is compared with an independent
FFmpeg capture with maximum two-level rounding tolerance. After trimming both
components to source second one, output frame zero is compared the same way.
It checks live player sample-clock progress, stable pause position, edited-plan
replay and synchronous deactivation pause. It does not instrument completion of
native decoder shutdown or security-scope release; the injected lifecycle checks
verify the controller calls and awaits backend closure.

Native sequence qualification remains the runtime's existing bounded SDR,
square-pixel CFR video and matching-rate PCM subset, with supported still/fade
behavior documented in the native proof. Sequence proxies, broader compressed
audio/resampling/VFR/color support, shipping runtime packaging, measured acoustic
A/V timing, display presentation latency, device-switch acceptance and startup
latency remain open. Polling only publishes the native player's accepted sample
position; it does not advance the playhead using elapsed wall time.
