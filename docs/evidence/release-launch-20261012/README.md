# Isolated Release launch evidence

The [workflow](../../release-launch-performance.md) measures a real loaded
workspace window handling an opt-in native button mouse event. These are unsigned,
helper-free local Release bundles with unique preferences domains. The measurement
includes the Launch Services request and harness receipt of the event marker.

Three retained experiments deliberately include failures:

- `before-fallback`: only one of five runs reaches interaction, at approximately
  4.6 seconds. The other runs finish AppKit launch without loading a workspace.
- `first-after-fallback`: all five runs load a workspace and handle interaction
  in 1.157–1.284 seconds, median 1.215 seconds.
- `repeat-after-fallback`: all five runs load a workspace and attach its probe.
  Four handle interaction in 1.108–1.383 seconds. Run 2 never reaches the
  visible/key-window gate within the timeout. It remains a failed sample; the
  experiment does not meet its all-runs-under-two-seconds condition.

The default-launch fallback fixes the observed document-creation path. It does
not establish consistent activation/input readiness. Each experiment retains its
manifest, source/executable hashes, exact build/launch commands, every JSONL
milestone, app diagnostics and build completion summary. Full build logs remain
in the corresponding `/private/tmp/afc-release-launch-proof-*-20261012` folders.
Startup policy smokes also preserve non-default launches, existing/queued
documents, restoration precedence, coalescing, reopen and creation-error retry.

The first run has fresh preferences but unpurged OS caches; later runs have warm
OS caches and fresh preferences. These are not reboot-cold launch measurements.
Physical input, display presentation, populated-project editing, media helpers,
signed sandbox/notarized bundles and consistent activation remain unqualified.

A native computer-use inspection stalled and the parent interrupted it after
the completed measurement. Its raw result was `aborted by user after 265.7s`;
this was orchestration cancellation, not a user request to cancel this task.
No native visual inspection or physical click qualification is claimed.
