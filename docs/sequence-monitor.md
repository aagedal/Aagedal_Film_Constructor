# Edited-sequence monitor

The workspace has Source and Sequence monitor modes. Sequence mode reads the
edited timeline, retains original audio, forwards timeline seeks and frame stepping, and
routes K/L to sequence pause/play. Reverse sequence playback is unavailable.
Edits pause output, clear the previous image, close its decoder session, and rebuild
at the current playhead. Rapid seeks coalesce. Pause and scrubs during asynchronous
priming invalidate the pending play. Switching monitor modes or closing the
workspace shuts down sequence output; returning rebuilds at the preserved playhead.
Shutdown awaits decoder work and teardown before releasing media-access grants.

The representation button is available in both viewer modes. **Prefer Proxy**
verifies used timeline proxies asynchronously, then rebuilds at the current
playhead without changing edits. Switching pauses playback; choose Play to resume.
Rapid preference changes and hiding the viewer cancel verification. Missing,
stale, modified, legacy unhashed or unqualified proxies fall back to originals with
visible reasons. Sequence playback requires originals; it does not substitute
silent proxy-only output when original audio is unavailable.

Sequence proxy support requires imported qualified source picture metadata,
matching source/proxy/sequence cadence, zero stream offsets, complete trim coverage,
matching aspect ratio and rasters within the native 4096-pixel limit. Lower-resolution
proxy picture is composed using original dimensions for fit/fill/no-scaling;
proxy stream zero replaces only its recorded original video stream. Audio uses the
original stream selection, channel maps, gain and envelopes. Older projects without
qualified picture metadata use originals until their media is reimported.

## Default build and development runtime

Normal Xcode builds use the system AVFoundation backend for timeline preview.
Picture preparation reuses composition tracks across nonoverlapping clips, with
separate pools for motion video and prepared stills. Exact boundary events select
visible layers without rescanning the whole timeline at every cut; hidden cuts
with unchanged visible layers share one instruction. Audio components retain
independent tracks and envelope parameters. See
[composition scheduling evidence](evidence/system-composition-20261015/README.md).
It consumes the shared render plan with trims, upper-video precedence, black gaps,
fit/fill/no-scaling and verified proxy picture with original audio. Whole mono/stereo
streams must match the sequence layout with identity channel routing and gain up
to unity. Nonlinear fades/crossfades use curve-based approximate volume ramps,
with a visible qualification notice. Fades of 5 ms or less also show a warning
about substantial differences from export; finer ramps do not resolve the system
renderer's measured short-fade errors. See [fade-ramp evidence](evidence/system-fade-ramps-20261015/README.md).
Single-frame PNG/JPEG stills up to 4096 pixels per dimension are prepared off the
UI thread as one-frame ProRes 4444 movies using the system encoder. The composition
stretches that frame to the exact clip duration, including synthetic source In/Out
points; no FFmpeg helper is used at preview runtime. Fit/fill/no scaling, EXIF
orientation, PNG alpha and lower-picture visibility are retained. Prepared files
are reused within one backend session and removed on close; a rebuild prepares
them again. Preparation is cancellable with a 15-second encoder deadline, a
512-image limit and a 256 MiB temporary-file budget. Animated/multi-image sources
and larger images fail visibly. Wide-gamut/HDR and ICC-aware preview/export color parity, and signed sandbox
encoder access remain unqualified. Explicit channel maps and boosted gain require
the native FFmpeg runtime.

Run `scripts/system-still-smoke.sh /absolute/path/ffmpeg` for generated still and
video checks; add a new absolute output directory as the second argument to retain
fixtures and the executable. Host media-service access is required. FFmpeg creates
the reference video fixture only.

The generated codec/cadence matrix qualifies ProRes/PCM, H.264/AAC and closed-GOP
HEVC/AAC at 24, 23.976, 29.97 and 59.94 fps. Open-GOP HEVC trims can return black
without a decoder error and remain unqualified. See [system preview evidence](evidence/system-sequence-20261014/README.md)
for reproduction and limits. The [open-GOP diagnosis](evidence/system-open-gop-20261014/README.md)
confirms source/player random-access failures near GOP boundaries; a reader-only
capture replacement is insufficient.

