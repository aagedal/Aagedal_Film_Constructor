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

The macOS app opens directly into an untitled workspace ready for Finder file
drops; save the project when you want to keep it. It has a resizable media bin, source monitor, inspector, and
multitrack timeline. The media browser supports saved nested sub-bins: create and
rename folders, move selected media or bins, and remove a bin while keeping its
contents. Organization supports undo/redo and does not interrupt sequence playback.
Track headers have a compact settings icon for custom names, independent family
naming, empty-track retention, and audio gain. Static gain is undoable and uses
the shared playback/render plan; collision-created siblings inherit it. Main
workspace actions use icons with tooltips and accessibility labels.
Imports use the bin selected when inspection starts. Import AVFoundation-supported video/audio and still images,
preview sources, mark source In/Out with compact icons or remappable I/O shortcuts, append the selected range as linked video/audio, drag move/trim with snapping, split/delete clips, undo/redo,
and save/reopen `.afcproject` documents. Timeline shortcuts include Shift+Z to fit/restore zoom and Q/W to ripple-trim a selected clip to the playhead; aligned linked components trim together and later clips shift across tracks. Overlapping unrelated content is refused by this first ripple implementation. Media access is retained with sandbox
bookmarks; missing originals can be relinked. DocumentGroup supplies native
new/open/save and autosave behavior. An approximately five-minute first-save
reminder and automatic timestamped
backups of saved projects are available. The latest 20 backups are recoverable
through **Show backups**; source media is referenced, not copied. See
[saving and recovery](docs/basic-workspace.md).
The empty timeline displays a ruler, playhead, and placeholder video/audio lanes
before any tracks exist. Finder drops highlight the media bin and timeline
independently: the bin imports, while the timeline imports and places clips.
Finder drops onto the timeline import and place files directly at the drop time;
multiple files are placed consecutively. Compatible target tracks and automatic
collision siblings are supported, with one undo step per imported file.
Finder file drops, persistent panel visibility, exact integer/decimal/fractional
sequence frame rates, audio output layout/sample-rate settings, sequence timecode
and frame stepping, and an empty-track cleanup preference are available.
The mono/stereo/5.1 output configuration is saved; current sequence playback and
rendered export require mono/stereo. Timeline clips display asynchronous filmstrips and channel waveforms;
Settings includes persistent keyboard shortcut remapping and conflict checks.
Source playback supports J (silent reverse), K (pause), and L (forward), with
monitor buttons and text-entry protection. The app now includes a macOS icon.
Still source previews decode asynchronously with orientation and a 2048-pixel
longest-edge limit. Timeline preview metadata and decoding share bounded admission;
queued requests cancel without polling, and hidden clips release their previews.
Audio components support explicit source/output channel selection with track
adaptation and optional confirmation. Aligned linked audio components with the
same source, track family, and gain can be combined into one explicitly mapped
component. See [basic testing instructions](docs/basic-workspace.md).

This is the first usable assembly workspace. The viewer has one Source/Sequence icon toggle and a remappable Tab shortcut.
Media-bin clicks select Source; timeline clicks and clip/ruler drags select Sequence. Normal Xcode builds use system AVFoundation timeline preview. A broader native
FFmpeg monitor is available through an explicit local Xcode Debug selection or
the isolated development workspace harness.
System picture scheduling reuses tracks across nonoverlapping cuts and avoids
whole-timeline scans at each cut, preserving separate still/movie color handling.
The optional native monitor now admits a qualified 16/24-bit mono/stereo ALAC
subset at matching 44.1/48 kHz alongside PCM. See
[native ALAC evidence](docs/evidence/native-alac-20261015/qualification.md).
System preview uses curve-based audio fade ramps and reports approximation
status, including measured errors for very short fades. See
[fade-ramp evidence](docs/evidence/system-fade-ramps-20261015/README.md).
See [sequence monitoring](docs/sequence-monitor.md) for building and exercising
the enabled app controls. Release runtime/helper packaging remains unfinished.
The bin supports batch ProRes Proxy/H.264 creation, cancellable verified jobs,
saved proxy references, and a Prefer HiRes/Prefer Proxy icon toggle. Source preview
uses available media with fallback; proxies use original audio when available,
or verified proxy picture with an explicit silent status when originals are unavailable. Newly generated proxies have recorded
SHA-256 hashes and can be relinked after relocation with one undoable reference/grant
change. Proxy jobs persist with the project and can be manually resumed after
interruption or reopening. See [proxy scope and testing](docs/proxies.md).
A development sequence render workflow
exports MOV/ProRes 422 HQ with PCM audio, progress, cancellation, and FFprobe
verification using the automatically bundled pinned helpers. PNG/JPEG stills,
layered video, channel maps, gain, fades and crossfades are supported within the
qualified subset. The export dialog reports source geometry/color/VFR limitations.
Xcode builds now automatically download and bundle the pinned signed Apple Silicon
FFmpeg/FFprobe 9.0.2 pair on the first build, then reuse a verified local cache.
No machine-local path configuration is required. See
[automatic helper packaging and offline setup](docs/media-helper-packaging.md). A prepared local build
can be selected persistently for Debug with
`python3 scripts/configure-local-media-helpers.py --prepared-dir /absolute/prepared-helpers`.
Run `scripts/bundled-proxy-smoke.sh /absolute/built.app` to test proxy generation
through the production bundle lookup. FCPXML export references
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

