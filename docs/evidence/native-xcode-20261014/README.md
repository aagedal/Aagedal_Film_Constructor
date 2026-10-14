# Native Xcode development integration — 2026-10-14

The app and both Swift packages now target macOS 27, as requested. This permits
the existing local FFmpeg/native closure without weakening deployment checks.
Explicit local Debug selection builds and embeds the runtime through ordinary
Xcode build phases. Default Debug and Release builds retain system AVFoundation.

The selected native app contains the native sequence adapter, confirmed by its
actual `NativeSequenceBackend` symbols. This check caught an initial false-positive
link-only build: SwiftPM's Xcode backend placed modules directly in the products
folder, while the first include setting searched only `Modules`. Both layouts are
now included. The final artifact is
`/private/tmp/afc-native-xcode-selected-import-20261014.app`.

`results.json` records the app/closure macOS 27 floor and hashes for all 17 bundled
libraries. `build-selection.json` records exact build flags, Swift version, selected
pkg-config output and hashes of both packages' source inputs. The supplied notices
and provenance explicitly remain unreviewed; `releaseCertified` stays false.
Release/archive native opt-in and universal builds are refused.

The production controller smoke was compiled against the actual Xcode-embedded
libraries. Its closure hashes match the final corrected workspace. It passes
original/proxy decoded-frame parity, nonzero representation switching, exact seeks,
play/sample-clock/pause, edit/replay and deactivation. The loader environment was
cleared of DYLD overrides before enabling DYLD_PRINT_LIBRARIES for observation.
`controller-library-loads.log` retains the bundled loads and success; the complete
log at `/private/tmp/afc-native-xcode-controller-smoke.log` contains no Homebrew,
/usr/local or runtime-build-directory library loads. This is controller qualification
against the app's dependencies, not a signed sandbox GUI acceptance test.

Disabling selection and rebuilding the same derived directory succeeds. Native
adapter symbols, runtime link dependency, Frameworks and NativeRuntime resources
are all gone. Both selected and disabled build logs remain at
`/private/tmp/afc-native-xcode-selected-import-build.log` and
`/private/tmp/afc-native-xcode-disabled-import-build.log`.

Packaging regressions cover re-embedding, input preservation, deployment refusal
before staging, signing/preparation failure preserving previous output, unowned
framework refusal, symlink rejection and inverse input/output overlap. The latter
prevents rebuilding over selected notices/provenance or libraries. Six integration
regressions cover local configuration, include layouts, exact target/sdk/tool flags,
invalid paths and Release/archive/architecture/attribution refusal.

The full verifier passes 100 core tests (two optional skips), workspace smokes and
unsigned Debug. The final Python suite passes 72 tests (eight optional skips).
Unsigned Release passes independently. Full logs are
`/private/tmp/afc-plan-macos27-verification-host.log`,
`/private/tmp/afc-plan-macos27-python-final.log` and
`/private/tmp/afc-plan-macos27-release-host.log`. Restricted runs hit SwiftPM cache
access or AVAudioEngine hardware-service restrictions; unchanged host-service runs
pass. A second relocated controller proof passes with a strict 27.0 packaging
ceiling under `/private/tmp/afc-native-macos27-controller-host-20261014`.

Reproduce local selection using [the setup instructions](../../sequence-monitor.md#native-playback-in-xcode-debug).
The native decoder still admits its qualified CFR/SDR/still and matching-rate PCM
subset. Packaging does not establish compressed-audio/resampling/VFR/color parity,
complete release attribution, distribution signing/notarization, signed sandbox
media grants, acoustic synchronization or display presentation timing.
