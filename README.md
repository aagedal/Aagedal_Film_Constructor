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

The macOS app now has a resizable media bin, source monitor, inspector, and
multitrack timeline. Import AVFoundation-supported video/audio and still images,
preview sources, append linked video/audio, drag move/trim with snapping, split/delete clips, undo/redo,
and save/reopen `.afcproject` documents. Media access is retained with sandbox
bookmarks; missing originals can be relinked. DocumentGroup supplies native
new/open/save and autosave behavior. Finder file drops, persistent panel visibility,
sequence timecode and frame stepping, and an empty-track cleanup preference are
available. Timeline clips display asynchronous filmstrips and channel waveforms;
Settings includes persistent keyboard shortcut remapping and conflict checks.
Source playback supports J (silent reverse), K (pause), and L (forward), with
monitor buttons and text-entry protection. The app now includes a macOS icon.
Audio components support explicit source/output channel selection with track
adaptation and optional confirmation. Aligned linked audio components with the
same source, track family, and gain can be combined into one explicitly mapped
component. See [basic testing instructions](docs/basic-workspace.md).

This is the first usable assembly workspace. The monitor previews original
sources, not the edited sequence. Native timeline playback, release media-helper
packaging, and proxies remain unfinished. A development sequence render workflow
exports MOV/ProRes 422 HQ with PCM audio, progress, cancellation, and FFprobe
verification when explicitly prepared helpers are bundled. PNG/JPEG stills,
layered video, channel maps, gain, fades and crossfades are supported within the
qualified subset. The export dialog reports source geometry/color/VFR limitations.
See [helper preparation](docs/media-helper-packaging.md). FCPXML export references
originals and refuses unsupported edits; [its supported subset](docs/fcpxml-export.md)
passes Apple's DTD, with native editor import still unverified. Standalone audio fades
have timeline handles and inspector duration/curve controls; edits persist and
support undo/redo. Linked audio crossfades support existing overlaps and adjacent
cuts with available source handles, without changing clip cuts or linked picture.
The source monitor plays original audio without timeline fades or crossfades. Still images currently have a
five-second extent. Default append uses matching sequence layouts or mono
duplicated to stereo; other layouts open an explicit audio selection sheet.
Use “Append with audio selection…” in the bin to choose channels and outputs
before insertion, or omit audio from picture. Once an audio component exists, its
source channels and output routing can be changed in the inspector, including
combining compatible separate components into one.

`Packages/EditorCore` is the independent Swift 6 timeline model and editing
engine. The app targets macOS 14+; the inherited project format requires a
compatible Xcode (verified with Xcode 27).

Run `scripts/verify.sh` to test the core and build the app without signing.
Run `scripts/app-file-smoke.sh` to generate WAV/PNG fixtures and verify import,
editing, bookmarks, relink undo, project round trips, and malformed-file rejection.
The bookmark smoke checks need macOS services available outside restrictive tool
sandboxes. For the core alone, run `swift test --package-path Packages/EditorCore`.
See [the media audit](docs/media-engine-audit.md) for the development-only FFmpeg
proof and packaging gaps.

The core now includes a development FFmpeg render-plan compiler and a persisted
fixture integration proof. Run `scripts/render-plan-proof.py` with explicit
absolute FFmpeg and FFprobe paths and a new absolute output directory. It checks
decoded frame identities, cuts, channel routing, gain, timecode, and sample counts.
The app now uses this compiler for the development render workflow; this proof
does not qualify every source format or establish MPV parity.

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
The assembly workspace now imports real media; live sequence playback and shipping
media dependencies remain unfinished.

The native development runtime now has an asynchronous serial decoder worker,
bounded request admission, a shared byte-limited video/audio cache, cancellation,
and seek/edit epochs that reject stale results. EditorCore includes an exact
sample-driven transport for play/pause/seek and frame selection. Four media
fixtures pass asynchronous frame/sample parity and transport checks against the
actual AVAudioEngine offline sample clock. See
[the asynchronous proof evidence](docs/evidence/native-playback-20261011/README.md).
This remains a development engine; live display and hardware A/V sync are next.