EditorCore also has a conservative [stream-copy assessment](docs/stream-copy.md)
with separate picture/audio reasons. It requires exact packet evidence that the
current importer does not produce; app stream-copy export remains unimplemented.
Separate development proofs now qualify exact ProRes/PCM ranges and cuts-only
joins, including fractional/drop-frame timecode, with packet and decoded parity.

`Packages/EditorCore` is the independent Swift 6 timeline model and editing
engine. The app targets macOS 27+; the inherited project format requires a
compatible Xcode (verified with Xcode 27).

Run `scripts/verify.sh` to test the core and build the app without signing.
Run `scripts/project-profile.sh --clips 10000 --tracks 8 --iterations 3` for
optimized synthetic large-project timings. Indexed validation/render planning
and crossfade geometry avoid repeated scans; the workspace caches derived
duration and media lookups across transport updates. See
[performance evidence](docs/evidence/project-performance-20261012/README.md) for
scope and memory tradeoffs.
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
The [integer/fractional export matrix](docs/fractional-render-export-proof.md)
also verifies every decoded frame, exact timestamps, routed samples and MOV
timecode packets at 24, 24000/1001, 30000/1001 DF and 60000/1001 DF.

The fixture also emits an experimental MPV graph from the same export filters.
`scripts/mpv-plan-proof.py` resolves actual loaded tracks over local JSON IPC and
compares every captured frame and sample. A full-filter headless MPV now passes
sequential parity. `scripts/mpv-seek-proof.py` demonstrates incorrect frames after
later/backward seeks and graph rebuilding, despite correct reported time positions.
The unchanged export graph is unsuitable for interactive sequence monitoring.
See the audit for reproduction and retained evidence. Native playback and helper
packaging remained open at that checkpoint. Ordinary app builds now use the
AVFoundation sequence preview described below.

