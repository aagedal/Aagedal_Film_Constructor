# Populated Release launch after timeline viewport culling

The same deterministic offline saved project (2 assets, 3 tracks, 3,000 clips)
was launched five times through Launch Services using separate unsigned Release
app copies with fresh preferences, warm OS caches and no bundled media helpers.
Each loaded workspace confirmed the expected saved-document state and counts.

| 3,000-clip offline workspace | Valid actions | Minimum | Median | Maximum |
| --- | ---: | ---: | ---: | ---: |
| Before culling | 5/5 | 4.106 s | 4.500 s | 4.784 s |
| After culling | 5/5 | 0.769 s | 0.844 s | 1.191 s |

All five after-culling samples were below two seconds; no samples were discarded.
The median is approximately 81% lower. These are local observations with no
reboot/cache purge, rather than a guarantee for packaged or media-ready launch.
The before and after manifests retain the same input SHA-256. Executable hashes
identify each built artifact; the after manifest also hashes TimelineView and its
visibility helper. The [manifest](manifest.json), per-run JSONL/application stderr,
and successful Release build summary are retained here. The
[before measurements](../release-launch-reliability-20261012/offline-3000/manifest.json)
remain retained unchanged.

Timeline lanes filter clip views using the horizontally scrolled canvas and
viewport in the same named coordinate space, accounting for track-label width.
Two hundred pixels of overscan retain near-edge clips. Before geometry is
available, the bounded initial range mounts only five clips of each thousand-clip
track. Full canvas widths and scroll extents remain based on project duration.
Boundary-touching, long spanning and minimum-width clips remain visible.

Selected clips and active move/trim/fade gestures are pinned even when outside the
viewport. Gesture-state reset handles cancellation as well as completion; removing
a clip clears its pin, geometry and previews. The visibility smoke covers initial
layout, scrolled/window coordinates, both touching edges, long/tiny clips, zoom,
overscan and pin/unpin policy. Actual native pointer dragging across a scrolling
viewport has not been visually qualified by this synthetic-button experiment.

Reproduce using the commands in [the launch method](../../release-launch-performance.md).
The workload uses deliberately nonexistent source URLs and contains no media
bookmarks, proxies or proxy jobs. The interaction is an opt-in native probe button,
not an ordinary edit command. Cold packaged launch, media initialization, physical
input/presentation latency and ordinary editing responsiveness remain open.