[Decoded audio mix evidence](evidence/system-audio-20261014/README.md) qualifies
generated PCM/AAC mono/stereo at matching 44.1/48 kHz, with explicit amplitude
bounds for gain, fades and crossfades. Initial volume is established before delayed
clips begin, avoiding a brief unity-gain onset. Nonlinear ramps remain approximate;
AAC boundaries, resampling, measured A/V timing and signed sandbox media grants remain open.

Without an explicit local native selection, the app does not link the native runtime. Bundled FFmpeg and
FFprobe executables alone do not supply that library runtime. The runtime statically links FFmpeg 9.0.2
from the pinned [aagedal/MPVKit](https://github.com/aagedal/MPVKit) GPL build, so no local FFmpeg
libraries or pkg-config are needed. Native-enabled
builds use the existing FFmpeg bridge instead of the system backend.

An opt-in development harness compiles the production controller against the
existing qualified `NativePlaybackRuntime` bridge, generates a two-second 80x48,
24 fps FFV1/48 kHz stereo PCM fixture, and exercises actual output. It can also
build an isolated unsigned copy of the actual SwiftUI workspace:

```sh
python3 scripts/sequence-monitor-native-smoke.py \
  --ffmpeg /absolute/path/to/ffmpeg \
  --output /private/tmp/afc-native-workspace-proof \
  --build-workspace
```

The FFmpeg executable only generates fixtures and reference frames; the runtime
uses MPVKit's libraries. The first build downloads MPVKit's binary artifacts. The output directory
must be new. Without `--build-workspace`, only the production-controller smoke is
built and run. macOS audio services and Swift macro services require host access
when running under a restricted agent sandbox.

The output includes the SwiftPM runtime build, controller smoke executable,
`fixture.mov`, a normal `fixture.afcproject`, and independent FFmpeg `seek.rgb` and
`edited.rgb` reference captures, plus a distinct lossless proxy fixture and
`proxy-seek.rgb`. The synthetic proxy changes picture intentionally to expose an
accidental original decode; generated ProRes proxy verification is covered separately
by the workspace proxy smoke. With `--build-workspace` it also includes
`Native Sequence Workspace.app`. Launch the isolated app using the command emitted
by the script, for example:

```sh
open -n -a '/private/tmp/afc-native-workspace-proof/Native Sequence Workspace.app' \
  /private/tmp/afc-native-workspace-proof/fixture.afcproject
```

Click the timeline to select Sequence, or use the viewer header icon / Tab,
then play or seek in the timeline. This app uses
a distinct development bundle identifier. The runtime remains in the output build
tree; keep it available. It does not include executable media helpers, so workflows
that require bundled FFmpeg/FFprobe are unavailable in this isolated harness.
Do not distribute this app: no dependency collection, attribution qualification,
release signing, notarization, sandbox qualification, or minimum-OS acceptance is
performed.

## Verification and limits

`scripts/sequence-monitor-smoke.sh`, included in `scripts/verify.sh`, compiles the
controller with Swift 6/default MainActor isolation. Its injected delayed backend
checks explicit missing-runtime state, scrub coalescing, pause during priming,
scrub plus pause during priming preserving the pending target, edited-plan
replacement and prior-backend closure, deactivation, and reappearance. It also checks nonzero representation switching, resolved status,
obsolete verification cancellation and hiding/reappearing during verification. The app-file
smoke checks that K remains enabled during preparation, L is disabled then, reverse
source transport is disabled in Sequence mode, and K rejects a delayed sequence play.

The native smoke uses actual decoded video and PCM audio through AVAudioEngine.
It requires the exact playhead callback at 0.5 seconds and displayed frame 12
before starting output. Every RGB byte of that frame is compared with an independent
FFmpeg capture with maximum two-level rounding tolerance. After trimming both
components to source second one, output frame zero is compared the same way.
The same nonzero frame is also compared against the distinct proxy reference,
then against HiRes after switching back. The document and original-only FFmpeg
render command remain identical across switches. It checks live player sample-clock progress, stable pause position, edited-plan
replay and synchronous deactivation pause. It does not instrument completion of
native decoder shutdown or security-scope release; the injected lifecycle checks
verify the controller calls and awaits backend closure.

Native sequence qualification remains the runtime's existing bounded SDR,
square-pixel CFR video, matching-rate PCM and scoped 16/24-bit mono/stereo ALAC
at 44.1/48 kHz, with supported still/fade behavior documented in the native proof.
See [ALAC qualification](evidence/native-alac-20261015/qualification.md).
Broader compressed
audio/resampling/VFR/color support, shipping runtime packaging, measured acoustic
A/V timing, display presentation latency, device-switch acceptance and startup
latency remain open. Polling only publishes the native player's accepted sample
position; it does not advance the playhead using elapsed wall time.

See [sequence proxy evidence](evidence/sequence-proxies-20261013/README.md) for
runtime, controller and app-resolution verification and remaining limits.


System audio admission now requires each selected source's actual sample rate to
match the sequence sample rate. Unknown or differing formats fail visibly; choose
matching sequence settings or normalized media. Generated same-rate AAC starts
around an interior packet boundary pass, while cross-rate mixes fail decoded
fidelity bounds. See [boundary/resampling evidence](evidence/system-audio-resampling-20261014/README.md).
The opt-in native workspace runner can package a separate self-contained ad-hoc
development app with explicit notices/provenance. See
[native packaging evidence](evidence/native-runtime-packaging-20261014/README.md)
for the runner flags, loader checks and remaining release/macOS compatibility gaps.

Generated same-rate ALAC now passes source-head/tail/whole-source audio checks.
MP3 is refused by actual codec description after decoded trim/mix failures;
normalize sources to PCM or ALAC before sequence preview. Existing AAC preview
remains available, but source-edge/whole-source fidelity fails the current bounds;
interior/packet cuts retain their earlier qualification. See
[compressed-audio evidence](evidence/system-compressed-audio-20261014/README.md).

Native development packaging declares the actual library minimum macOS version
in the packaged app. Add `--package-runtime-deployment-target 27.0` alongside
notices/provenance to enforce the app’s macOS 27 baseline. The currently selected
local closure fits that baseline; attributed release dependencies remain open.


## Native playback in Xcode Debug

The app and both Swift packages now require macOS 27. Select the native runtime
for Debug builds:

```sh
python3 scripts/configure-native-playback.py --enable
```

This creates ignored `Configuration/LocalNativePlayback.xcconfig`. Build the
ordinary app scheme in Debug for Apple Silicon. Xcode builds the Swift runtime
before compiling the workspace; the first build downloads the pinned MPVKit
binary artifacts. FFmpeg and its dependencies are linked statically into
`libNativePlaybackRuntime.dylib`. The build discovers the complete non-system dylib closure,
checks thin arm64/deployment compatibility, relocates it into `Contents/Frameworks`,
and signs nested libraries before signing the app. The closure is the native
runtime alone; the separately bundled FFmpeg/FFprobe helpers
continue to support import, proxies and export.

`Contents/Resources/NativeRuntime` retains dependency hashes, actual deployment
versions, MPVKit's license notice, provenance naming the resolved MPVKit revision
and the exact build selection. No developer
library paths are needed at runtime. Selection remains development-only: Release
and archive native opt-in are refused while attribution and distribution review
are incomplete. The native engine still supports its qualified CFR/SDR picture,
PNG/JPEG stills and matching-rate PCM plus the qualified ALAC subset; packaging
does not qualify additional compressed audio, VFR or broader color behavior.

To return Debug builds to AVFoundation:

```sh
python3 scripts/configure-native-playback.py --disable
```

The next build removes owned native outputs. It refuses to replace unrelated
frameworks or unrecognized resources. System AAC preview keeps working and now
shows its source-edge approximation notice; normalize audio to PCM/ALAC when
faithful boundaries are required. See [AAC qualification status](evidence/system-compressed-audio-20261014/AAC-preview-notice.md).