The native fallback now has an exact `NativePlaybackPlan` scheduler and a separate
development FFmpeg-library bridge in `Packages/NativePlaybackProof`. Its runner
compares every frame/sample, forward/backward seeks, native PNG captures,
AVAudioEngine offline output, and replacement of an already-used edit plan against
independent FFmpeg renders. Barcode, video-gap, overlapping-audio and H.264 B-frame
fixtures pass. See [the native proof evidence](docs/evidence/native-playback-20261009/README.md)
and [reproduction instructions](docs/media-engine-audit.md#native-sequence-fallback-proof-2026-10-09).
The assembly workspace imports real media and supports qualified source proxies;
shipping media dependencies and full live acceptance remain unfinished.

The native development runtime now has an asynchronous serial decoder worker,
bounded request admission, a shared byte-limited video/audio cache, cancellation,
and seek/edit epochs that reject stale results. EditorCore includes an exact
sample-driven transport for play/pause/seek and frame selection. Four media
fixtures pass asynchronous frame/sample parity and transport checks against the
actual AVAudioEngine offline sample clock. See
[the asynchronous proof evidence](docs/evidence/native-playback-20261011/README.md).
This remains a development engine; live display and hardware A/V sync are next.


The app also exports a conservative cuts-only CMX3600 EDL for one selected track.
Source frame rate, start timecode and reel identity must be declared explicitly;
unsupported edits are refused. Other tracks are excluded rather than flattened.
See [EDL workflow and limits](docs/edl-export.md). Native receiver conform is
unqualified.

OpenTimelineIO export is available from the Export menu and can be assigned a
keyboard shortcut. It preserves layered cuts, gaps and original media references
within a conservative mono/stereo subset, refusing fades, channel remapping and
other unsupported edits before showing a save panel. See
[OTIO timing and qualification](docs/otio-export.md). Receiving-editor import and
spatial conform remain unqualified.

`Packages/NativePlaybackProof` now includes a standalone live monitor development
window with bounded audio scheduling, node sample-clock transport, play/pause,
seeks and stale-result rejection. Video now supports bounded fit/fill/none scaling,
with [decoded spatial parity evidence](docs/evidence/native-geometry-20261012/README.md).
Audio configuration changes pause and flush pending work; explicit Play restarts
the monitor. The runner retains JSON observations and offers a scripted
play/seek/pause/resume exercise. It is separate from the shipping app. Hardware
A/V sync, device latency and release dependency packaging remain unqualified;
see [the native package instructions](Packages/NativePlaybackProof/README.md).

The native monitor also supports a qualified single-frame PNG/JPEG subset with
transparent PNG composition and fit/fill/none scaling. Starvation preserves the
last accepted sample position, and explicit Play starts a fresh output-clock epoch.
Priming cancels across pause/seek/edit/close, and abandoned monitors release their
polling tasks. [Recovery evidence](docs/evidence/native-recovery-20261012/README.md)
includes deterministic injected-clock tests and a successful local scripted output
run; physical starvation recovery and acoustic/display synchronization remain open.

The HiRes/Proxy preference now also drives the opt-in native sequence monitor.
Verified proxy picture preserves original framing and clip coordinates; audio and
final renders retain originals. Switching pauses and rebuilds at the current
playhead, with visible fallback for unavailable or unqualified proxies. See
[sequence proxy evidence](docs/evidence/sequence-proxies-20261013/README.md).


Normal Xcode builds now include timeline preview through AVFoundation. Append
video/audio to the timeline, select **Sequence** in the viewer, then play, scrub
or step frames. Trims, upper video precedence, gaps, fit/fill/no scaling, verified
proxy picture with original audio, and static audio gain up to unity use the
shared timeline plan. Whole mono/stereo audio streams must match the sequence
layout and sample rate and use identity routing. Mismatched or unknown source
sample rates are refused with guidance to match sequence settings or normalize media. Fade and crossfade curves use approximate volume
ramps. Single-frame PNG/JPEG stills up to 4096 pixels per dimension support fit/fill/no scaling and transparency. Unsupported formats, channel maps and boosted audio require
the native FFmpeg runtime and report a visible preview error.

Run `scripts/system-sequence-smoke.sh /absolute/path/ffmpeg` to verify generated
ProRes/PCM decoded frames and live transport; the fixture generator requires
FFmpeg, while the system preview itself has no external playback dependency.
Native-enabled development builds continue to use the native backend. Generated ProRes/PCM, H.264/AAC and closed-GOP HEVC/AAC fixtures now pass decoded
seek checks at 24, 23.976, 29.97 and 59.94 fps. Open-GOP HEVC trim preview can return
black and remains unqualified. See [system preview evidence](docs/evidence/system-sequence-20261014/README.md).
Generated PCM/AAC mono/stereo decoded audio mixes now pass reference waveform
checks at matching 44.1/48 kHz within explicit amplitude bounds. Delayed clips
apply their initial gain/fade before media begins. See [audio mix evidence](docs/evidence/system-audio-20261014/README.md).
Generated AAC cuts around an interior packet boundary now pass at matching rates;
AAC priming/end padding and broader compressed codecs remain unqualified. Cross-rate
resampling failed decoded parity and is explicitly refused by system preview. See
[audio boundary and resampling evidence](docs/evidence/system-audio-resampling-20261014/README.md).
Broader real-world media, signed sandbox and measured A/V timing remain open.
The opt-in native controller now also passes from a self-contained ad-hoc
development bundle with relocated dependencies and developer loader paths cleared.
Its locally selected libraries fit the app’s macOS 27 baseline. Xcode Debug can
compile and embed this closure with explicit local notices/provenance; attributed
release dependencies and distribution qualification remain open. See
[native packaging evidence](docs/evidence/native-runtime-packaging-20261014/README.md).

Generated same-rate ALAC now passes source-head/tail/whole-source decoded mix
checks alongside PCM. MP3 fails trim/mix parity and is explicitly refused by
system sequence preview; normalize it to PCM or ALAC. AAC source-edge cases fail
existing fidelity bounds and remain unqualified, while the earlier interior and
packet-cut subset still passes. See [compressed-audio boundary evidence](docs/evidence/system-compressed-audio-20261014/README.md).
Native development packaging now declares the actual dependency minimum OS and
supports an explicit deployment-target compatibility ceiling. The current local
runtime fits the macOS 27 baseline; no release certification is claimed. See
[native Xcode setup](docs/sequence-monitor.md#native-playback-in-xcode-debug).
AAC playback now displays its audio-boundary approximation status without disabling
ordinary camera/phone media; see [AAC status evidence](docs/evidence/system-compressed-audio-20261014/AAC-preview-notice.md).

An isolated development [MPVKit source proof](docs/evidence/mpv-source-20261016/README.md)
now verifies grayscale decoded seeks, loaded stream identities and repeated
transport/teardown against the cached CoreAudio-fixed runtime. Its color matrix
fails the unchanged pixel bounds, with diagnostics locating chroma-boundary
conversion disagreements. A separate [private-library coexistence proof](docs/evidence/mpv-coexistence-20261016/README.md)
passes both load orders with concurrent native decoding. CoreAudio, native
display, Swift playback coordination and application integration remain open. Source playback in ordinary builds
continues to use AVFoundation.

A private [asynchronous source bridge](docs/evidence/mpv-async-source-20261016/README.md)
now passes a Swift main-actor lifecycle and decoded-seek proof with AddressSanitizer
on the new bridge/client. It qualifies bounded polling, request correlation,
track selection, EOF recovery and pending-work teardown. App integration and
native audio/video presentation remain open.

The private [Swift coexistence proof](docs/evidence/mpv-swift-coexistence-20261016/README.md)
now exercises asynchronous MPV source commands alongside the native sequence
session actor, including edited-plan epochs and decoded picture/audio parity.
The combined AddressSanitizer run passes; app source playback remains AVFoundation.

A deterministic [in-flight payload proof](docs/evidence/mpv-swift-inflight-20261016/README.md)
now verifies replacement, cancellation and close after real native decode but
before payload publication, while MPV transport remains responsive. Obsolete
queued work is skipped; recovery output and decoder teardown pass. This does not
qualify interruption inside libavcodec or hardware presentation.

The isolated [MPV decoded-audio proof](docs/evidence/mpv-audio-20261016/README.md)
now finds exact natural PCM/ALAC output for its generated subset, but only 30/96
broader source/range comparisons pass. AAC/MP3 and some lossless range boundaries
remain unqualified. This diagnostic does not change application source playback.

A follow-up [audio control matrix](docs/evidence/mpv-audio-controls-20261016/README.md)
separates timestamp clipping from demuxer behavior. Integer trimming after decoding
from zero passes all PCM/ALAC ranges; forcing the FFmpeg demuxer additionally
passes all tested MP3 ranges under that control. AAC remains unqualified, and
this offline control does not resolve interactive seeking or change app playback.

The [AAC seek isolation](docs/evidence/mpv-aac-seek-20261016/README.md) reproduces
MPV's audio divergence with a direct embedded-library seek-to-zero control.
Unseeked decoding matches bounded reference audio, while priming and tail
handling still prevent faithful AAC qualification. Decoder controls and complete
failing results are retained; production source playback remains unchanged.

A direct [AAC priming/frame-duration control](docs/evidence/mpv-aac-preroll-20261016/README.md)
now passes all 24 generated AAC reference comparisons with the embedded libraries:
seeking to the observed first packet restores priming, and explicit decoded-frame
duration accounts for the excess tail. MPV itself remains 0/24 for AAC; these
controls do not yet change source playback or qualify efficient random access.

The [timestamp seek-preroll control](docs/evidence/mpv-seek-preroll-20261016/README.md)
now tests MPV loading ranges with 0/100/500 ms demuxer preroll. Larger preroll
fixes two early AAC comparisons but leaves later content and exact-count failures;
all natural AAC tails remain excessive. This diagnostic preserves the prior
bounded decode-from-zero result and leaves application source playback unchanged.


The [absolute-PTS seek control](docs/evidence/mpv-pts-seek-20261016/README.md)
now separates an earlier MPV playback start from integer timestamp-based output
cuts. PCM and ALAC each pass all 24 comparisons, including nonzero tail seeks;
500 ms preroll passes 68/96 comparisons overall. Natural AAC EOF and broader compressed-audio seeking remain
unqualified; application source playback stays AVFoundation.

An [AAC encoder PNS control](docs/evidence/mpv-aac-pns-20261017/README.md)
now isolates content divergence after nonzero loading seeks: all 20 bounded AAC
ranges match reference bytes when the generated fixture disables perceptual noise
substitution. Existing PNS-enabled sources and natural AAC EOF remain unresolved;
this fixture diagnostic does not change application playback.
