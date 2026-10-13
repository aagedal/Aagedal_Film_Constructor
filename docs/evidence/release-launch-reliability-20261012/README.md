# Release launch reliability and populated-document measurement

Two isolated unsigned Release experiments on the same local desktop use fresh
preferences per run, warm OS/framework caches, no bundled media helpers and a
synthetic native probe button. Neither experiment is a rebooted cold launch,
shipping sandbox measurement, physical input test or visual qualification.

| Workspace | Valid interactions | Minimum | Median | Maximum | Every run below 2 seconds |
| --- | ---: | ---: | ---: | ---: | --- |
| Empty untitled | 5/5 | 1.153 s | 1.171 s | 1.259 s | Yes |
| Offline saved project, 3,000 clips | 5/5 | 4.106 s | 4.500 s | 4.784 s | No |

The [empty manifest](empty/manifest.json) and
[populated manifest](offline-3000/manifest.json) retain all samples, build commands,
source/executable hashes, environment and per-sample gate state. JSONL milestones,
application stderr and a build summary are retained alongside them. Both builds
succeeded. Every populated sample confirmed a saved document with exactly two
assets, three tracks and 3,000 clips before claiming interaction. No sample was
discarded. The populated workload exceeds the two-second target.

Generate the populated input with:

```sh
python3 scripts/generate-launch-project.py \
  --output /private/tmp/afc-launch-offline-3000.afcproject --clips-per-track 1000
```

The generator derives audio/video selections from the retained native baseline,
uses deterministic unique clip IDs and nonoverlapping ten-second spacing, and
points both sources to deliberately nonexistent URLs. The project has no media
bookmarks, proxies or jobs. Each run opens its own copied document via Launch
Services. The original fixture remains unchanged. This is an offline project
loading/layout workload, not media-ready editing or decoder acceptance.

The readiness probe now waits until the native button action actually runs,
rather than stopping before its deferred click. It can retry a click if the
window loses readiness between turns. The harness waits for the isolated process
to quit before starting another run. Gate transitions record visible/key/document/
bounds/application-active state without forcing activation or relaxing readiness.

The earlier retained [failed gate sample](../release-launch-20261012/repeat-after-fallback/run-2.jsonl)
never emitted `workspace_visible`; a deferred-click retry alone does not explain
or prove correction of that failure. These new passing samples did not reproduce
it. Future stalled samples will contain the exact failed gate state. The full
packaged-app cold/warm launch and ordinary editing-control acceptance remains open.
