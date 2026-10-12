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
restoration. It opens only a new untitled workspace. Cleanup terminates only
processes whose executable path exactly matches that temporary copy and deletes
only its generated preferences domain. An installed/running app and user documents
are not opened or quit. macOS can still register temporary bundle locations and
write temporary restoration state; the script records unexpected saved state.

`AFC_LAUNCH_PROBE_LOG` enables a small native “Launch probe” control in the loaded
workspace. With the variable absent, no probe control or timer is created. JSONL
records distinguish diagnostic startup from actual window readiness:

- `application_did_finish_launching`: AppKit finished launch; **not** readiness.
- `workspace_loaded`: the document has been loaded into its editor store.
- `probe_attached`: the loaded workspace's probe is attached to an actual window.
- `workspace_visible`: that window is visible, key, belongs to a real document,
  and its content has undergone layout and `displayIfNeeded`.
- `scripted_interaction_processed`: a later main-loop turn sends mouse-down and
  mouse-up through that window; the native button's action actually runs.

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

A passing result qualifies an empty workspace handling a synthetic native-control
interaction in this local bundle. It does not measure physical input, monitor
scanout/compositor presentation, populated-project editing, helper initialization,
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
