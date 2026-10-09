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
resolution, frame rate, and timecode. The app will use native Swift/SwiftUI with
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
