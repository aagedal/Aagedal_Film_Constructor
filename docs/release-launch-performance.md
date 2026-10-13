# Release launch responsiveness proof

Run from a logged-in macOS desktop with Xcode installed:

```sh
python3 scripts/release-launch-proof.py \
  --output /private/tmp/afc-release-launch-proof --runs 5 --timeout 20
```

The output directory must not already exist. The harness builds Release into a
new temporary DerivedData directory, disables distribution signing and bundled
media helpers, and launches separate copies through Launch Services. Each copy
has a unique bundle identifier, fresh AppStorage preferences, and ignored window
restoration. By default it opens a new untitled workspace. `--project path/to/project.afcproject`
opens a separate temporary copy on each run; the original project is never edited.
Referenced media URLs/bookmarks are preserved, so choose an appropriate test project. Cleanup terminates only
processes whose executable path exactly matches that temporary copy and deletes
only its generated preferences domain. Cleanup waits for each isolated executable
to quit before launching the next sample, preventing overlapping test windows. An installed/running app and user documents
are not opened or quit. macOS can still register temporary bundle locations and
write temporary restoration state; the script records unexpected saved state.

`AFC_LAUNCH_PROBE_LOG` enables a small native “Launch probe” control in the loaded
workspace. With the variable absent, no probe control or timer is created. JSONL
records distinguish diagnostic startup from actual window readiness:

- `application_did_finish_launching`: AppKit finished launch; **not** readiness.
- `workspace_loaded`: the document has been loaded into its editor store; records
  whether it is saved and its asset/track/clip counts.
- `probe_attached`: the loaded workspace's probe is attached to an actual window.
- `readiness_gate_changed`: records visibility, key status, document attachment,
  nonzero bounds and application-active state whenever that gate changes.
- `workspace_visible`: that window is visible, key, belongs to a real document,
  and its content has undergone layout and `displayIfNeeded`.
- `scripted_interaction_processed`: a later main-loop turn sends mouse-down and
  mouse-up through that window; the native button's action actually runs. Polling
  continues until the action runs, allowing a retry if readiness changes between
  the gate and the deferred click. `workspace_visible` can therefore repeat.

The reported duration starts immediately before spawning `/usr/bin/open`, so it
includes the Launch Services request and process startup. It ends when the Python
harness observes the flushed interaction marker; the 10 ms polling interval and
log-write overhead make this a conservative upper bound. App records also retain
system uptime, process ID and window number. The manifest includes Release build
command, Xcode/OS/architecture, instrumentation source hashes, executable hash,
helper inventory, every sample, failures, and min/median/max for valid interactions.
Timeouts and builds without markers fail instead of reporting fast startup.

The first measured run has fresh preferences but possibly warm OS/framework caches.
Later runs deliberately use warm OS caches and fresh preferences. These are **not**
rebooted or cache-purged cold launches. Launch Services models an ordinary app launch. Before the guarded default-launch
fallback was added, both direct executable and Launch Services launches reached
AppKit did-finish without creating a workspace on this machine. The fallback
uses [AppKit’s default-launch flag](https://developer.apple.com/documentation/appkit/nsapplication/launchisdefaultuserinfokey)
to exclude file, print, service and restoration launches, and shares the existing
deferred/coalesced document-count checks with the untitled callback.

A passing result qualifies the measured workspace handling a synthetic native-control
interaction in this local bundle. Project mode verifies saved-document status and
loaded asset/track/clip counts against its input. It does not measure physical input,
monitor scanout/compositor presentation, ordinary project editing, helper initialization,
or signed sandbox/notarization behavior. No accessibility permissions or injected
external system input are required. The full two-second version-one acceptance
remains open until representative cold and warm runs of the packaged app and
ordinary editing controls are measured and visually qualified.

The [retained experiments](evidence/release-launch-20261012/README.md) include
the original startup failure, a five-of-five passing post-fix run and a repeat
with four-of-five valid interactions. The repeat's failed run still loaded its
workspace and attached the probe, but never passed the visible/key-window gate.
Do not discard that sample or interpret the faster passing samples as consistent
two-second acceptance. Native visual inspection could not be completed.

A deterministic offline populated fixture is available for measuring document/UI
loading separately from media decoding:

```sh
python3 scripts/generate-launch-project.py \
  --output /private/tmp/afc-launch-3000.afcproject --clips-per-track 1000
python3 scripts/release-launch-proof.py \
  --output /private/tmp/afc-launch-3000-proof --runs 5 --timeout 12 \
  --project /private/tmp/afc-launch-3000.afcproject
```

This produces 3 tracks, 3,000 clips and 2 sources at deliberately nonexistent URLs.
It preserves the retained native fixture's video/audio selections and uses unique,
deterministic clip IDs with nonoverlapping ten-second spacing. There are no media
bookmarks, proxies or proxy jobs. The workload exercises offline project loading
and initial layout; it cannot qualify media-ready launch or playback.

The [reliability and populated-document follow-up](evidence/release-launch-reliability-20261012/README.md)
retains five-of-five valid empty launches at 1.153–1.259 seconds (median 1.171)
and five-of-five valid 3,000-clip offline saved-project launches at 4.106–4.784
seconds (median 4.500) before timeline clip culling. That populated run fails the two-second target. Gate diagnostics
and retrying the deferred click improve the measurement, but these samples do not
prove the earlier key-window timeout is eliminated or qualify cold packaged launch.

Timeline lanes now create only clips intersecting the horizontal viewport plus
200 pixels of overscan. A bounded first-layout range avoids mounting the whole
project before scroll geometry arrives. Canvas widths, ruler and scroll extents
still use the full project duration. Selected clips and active move, trim and fade
gestures stay mounted outside the viewport; gesture reset/cancellation releases the
active pin. Existing clip disappearance cancels previews and clears geometry.

The [same 3,000-clip offline workload after culling](evidence/release-launch-culling-20261012/RESULTS.md)
processed five-of-five native probe actions in 0.769–1.191 seconds (median 0.844),
compared with 4.106–4.784 seconds (median 4.500) before culling. All five saved
workspaces confirmed their 2 assets, 3 tracks and 3,000 clips. These local samples
pass the two-second synthetic-control target, while cold packaged launch, ordinary
editing controls and media-ready acceptance remain open. Run
`scripts/timeline-visibility-smoke.sh` for first-layout, scroll-coordinate, edge,
zoom, overscan and pinned-interaction policy checks; it is included in `verify.sh`.
