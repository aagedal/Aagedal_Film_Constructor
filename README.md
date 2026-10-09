## Aagedal Film Constructor

#### Why build another video editor?
Because I want a video editor that is fast to start —ready to edit in less than 2 seconds— and because I still don't feel any editor has managed to optimize how to deal with audio tracks.

#### Track Philosophy
Why have no one been able to combine the usefulness of audio tracks with the flexibility of a magnetic trackless timeline. I believe it is possible to solve with a dynamic timeline tracks.
Using a fast classifier model such as Jev (or just some basic logic) it should be possible to automatically create (and optionally remove) tracks — with the same track routing and effects. This should let you have the benefit of normal tracks, while having the editing speed of not having to manually add tracks while expanding clips.


NB!
This is work in process and a sparetime project. Coded with the help of AI.

The planned first version focuses on assembling overlapping video and audio
tracks, source audio selection, fades/crossfades, proxies, and export with correct
resolution, frame rate, and timecode. Stream-copy export without re-encoding is
planned for eligible timelines, with exact-cut and codec/container validation. The app will use native Swift/SwiftUI with
FFmpeg for media processing and MPV evaluated for broad-format preview. Effects,
titles, keyframing, and plugin hosting are planned for later versions.

See [PLAN.md](PLAN.md) for the workspace layout, editing workflow, proxy and
interchange plans, Media Converter/Player reuse audits, and implementation milestones.


### Current implementation

The macOS app includes a synthetic timeline prototype: extend the Music clip
to create a sibling track, then undo/redo the complete edit. It does not yet
import or play media. `Packages/EditorCore` is the independent Swift 6 timeline
model and editing engine, with regression tests. The app targets macOS 14+;
the inherited project format requires a compatible Xcode (verified with Xcode 27).

Run `scripts/verify.sh` to test the core and build the app without signing.
For the core alone, run `swift test --package-path Packages/EditorCore`.
See [the media audit](docs/media-engine-audit.md) for the development-only FFmpeg
proof, packaging gaps, and the next MPV parity experiment.

The core now includes a development FFmpeg render-plan compiler and a persisted
fixture integration proof. Run `scripts/render-plan-proof.py` with explicit
absolute FFmpeg and FFprobe paths and a new absolute output directory. It checks
decoded frame identities, cuts, channel routing, gain, timecode, and sample counts.
This does not yet enable media import/export in the app or establish MPV parity.

The fixture also emits an experimental MPV graph from the same export filters.
`scripts/mpv-plan-proof.py` resolves actual loaded tracks over local JSON IPC and
compares every captured frame and sample. A full-filter headless MPV now passes
sequential parity. `scripts/mpv-seek-proof.py` demonstrates incorrect frames after
later/backward seeks and graph rebuilding, despite correct reported time positions.
The unchanged export graph is unsuitable for interactive sequence monitoring.
See the audit for reproduction and retained evidence. Native playback and helper
packaging remain open; this does not enable media playback in the app.

The native fallback now has an exact `NativePlaybackPlan` scheduler and a separate
development FFmpeg-library bridge in `Packages/NativePlaybackProof`. Its runner
compares every frame/sample, forward/backward seeks, native PNG captures,
AVAudioEngine offline output, and replacement of an already-used edit plan against
independent FFmpeg renders. Barcode, video-gap, overlapping-audio and H.264 B-frame
fixtures pass. See [the native proof evidence](docs/evidence/native-playback-20261009/README.md)
and [reproduction instructions](docs/media-engine-audit.md#native-sequence-fallback-proof-2026-10-09).
The app still uses its synthetic timeline; live playback and shipping media
dependencies remain unfinished.
