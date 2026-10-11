# Aagedal Film Constructor — implementation plan

Status: milestone 1 in progress. EditorCore now compiles a qualified prototype
subset of its render plan into FFmpeg, with decoded-frame/sample integration
evidence. Headless sequential MPV parity passes, but exact seeking and graph
rebuilding fail. The native FFmpeg-library fallback now passes decoded video/audio
seeks, edited-plan replacement, native image captures and AVAudioEngine offline
parity for qualified fixtures. Bounded asynchronous decoding, stale-result
rejection and exact sample-driven transport now pass the same fixtures and native
offline clock checks. Milestone 2 now has a basic assembly workspace with source
preview, media import, project documents, and linked editing. Live sequence
playback, helper packaging, and the remaining workspace features stay in progress.
This plan records the intended product and implementation order; unchecked
items remain planned capabilities.

## Product direction

A focused native Swift/SwiftUI video editor with a simple workspace inspired by
Final Cut Pro and quickly toggled panels inspired by DaVinci Resolve. FFmpeg is
required for media compatibility, proxy generation, and rendered sequence export.
MPV/libmpv is the preferred broad-format source preview candidate; prove its
timeline suitability before committing to a complete playback design.
The launch target is ready to edit in less than two seconds. Expensive media
inspection, waveform generation, and optional models must load asynchronously.

The core idea is a magnetic editing experience backed by real tracks. The editor
creates additional tracks as clips overlap. Version one prioritizes assembly,
multitrack audio/video playback, and dependable export. Track identity and routing
must leave room for a future mixer and effects without requiring plugin hosting
or an effects engine in the first release.

Exclude Media Converter's download, upload, recording, batch queue, and
transcription workflows from the initial app. Reuse media infrastructure where
it fits, while keeping the new editor's document and timeline model independent.

## Version-one scope

| Workspace region | Contents |
| --- | --- |
| Top left | Project browser/bin, media metadata, right-click proxy creation. |
| Top middle | Preview monitor, transport, source/sequence timecode, hires/proxy toggle. |
| Top right | Contextual settings/inspector for clips, source audio, sequence, and export. |
| Bottom half | Full-width multitrack timeline with video, waveforms, trim/fade handles. |

Use resizable panels. Future effects and title browsers belong in the upper
workspace and should toggle quickly; reserve their placement without building
empty panels in v1.

Required v1 capabilities:

- Assemble video, audio, and still images with overlapping video/audio tracks,
  trimming, splitting, moving, undo/redo, save/open, and relinking.
- Dynamic track creation, family naming, optional empty-track removal, and
  post-insertion mono/multiple-mono/stereo/surround source selection.
- FFmpeg-backed rendered export at the selected sequence resolution, exact frame
  rate, and start timecode, with explicit audio channel mapping.
- Stream-copy export without re-encoding when the timeline and source packets
  permit it, with explicit eligibility and exact-cut checks before export.
- Project-bin proxy generation: ProRes Proxy by default, optional H.264, and a
  global hires/proxy playback toggle. Final renders use originals by default.
- Default scale-to-fit, with scale-to-fill and no-scaling choices per clip.
- Audio fade handles and crossfades, including dragging a fade handle to a second
  clip to create a linked crossfade.
- A keyboard shortcut editor with remapping, conflict detection, and defaults.
- At least one useful sequence interchange export. Proposed first target:
  FCPXML; evaluate OpenTimelineIO export as the next target.

Defer audio/video effects, title tracks, general keyframing, VST hosting, built-in
EQ/compressor/limiter, and a full bus/fader mixer until after v1. Static gain and
fade envelopes are basic editing operations and do not require a general effects
or keyframing UI. Retain the original requirement that future dynamically created
tracks copy routing and effects once those features exist.

## Dynamic track requirements

- Clips must not overwrite or block each other when moved or extended into an
  occupied region. Create another track automatically when necessary.
- Copy the originating track's available routing and static audio settings to
  the new track. Later, copy its effects as independently instantiated processors.
- When `Music` gains a sibling, display `Music 1` and `Music 2`, continuing the
  numbering as more tracks are needed.
- Remove empty tracks by default, with a setting to disable automatic removal.
- Design for conventional track mixing and effects in later releases.
- Allow changing a timeline clip's selected source audio after insertion:
  one mono stream, several mono streams, stereo, or surround from the source.
- Adapt the destination audio track to the selected channel layout, with an
  optional confirmation prompt.

## Proposed editing rules

These rules make the requested behavior deterministic. They should be validated
in an early working prototype before expanding the UI.

### Placement and magnetic editing

1. Resolve snapping, the requested start time, and any explicit ripple edit.
2. Try the target track at that time. Adjacent clip boundaries are allowed;
   intervals overlap only when their interiors intersect.
3. If it is occupied, prefer a compatible free sibling in the same track family.
4. Otherwise insert a new sibling next to the target and copy the v1 track state,
   including routing and static gain. Later copy pan/sends and ordered effects
   with fresh instance IDs and parameters copied by value.
5. Place the edited clip on the available track without moving unrelated clips
   in time merely to resolve the collision.
6. Apply automatic names and remove eligible empty tracks after the edit commits.
   Preview track creation during a drag without accumulating permanent tracks.
7. Record placement, track creation, naming, and cleanup as one undoable action.

A proposed primary video sequence supports ripple insert/delete/reorder, while
connected video and audio clips follow their explicit attachment anchors.
Collision-driven track creation is separate from ripple timing. Define which
operations ripple, and how anchors behave when a parent clip is split or deleted,
as part of the first timeline prototype.

Overlapping video also needs a defined compositing order. Initially use explicit
track order, with the upper visible clip taking precedence; preserve audio/video
sync when a linked clip is moved to another track. Video transitions are a later
feature; audio fades and crossfades are included in v1.

### Track identity, names, and cleanup

- Store a stable track ID and track-family ID independently of display names.
  Keep `Music` as the family's base name; do not repeatedly parse number suffixes.
- Automatically named siblings display `Music 1`, `Music 2`, and so on in track
  order. Proposed behavior: collapse to `Music` when one sibling remains.
- Preserve manually assigned names. Renaming a family and renaming a single track
  should be separate actions; numbering must not overwrite a custom name.
- A family is a relationship between tracks, not a hidden shared mixer. New
  tracks start with copied settings, then remain independently editable.
- Persist a family template so that removing its last empty track does not lose
  the routing/effects needed when a clip is added to that family again.
- Default `automaticallyRemoveEmptyTracks` to true. With it disabled, retain
  empty tracks and their mixer settings. Cleanup runs on committed edits rather
  than each drag update. Proposed exemptions: master/bus tracks, explicitly
  retained tracks, and (in later releases) tracks with automation that would
  otherwise be lost. Do not remove a track still referenced by a crossfade.

### Source audio selection and layout adaptation

Source audio streams and mixer tracks are different entities. A timeline clip
stores its own source selection so two uses of the same media can differ.

The inspector should list stream index, label/language where available, channel
count, and channel layout. Support selecting individual mono streams, multiple
mono streams as separately controllable components, a stereo stream, or a
surround stream. Combining mono channels into stereo/surround requires an explicit
channel mapping; selecting several mono streams must not silently guess their
speaker order. Preserve source in/out points, timeline duration, and video sync.

Store speaker positions/channel maps, not just a channel count: six channels
without known speaker labels are not automatically a known 5.1 layout.

Proposed layout-change behavior:

- If the selected clip is the only clip on the track, reconfigure the track to
  the selected layout after validating its output route. Validate effect support
  as well when effects are introduced in a later release.
- If other clips use that track, place the changed component on a compatible
  sibling or create one. Do not silently reinterpret other clips' channels.
- If several mono components become one stereo/surround component, create or
  reuse the compatible destination and remove obsolete empty component tracks
  according to the cleanup setting.
- Add an `askBeforeAudioTrackLayoutChanges` preference. When enabled, show the
  source selection and resulting track change before committing. Cancel leaves
  both source selection and track configuration unchanged.
- An output route (or a future effect/bus) may reject the new layout. Keep the
  existing edit intact and offer an explicit compatible route or downmix. Never silently drop
  channels. Future effects must retain their configuration when unsupported.
- Source selection, layout adaptation, new tracks, and cleanup form one atomic
  undoable edit. Preview playback and export must use the same channel mapping.

## FFmpeg and playback compatibility

FFmpeg handles demux/decode-dependent jobs, proxies, and final encoding. Probe
streams using existing metadata services plus FFprobe where needed. Ship a known
bundle of codecs/helpers and report its actual capabilities; do not depend on a
user-installed FFmpeg or assume every decoder has a corresponding encoder.

Use MPV/libmpv for the source viewer and evaluate it for timeline monitoring.
It supports external streams and complex libavfilter graphs, including audio
mixing, but the app must still provide timeline offsets, source ranges, clocking,
seeking, track selection, and graph invalidation. This is a proposed integration,
not proof that an existing source-player wrapper is a ready-made editing engine.
See the [MPV complex-filter documentation](https://mpv.io/manual/stable/#options-lavfi-complex).

Before substantial UI work, prototype two overlapping videos with different
source in-points, multiple selected audio streams, seek/scrub, and a crossfade.
Compare a monitored frame/audio segment against an FFmpeg render. If MPV graph
rebuilding or seeking is unsuitable, keep MPV for source viewing and use a
FFmpeg-library bridge with native rendering/audio scheduling for the sequence.
Any helper bridge may use C/C++; the application and UI remain Swift/SwiftUI.

Playback and export builds can differ even when both use FFmpeg libraries.
Maintain a format fixture matrix for import, metadata, hires preview, proxy
generation, proxy preview, and export. Allow proxy-mediated editing for formats
that can be transcoded but cannot be monitored directly, and display that status.

## Sequence settings, timecode, and scaling

- Store sequence width/height, exact rational frame rate (including fractional
  rates), audio sample rate/layout, and start timecode with explicit DF/NDF mode.
  Offer first-clip matching when creating a sequence; do not change it silently
  when another clip is imported.
- Retain source start timecode independently from the sequence start. Source
  ranges and timeline positions use exact time/frame counts; timecode strings
  are a display/interchange representation, not the arithmetic model.
- Make mixed-frame-rate conforming explicit. Define which source frame is chosen
  for each output frame and preserve audio duration; handle variable-frame-rate
  media with timestamp-aware mappings or a normalized intermediate.
- Export with exact output dimensions/frame rate and sequence start timecode.
  Use a timecode-capable output such as MOV for the baseline acceptance case;
  explain unsupported container/codec combinations before rendering. Verify
  metadata and frame counts with FFprobe rather than only checking command text.
  FFmpeg documents MOV/MP4 timecode tracks in its
  [format options](https://ffmpeg.org/ffmpeg-formats.html).
- Store `fit` (default), `fill`, or `none` per clip. Apply to stills and video:
  fit preserves the full image and pads, fill preserves aspect ratio and crops,
  none uses the oriented native dimensions centered in the sequence canvas.
  Viewer zoom is separate from clip scaling.
- Account for rotation, pixel aspect ratio, and color metadata. Proxy dimensions
  must not change the source geometry used for scaling; validate the same result
  in preview and export.

## Stream-copy export

Offer a distinct **Copy original streams (no re-encoding)** export mode when
feasible. This preserves encoded media quality while remuxing packets; it does
not promise an identical container file. Assess video and audio independently,
so copying video while rendering edited audio is possible when timing/container
compatibility is validated. Clearly label which streams are copied or encoded.

Start with one source range, then qualify contiguous cuts-only sequences of
compatible sources. Eligibility requires probed codecs/codec parameters, raster,
pixel format/color, exact timing, audio layout/sample rate, container support,
and packet/random-access boundaries. A matching codec name alone is insufficient.
Do not conform copied video to a different sequence frame rate or raster.
Reject copying any stream needing compositing, generated gaps, scaling,
transitions, filters, speed changes, audio mixing, gain/fades, or sample-channel
remapping. Selecting whole original audio streams can remain copyable.

For interframe codecs, exact trim starts require independently decodable random
access points and valid dependencies at the outgoing boundary; an arbitrary
keyframe flag is not sufficient for every open-GOP source. Audio cuts must respect
packet framing, codec delay/padding, and container edit support. Intra-frame media
may allow more cut points, but still needs timing validation. FFmpeg documents
that input seeking can preserve preroll when copying rather than discard it.
See [streamcopy and seeking](https://ffmpeg.org/ffmpeg.html#Streamcopy).

Never silently shift cuts or change sequence duration to permit copying. Show
reasons when exact copying is unavailable, and offer rendered export or an
explicit, previewable adjustment to safe cut boundaries. Re-encoding boundary
GOPs while copying interiors is a later smart-render experiment, not a promise
of entirely unencoded export. Preserve source originals and validate timestamps,
A/V sync, decoded first/last frames, duration, and packet payload hashes (allowing
documented container-required bitstream transformations). Test ProRes/PCM,
closed/open-GOP H.264/HEVC, and compressed audio before declaring support.

The current render-plan compiler always encodes ProRes/PCM. Stream-copy needs
additional codec/packet metadata and its own compiler path; it must bypass the
filter graph rather than attach `-c copy` to filtered outputs.

## Proxies

- In the project bin, right-click one or several items to create proxies. Default
  to ProRes Proxy in MOV; offer H.264 as an alternative. Choose proxy resolution
  in the creation dialog, with a proposed half-resolution default.
- Reuse FFmpeg process/progress infrastructure. Its ProRes encoder supports the
  [Proxy profile](https://ffmpeg.org/ffmpeg-codecs.html#ProRes); do not copy Media
  Converter's different default proxy codec unchanged.
- Track proxy identity, preset, status, source fingerprint, and timeline mapping
  on the media asset. Preserve frame correspondence, duration, source timecode,
  orientation/aspect ratio, and all audio stream selections. Keep audio on the
  original source if a proxy container/codec cannot preserve its organization.
- A global hires/proxy toggle changes playback representation, never source
  identity, edits, source ranges, or sequence settings. Missing/stale proxies
  fall back to originals with visible status. Switching must preserve playhead.
- For VFR or unusual sources, validate the mapping explicitly; reject a proxy
  that cannot represent edits faithfully rather than guessing frame offsets.
- Generation is asynchronous, cancellable, and resumable per asset, with bounded
  concurrency. Keep existing proxies usable until replacements finish. Originals
  are retained; partial output is not registered as a valid proxy.
- Final export and interchange reference originals by default. Missing originals
  require relinking or an explicit proxy-resolution export choice.

## Audio fades and crossfades

- Show fade-in/out handles on audio clip components. Store duration and curve
  independently from future generic effect/keyframe data. Clamp fades to usable
  media and keep all selected channels synchronized.
- Drag a fade handle to another compatible audio component to create a paired
  crossfade. Use their overlap when present. At an adjacent cut, extend into
  available source handles without changing sequence duration; shorten or refuse
  the transition when there is insufficient source media.
- Crossfades may span dynamically created sibling tracks. Validate layout/channel
  compatibility, make duration/curve editable, and keep the relation coherent
  during move, trim, split, delete, cleanup, and undo.
- Proposed defaults: equal-power crossfade, linear standalone fades. Let users
  select another curve. Correlated audio may peak during a crossfade; do not add
  a hidden limiter or automatic loudness normalization.
- Preview and export evaluate the same envelopes at the audio sample clock.
  FFmpeg has [fade, crossfade, and mixing filters](https://ffmpeg.org/ffmpeg-filters.html),
  but compile them around absolute timeline placement; a sequential crossfade
  operation must not accidentally shorten an already overlapped sequence.

## Sequence interchange

Keep the native project document independent of interchange adapters so dynamic
track families, proxy links, and preferences remain recoverable on save/open.

Proposed v1 order: FCPXML sequence export first, then OpenTimelineIO export if it
fits the release. FCPXML is concrete XML interchange and has locally tested helper
code. FCP7 XMEML is a distinct target for Premiere-style workflows, not a synonym
for FCPXML. Import/round-trip editing is a later milestone.

Export source media references, source in/out, timeline offsets, gaps, multiple
audio/video tracks, source stream/channel selections where supported, sequence
dimensions/rate/start timecode, scaling, and audio fades. Validate with the
destination application's native import, and report any feature the adapter
cannot represent rather than silently flattening or omitting it.

OpenTimelineIO represents layered tracks, clips, gaps, transitions, and a global
start time in its [canonical structure](https://opentimelineio.readthedocs.io/en/latest/tutorials/architecture.html).
Evaluate its [official C++ core](https://github.com/AcademySoftwareFoundation/OpenTimelineIO)
through a small Swift bridge before choosing a writer. Its
[format specification](https://opentimelineio.readthedocs.io/en/latest/tutorials/otio-file-format-specification.html)
recommends using the library. Avoid shipping a Python runtime solely for adapters.
Custom metadata can retain app-specific routing/fades, but other apps may not
apply it; define a supported subset and validate with the official library.

EDL is a limited fallback. Media Player's existing Resolve EDL exports markers,
not an assembled sequence. Reuse timecode/escaping/validation helpers while
writing a new edit-event exporter if needed. The requested interchange candidates
are EDL, XML, and OpenTimelineIO. Define EDL's supported
cuts-only subset and source/record timecode mappings. Offer per-track EDLs or an
explicit flattened cut list when needed, explaining what happens to overlapping
layers and audio. Do not promise a lossless multitrack timeline through EDL.

## Architecture

Start with a macOS editor. The application now targets macOS 14 and later. The project file remains in
the Xcode 27 format inherited from the recovered starter; building the app
requires a compatible Xcode, while the standalone core uses Swift 6.

Keep a UI-independent editor core, preferably a local Swift package so timeline
logic can be tested without launching the app:

- `ProjectDocument`: versioned persistence, media references, sequences, and
  document-level undo/save behavior.
- `MediaAsset`: stable identity, security-scoped bookmark, metadata, and available
  video/audio streams, source timecode, geometry, and original/proxy representations.
  Missing media must remain relinkable.
- `TimelineClip`: source range, rational timeline time, linked components,
  attachment anchors, scaling mode, fades, and per-instance source audio selection.
- `TimelineTrack` / `TrackFamily`: stable IDs, display naming, layout, mixer
  configuration, and retained family templates. Effect hosting is deferred.
- `SequenceSettings`: exact raster/rate, start timecode, and audio output format.
- `AudioCrossfade`: paired components, duration/curve, and source handle constraints.
- `EditCommand` / `TimelineEditEngine`: validated placement, trim, split, ripple,
  collision resolution, and transactional undo/redo.
- `TimelineRenderPlan`: canonical source ranges, absolute positions, layer order,
  scaling, channel maps, and fade envelopes shared by preview and export.
- `PlaybackEngine`: decode/cache/schedule from that plan, resolving hires/proxies.
- `AudioGraph`: v1 channel maps, static gain, fades/mixing, and output layout;
  add processing, buses, and plugin hosting later.
- `ProxyService`: generation queue, validation, representation links, and relinking.
- `ExportService`: compile the render plan into FFmpeg processing and encoding.
- `InterchangeExporter`: compile the document to a validated target format.
- `EditorCommandRegistry`: stable action IDs, menu/timeline command dispatch,
  shortcut scopes, editable bindings, conflict detection, and reset-to-defaults.

Keyboard remapping must apply consistently to menus and the editor. Respect text
entry, application/system-reserved combinations, and focused-panel contexts.

Use integer/rational media time rather than accumulating floating-point seconds.
Separate UI drag previews from committed document edits. Media services should
operate asynchronously, with cancellation and bounded caches. Persist references
and configurations rather than player objects or effect runtime instances.

## Media Converter reuse audit

The following files exist in the local `Aagedal-Media-Converter` checkout. Paths
below are relative to its `Aagedal Media Converter/` source directory. Audit
dependencies and preserve licensing/attribution before extracting code.

| Area | Existing code | Reuse approach |
| --- | --- | --- |
| Sandboxed file access | `Utils/SecurityScopedBookmarkManager.swift` | Reuse bookmark resolution and balanced access leases behind a media-access service. |
| Helper processes | `Utils/SubprocessRunner.swift` | Reuse cancellation and process handling for probing/export; keep helper paths bundle-based. |
| Media metadata | `Logic/VideoMetadataService.swift` and SwiftMediaMetadata dependency | Adapt to editor assets instead of conversion queue items; enumerate source streams once. |
| Audio selection/export mapping | `Logic/AudioRoutingModels.swift`, `Logic/Conversion/AudioRoutingService.swift` | Reuse mapping and validation ideas; separate source components from timeline tracks and real-time mixing. |
| Filmstrips and waveforms | `Logic/Previews/PreviewAssetGenerator.swift`, `Logic/Previews/NativeWaveformRenderer.swift` | Extract reusable cache/rendering services with per-channel support where needed. |
| Preview playback | `Logic/TrimPlayer/PreviewPlayerController.swift`, `Logic/MPV/MPVPlayer.swift` | Reuse source playback/decoder abstractions after untangling UI/settings; neither is a complete multitrack compositor. |
| Timeline edits and undo | `UI/VideoQueueViews/StitchingEditorView.swift` (`StitchingTimeline`, `StitchingEditHistory`) | Port useful algorithms and regression cases; build a new multitrack model rather than importing this queue-based view. |
| Timecode | `Utils/TimecodeFormatter.swift`, `Logic/Conversion/StitchMarkerTimecodeRate.swift` | Reuse formatting/rate handling after checking rational-time and drop-frame behavior. |
| Export progress | `Logic/Conversion/FFMPEGProgressParser.swift` | Reuse progress parsing and selected process lifecycle code; create a dedicated timeline render plan instead of importing the converter's entire command builder. |

Do not import the entire converter app or its binaries as a first step. Keep
dependencies small and load optional decoding/export tools when needed.

Useful existing tests to adapt include `SecurityScopedBookmarkManagerTests.swift`,
`MetadataScopeLifecycleTests.swift`, `AudioRoutingPlanTests.swift`,
`StitchingTimelineTests.swift`, and `StitchMarkerExportTests.swift`. Existing audio
routing plans handle a single input and source playback picks one stream at a
time; simultaneous clips, buses, effects, and arbitrary mono-to-surround mapping
require editor-specific work.

## Media Player reuse audit

Paths below are relative to the local `Aagedal-Media-Player` checkout:

| Existing code | Reuse and limits |
| --- | --- |
| `Aagedal Media Player/UI/TimecodeFormatter.swift` | Exact frame-count/rational rate and DF/NDF formatting; extract with its boundary tests. |
| `Aagedal Media Player/Logic/CompareReviewReportExporter.swift` | Rational XML time, escaping, source timecode/raster handling, and export validation. Resolve EDL is review markers; FCPXML is one browser asset with markers; XMEML is a one-source review sequence. None is the required general multitrack exporter. |
| `Aagedal Media Player/Logic/ExportCommandBuilder.swift` | Inspect format/timecode command construction; adapt selected helpers to a canonical timeline render plan. |
| `Aagedal Media Player/Logic/AudioChannelRouting.swift` | Reuse known speaker roles and monitoring channel-map ideas; the current helper monitors a single audio stream rather than a timeline mix. |
| `Aagedal Media Player Tests/TimecodeFormatterTests.swift`, `CompareReviewReportExporterTests.swift` | Reuse DF boundaries, overflow, fractional rates, XML safety, and geometry regression cases. |
| `docs/evidence/` editor-import fixtures | Use existing native conform evidence when designing new sequence-export tests; do not assume marker round trips prove sequence fidelity. |

Inspect other open-source editors for scheduling, transition, proxy, and interchange
ideas where useful. Prefer small proven library integrations and algorithms over
porting another application's UI/framework. Keep license notices for reused code.

Do not inherit silent frame-rate fallback or unsupported DF-to-NDF coercion from
existing helper constructors. Validate sequence settings explicitly. Preserve
unwrapped positions/durations separately from timecode's 24-hour display wrap,
and use exact probe fractions as timing authority rather than rounded metadata
rates. Track stable container stream indices and per-stream timing offsets.

## Implementation milestones

### 0. Repository repair and baseline

- [x] Join the Xcode initial commit and GitHub history without rewriting either.
- [x] Keep one `origin` remote at the supplied GitHub URL; configure `main` upstream.
- [x] Stop tracking personal `xcuserdata`; preserve the original local settings.
- [x] Verify the original app builds for macOS.
- [x] Record the workflow and reuse audit in this plan.

### 1. Timeline core and media-engine proof — first implementation

- [x] Add rational time, validated sequence settings, tracks/families, stable
      source stream identities, clip ranges, scaling modes, and a render plan.
- [x] Implement move/trim/split/placement, sibling naming, cleanup, and undo/redo.
- [ ] Bundle/audit FFmpeg and prototype MPV-based source/timeline monitoring.
- [ ] Render a minimal sequence with two overlapping videos and several audio
      components at different source in-points. Verify seeking and preview/export
      agreement before selecting the final playback path.
- [x] Prototype the native FFmpeg-library fallback after MPV seek failure; verify
      exact frame/sample requests, forward/backward seeks, decoder rebuilding,
      edited-plan invalidation and native offline output against rendered fixtures.
- [x] Add bounded asynchronous decoder requests, shared decoded-payload caching,
      cancellation and stale seek/edit rejection; verify exact transport against
      the native offline sample clock and independent frame/sample renders.
- [x] Test adjacency, multiple overlaps, free siblings, custom names, failed edit
      rollback, exact fractional rates, DF boundaries, and preserved audio sync.

Implemented foundation: `Packages/EditorCore` contains exact checked rational
arithmetic, DF/NDF formatting, validated project decoding, explicit source channel
selection and stream offsets, ordered render components, and non-ripple edit
commands. Linked components move/trim/split/delete transactionally. Split refuses
a cut outside any linked component rather than breaking sync. Family templates
survive cleanup; retained tracks and custom names are respected. The app's small
synthetic example demonstrates an extension creating a sibling and undo/redo.

This is not the complete playback model: source geometry/color, proxy
mappings, live playback and ripple/attachment rules remain work for the
relevant milestones. The development FFmpeg compiler now
handles frame-aligned video layers and sample-aligned explicitly routed audio;
it is not yet a production export service. See
[the media-engine audit](docs/media-engine-audit.md) for artifact evidence and the
standalone FFmpeg smoke proof. Headless sequential MPV parity passes for the
qualified fixture, but exact seeking and graph rebuilding fail. The native fallback
passes four frame/sample parity fixtures, including H.264 B-frames, video gaps,
overlapping audio and replacement of a primed playback plan. It uses native
CGImage captures and AVAudioEngine offline scheduling. Real-time monitoring
remains unqualified; no media helpers have been bundled.

Completion example: extending a `Music` clip creates `Music 1` and `Music 2`
with copied routing/static settings; undo restores the original state. A fixture
sequence previews and renders at the same positions with exact output timing.

### 2. Native workspace, persistence, and shortcuts

- [x] Build the top-left bin, middle source monitor, top-right inspector, and
      full-width timeline with resizable panels.
- [x] Add persistent panel visibility controls in the toolbar and View menu.
- [ ] Add edited-sequence monitoring.
- [x] Add sandboxed AVFoundation import, versioned project save/open, native
      DocumentGroup autosave, validated relinking, and basic sequence setup.
- [x] Connect horizontal drag/move, inspector trim, split/delete, selection, and
      atomic linked-component undo/redo; video edits snap to sequence frames.
- [x] Add linked drag trim handles, adjacency snapping, frame stepping, and
      sequence/start timecode controls.
- [ ] Add live sequence transport.
- [x] Add asynchronous filmstrips/waveforms and fit/fill/no-scaling controls.
      Scaling is persisted; sequence preview/render geometry remains unqualified.
- [x] Expose the automatic empty-track cleanup preference.
- [x] Expose layout-confirmation preferences with the source-layout workflow.
- [x] Add a command registry and keyboard shortcut editor with conflict checks,
      focus-aware dispatch, persistence, and reset-to-defaults.

Completion example: edit overlapping clips, change scaling, customize a shortcut,
and save/reopen without losing placements, preferences, or source identity.

### 3. Audio components, fades, and crossfades

- [x] Support initial and post-insertion mono, multiple mono, stereo, and surround selection
      on a selected component, including explicit consolidation of aligned linked
      components with matching source, track family, and gain.
- [x] Implement explicit channel maps and compatible track layout adaptation.
- [x] Add standalone audio fade handles, inspector durations/curves, persistence,
      atomic undo/redo, trim clamping and envelope-preserving split rules.
- [x] Qualify standalone linear/equal-power fades, including overlapping edges,
      fractional durations, seeks and edited-plan replacement in development
      FFmpeg/native sample-parity fixtures.
- [x] Add linked crossfades, including drag-to-second-clip creation.
- [x] Handle insufficient source handles, adjacent cuts, overlapping siblings,
      layout compatibility, subsequent trims/moves, cancellation, and atomic undo.
- [ ] Validate output layout and monitor/render the same sample-timed mix.

Completion example: switch two mono components to the source's 5.1 stream, obtain
a compatible track, create a crossfade, and undo both operations without lost sync.

### 4. Project-bin proxy workflow

- [ ] Add batch right-click proxy creation with ProRes Proxy default and H.264 option.
- [ ] Implement progress/cancel, bounded jobs, atomic registration, and relinking.
- [ ] Add the hires/proxy toggle with missing/stale-proxy status and fallback.
- [ ] Test frame/timecode correspondence, geometry, multiple audio streams, VFR
      mapping, switching at a nonzero playhead, and save/reopen.
- [ ] Verify proxy playback does not change edits and final exports use originals.

### 5. Sequence export and interchange

- [ ] Implement FFmpeg sequence render with correct raster, rational frame rate,
      start timecode, compositing order, scaling, audio selections, and fades.
- [ ] Add output settings, timecode-capability validation, progress, and cancellation.
- [ ] Add stream-copy eligibility using codec/packet metadata; qualify exact
      single-source trims, compatible cuts-only concatenation, and video-copy /
      audio-render export, with clear reasons and no silent boundary shifts.
- [ ] Verify copied packet payloads, decoded boundary frames, timestamps, duration,
      timecode, and A/V sync across supported containers/codecs.
- [ ] Verify outputs using FFprobe, decoded frame checks, channel identification
      audio fixtures, and native-player/editor import at integer/fractional rates.
- [ ] Add FCPXML sequence export and validate real layered-video/audio imports.
- [ ] Evaluate OTIO export using its official core/validator; document its subset.
- [ ] Define and optionally implement cuts-only sequence EDL using Player helpers,
      with clear per-track/flattening limits and exact source/record timecode.

V1 requires rendered export plus one validated sequence interchange target; it
does not require implementing every proposed interchange adapter.

### 6. Version-one acceptance and performance

- [ ] Exercise mixed-format media, multiple overlapping video/audio tracks,
      source audio changes, fades, proxies, relinking, and customized shortcuts.
- [ ] Check preview/export parity, deterministic frame counts, start timecode,
      dropped/duplicated conform frames, geometry, channel maps, and audio sync.
- [ ] Measure launch-to-interaction against the two-second target in Release builds.
- [ ] Profile large projects; bound caches and keep import/generation off the UI thread.

### After version one

- Audio/video effects, title browsers and title tracks, and general keyframing.
- Built-in EQ, compressor, limiter, and a fuller mixer with buses and faders.
- VST audio plugin hosting, capability checks, saved state, and offline rendering.
  Evaluate a native SDK bridge; do not assume it is a pure Swift package or
  automatically interchangeable with Audio Units.
- When effects arrive, dynamic siblings copy settings/routing while instantiating
  independent processors. Extend undo/persistence and preview/export parity tests.
- Additional interchange adapters/import, transitions, and optional classification.

## Decisions to validate during prototyping

- Exact ripple and attachment behavior, particularly when parents are split/deleted.
- Whether surviving automatic names collapse to their base name after cleanup.
- How users retain empty tracks containing intentional routing/static state, and
  later mixer automation.
- Default state of the optional layout-change confirmation setting.
- Surround output/downmix policy when monitoring hardware has fewer channels.
- MPV timeline graph viability versus a dedicated FFmpeg-backed sequence engine.
  The unchanged canonical export graph passed sequential capture but failed
  exact later/backward seeks and rebuilding. FFmpeg-library exact frame/sample
  selection and native offline output now pass qualified fixtures. Continue with
  this native sequence-engine direction, qualify live display/audio clocking and
  packaging next, and retain MPV as a source-viewer candidate.
- Mixed-frame-rate/VFR conform policy and proxy resolution/storage defaults.
- Crossfade geometry at adjacent cuts and curve choices when audio is correlated.
- First interchange target's native round-trip fidelity and explicit EDL subset.
- Long-term VST version/SDK choice, plugin isolation, and offline-rendering parity.
- Manual family assignment first; optional automatic audio classification later.

## Baseline verification

The recovered starter builds with Xcode 27 using:

```sh
xcodebuild -project "Aagedal Film Constructor.xcodeproj" \
  -scheme "Aagedal Film Constructor" -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/aagedal-film-constructor-derived-data \
  CODE_SIGNING_ALLOWED=NO build
```

This checks the starter's compilation only. No editor functionality or
launch-performance claim has been validated yet.


### First implementation verification (2026-10-09)

- Standalone EditorCore suite: 16 tests passed (10 edit-engine XCTest cases and
  6 model Swift Testing cases).
- macOS Debug app build: passed with Xcode 27, signing disabled. This proves
  package integration and compilation, not GUI interaction or macOS 14 runtime
  compatibility; the build was run on the current development machine.
- Development FFmpeg proof: decoded 180 frames at 30000/1001 and 288,288 audio
  samples per channel, with layer colors, channel routing, fade amplitudes, and
  MOV timecode checked. See the audit for limitations and reproduction.

### Render-plan compiler verification (2026-10-09)

- Core suite: 25 tests pass; unsigned macOS Debug build passes with Xcode 27.
  Tests include fractional collision/linked-sync cases,
  rollback after sibling creation, custom names, and compiler rejection cases.
- New `scripts/render-plan-proof.py` compiles a persisted fixture project through
  EditorCore, executes the emitted argument array, and decodes its actual output.
  It passes 180 frames at 30000/1001, 288,288 stereo samples, MOV DF timecode,
  exact layer cut boundaries, distinct source frame identities, swapped mono
  stream routing, static gain, and exact silence boundaries.
- Preview/export parity is still unchecked: the proof has no MPV monitor.
  Helper packaging, source geometry/color, VFR, nonzero stream offsets, stills,
  fades, process cancellation/progress, and native interchange remain open.

### MPV canonical-graph experiment (2026-10-09)

- Added an experimental `MPVRenderCompiler` adapter that uses the exact FFmpeg
  export graph, explicit file/stream-to-MPV track bindings, and split/asplit for
  repeated source use. It does not assume container stream indices are MPV IDs.
- The persisted render fixture now emits `mpv-command.json`; the development
  runner records MPV capabilities and actual graph initialization/playback.
- The local MPV 0.41.0-dirty / FFmpeg n8.1.2 build cannot initialize this graph.
  Its build disables required filters including asetpts, adelay, anullsrc, pad,
  and setsar. This is a package capability failure, not a completed parity or
  seek test. Select/build a filter-enabled candidate before evaluating timeline
  seeking; keep the milestone unchecked. See the media-engine audit for evidence.

### Runtime MPV parity and seeking verification (2026-10-09)

- Added strict runtime `track-list` resolution by file, kind, and `ff-index`,
  requiring libavformat demuxing. Missing/ambiguous identities fail explicitly;
  repeated stream use resolves once and retains split/asplit behavior.
- Added a reproducible development headless MPV build using local source and
  installed full FFmpeg libraries, with per-file source hashes and build commands.
  It is dynamically linked to Homebrew and is not a shipping package.
- Replaced potentially colliding frame colors with binary frame/source barcodes.
  MPV sequential capture matches all 180 frames and 288,288 stereo samples;
  maximum frame mean RGB error is 1.8 and maximum PCM sample error is 1.
- Exact seek checks pass at frames 0, 2, and 3, but fail at 60, 119, 120, 179,
  backward 60/15, and rebuilding at 15. Reported time positions are accurate;
  displayed pixels differ by 58.7–154.2 (tolerance 12). Do not use this unchanged
  graph as the interactive timeline engine. Evaluate the native fallback next.
- 33 core tests and 5 IPC tests pass; unsigned macOS Debug app build passes.
  Audio seeks, native display/CoreAudio, crossfades, helper packaging, and the
  full workspace remain unqualified. Milestone 1 remains in progress.
- Reproduction and retained results: [media-engine audit](docs/media-engine-audit.md#runtime-track-resolution-sequential-parity-and-seek-failure-2026-10-09).

### Native sequence fallback verification (2026-10-09)

- Added exact `NativePlaybackPlan` frame and sample-block requests with 14 tests
  for layer/cut/gap boundaries, fractional counts, explicit stream/channel routes,
  overlapping audio, stateless seeks, invalid models and overflow.
- Added a separate development FFmpeg C bridge with exact timestamp qualification,
  backward seek/flush/forward decode, RGB output and matching-rate PCM extraction.
  The app does not link local development libraries.
- Four fixtures pass all 180 frames and 288,288 stereo samples each, plus ten
  video and eight audio seeks each. They cover original barcodes, gaps, overlapping
  audio, H.264 B-frames and replacement of a primed plan with changed edits.
  CGImage/PNG captures and AVAudioEngine offline output match independent exports.
  Maximum RGB error is 2.0 (tolerance <12); audio error is 0.75 s16 units (limit 1).
- A reproducible direct decoder matrix passes 65 ASan/UBSan checks, including
  four-channel PCM and explicit rejection of unsupported timing/geometry/audio.
- 47 core tests, 9 Python tests and the unsigned macOS Debug build pass.
- Continue the native sequence-engine direction. Full-stream initial qualification
  is development behavior; live output/clocking, asynchronous caching/cancellation,
  crossfades, format/rate/geometry coverage and macOS 14-compatible shipping
  dependencies remain open. Milestone 1 remains in progress.
- Reproduction and evidence: [native media-engine audit](docs/media-engine-audit.md#native-sequence-fallback-proof-2026-10-09).


### Asynchronous native playback verification (2026-10-11)

- Added exact sample-driven play/pause/seek transport with seven tests covering
  fractional anchors, frame boundaries, stale clock callbacks, monotonic counts,
  exact-end clamping, replacement and checked failure rollback.
- Extracted the development decoder/output into `NativePlaybackRuntime`. A
  serial worker keeps media I/O off the caller executor; its actor session bounds
  pending requests and shares a byte-limited LRU across video/audio. Seek/edit
  epochs invalidate queued work and prevent stale results from entering the cache
  or being accepted for presentation. Cleanup jobs are coalesced.
- Nine runtime tests cover cancellation during decode/initialization, saturated
  admission, queued read rejection, repeated replacements, close, rejected edits,
  invalid requests and mixed-cache eviction. A running FFmpeg call cannot yet be
  interrupted; cancellation skips pending calls and discards obsolete output.
- 54 EditorCore tests, nine runtime tests, nine Python tests and the unsigned
  macOS Debug app build pass. The app still uses its synthetic timeline.
- Four actual media variants pass asynchronous parity for every 180 frames and
  288,288 stereo samples, ten video and eight audio seeks each, plus replacement
  of primed decoder state. Every variant passes 282 actual AVAudioEngine offline
  clock observations checked against independent exact frame arithmetic.
- Retained payload cache is 90,112 bytes under a 131,072-byte test limit; pending
  requests finish at zero. Internal codec/index memory remains unprofiled.
- Live display/audio scheduling, latency/underrun recovery, helper packaging and
  broader format coverage remain open. Milestone 1 remains in progress. See
  [the evidence](docs/evidence/native-playback-20261011/README.md).

### Basic assembly workspace checkpoint (2026-10-11)

- Replaced synthetic UI with a resizable bin/source monitor/inspector/timeline.
  AVFoundation probes run asynchronously off the main actor; AVKit previews
  original video/audio and the monitor displays stills. Edited-sequence playback
  remains unavailable, and AVFoundation format coverage is the current limit.
- Added `.afcproject` versioned JSON documents, validated decoding, native
  document commands/autosave, security-scoped bookmarks and required entitlements.
  Document reload resets editor state; relinking checks stream identities/layouts
  and source bounds, with locations and grants restored together by undo/redo.
- Added atomic core asset registration/assembly, linked A/V placement, mono to
  stereo mapping, sibling collision placement, basic sequence/scaling controls,
  horizontal move, numeric trims, split/delete, and focus-scoped default commands.
- Added eight assembly/persistence regressions plus a generated WAV/PNG app smoke
  harness covering real importer/document/store paths, import/relink grant undo,
  save/reopen, bookmark resolution, failed relink, reload, and corrupt/schema/model
  rejection. Core tests and macOS Debug build pass; see `docs/basic-workspace.md`.
- Timeline playback, FFmpeg packaging, filmstrips/waveforms, fading/proxies/export,
  full source audio selection, panel visibility, and shortcut customization remain
  unchecked. Basic workflow testing is ready; full v1 acceptance is not complete.

### Workspace editing controls checkpoint (2026-10-11)

- Added Finder URL drops through the same asynchronous importer as the file
  panel, persistent panel visibility controls, and project-persisted automatic
  empty-track cleanup controls.
- Clip-edge gestures preview locally and commit one linked edit on release.
  Shared geometry clamps trim deltas to all linked source/timeline bounds and
  preserves at least one sequence frame for video. The magnet toggle snaps moves
  and trims to other clip edges and the playhead within eight screen pixels.
- Added strict non-drop/drop-frame timecode parsing, skipped-label rejection,
  exact containing-frame formatting with sequence start offset, start timecode
  editing, go-to-timecode, and previous/next frame navigation. These navigate edit positions;
  live edited-sequence playback remains unfinished.
- Added core timecode/gesture regressions and app/store smoke coverage for linked
  trims, boundaries, undo/redo, timecode persistence, and cleanup. Verification
  passed: 9 Python regressions, 42 Swift Testing cases plus 27 XCTest cases,
  unsigned macOS Debug build, and the expanded app-file smoke harness. Native UI
  automation reached the initial document dialog but disconnected before workspace
  interaction; manual gesture and panel-layout checks remain part of user testing.


### Timeline previews, shortcuts, and audio source selection checkpoint (2026-10-11)

- Added visible-region asynchronous video/still filmstrips and channel-mapped
  source waveforms. Two active decoder jobs, twelve pending jobs, twelve images
  per request, 512 waveform bins, and a 24 MB/32-entry LRU bound retained preview
  work. Trims/zoom, source channel maps, media revisions and file fingerprints
  invalidate stale results; offline/unsupported media retains a placeholder.
- Added a shared command registry and Settings shortcut editor with persistent
  remapping, clearing, defaults reset, conflict/reserved-key validation, and
  panel/text-entry dispatch guards. Document shortcuts remain native.
- Added atomic post-insertion source selection and explicit output routing for
  mono, multiple mono, stereo, surround and unknown speaker layouts. The inspector
  previews track adaptation and optionally confirms it before committing. Source
  timing and linked picture remain intact; stale drafts and invalid routes fail
  without changing the document. Undo/redo and persistence include all tracks/maps.
- Collision-driven moves/trims now reuse siblings only when routing and gain
  match the originating track, protecting differently routed mono components.
- Initial placement of non-mono/stereo-only sources and consolidation of existing
  separate components remain open. Waveforms describe source channels before
  routing/gain; source monitoring still plays original media. Live edited-sequence
  monitoring, helper packaging, fades/crossfades, proxies and export remain open.
- Verification passed: 76 EditorCore tests (34 XCTest and 42 Swift Testing),
  nine Python regressions, shortcut model smoke, expanded native app-file smoke,
  generated audio/still/video preview stress smoke, and the unsigned macOS Debug
  build. Preview checks cover duplicate cache misses, queue saturation, active
  cancellation, same-path replacement invalidation, source/channel windows and
  image bounds. Native workspace gestures, focus transitions, and sheet layout
  still need manual UI testing; no live sequence-playback claim is made.

### Audio component consolidation checkpoint (2026-10-11)

- The audio source inspector now lists compatible linked components for explicit
  replacement with one mapped mono/stereo/surround component. Only checked
  components are removed; linked picture and unchecked audio remain intact.
  Source channels and sequence outputs still require explicit selection.
- Consolidation requires matching asset, source range, timeline start, link group,
  track family and static gain. Differing timing or gain requires a separate edit;
  it is never silently resolved by choosing one component's settings. The selected
  clip identity and gain survive, occupied tracks keep their settings, and empty
  tracks follow the cleanup/retention preferences. Family templates survive.
- Preview and optional track-change confirmation include component removal.
  Cancellation and stale drafts leave the document intact. Consolidation, routing,
  track adaptation and cleanup commit as one undoable document edit.
- Added five core regressions covering mono-to-surround maps, explicit subsets,
  occupied tracks, cleanup/retention, persistence, linked moves, invalid component
  identities/maps, ambiguous timing/gain and redo preservation. The app smoke
  harness exercises preview, rejection, commit, save/reopen and undo/redo.
- Verification passed: 81 EditorCore tests (39 XCTest and 42 Swift Testing),
  nine Python regressions, shortcut smoke, expanded app-file smoke and the
  unsigned macOS Debug build.
- Initial placement of non-mono/stereo-only assets, live edited-sequence monitoring,
  helper packaging, fades/crossfades, proxies and export remain open. Inspector
  checkbox interactions and confirmation layout still need manual UI testing.

### Initial audio placement checkpoint (2026-10-11)

- Added explicit source/channel/output selection before insertion, including
  separate mono components, surround and unknown layouts, and picture-only
  placement. Unsupported default append opens the selection sheet.
- Preview and optional confirmation leave the document untouched; append, linked
  picture/audio, track creation and routing commit as one undoable edit. Stale
  drafts and invalid maps are rejected atomically. Existing track reconfiguration
  cannot change requested routing or gain during initial placement.
- Uses the component consolidation implementation already merged in PR #11;
  this checkpoint adds initial placement rather than another consolidation API.
- Added six core regressions and app-store preview/commit/history/persistence
  checks. Verification passed: 87 EditorCore tests (45 XCTest and 42 Swift
  Testing), nine Python regressions, shortcut smoke, expanded app-file smoke,
  and the unsigned macOS Debug build.
- Live sequence monitoring, helper packaging, fades/crossfades, proxies and export
  remain open. Native sheet interactions still need manual UI testing.

### Standalone audio fades checkpoint (2026-10-11)

- Added backward-compatible per-component fade-in/out durations and linear or
  equal-power curves. Each edge is independently bounded by clip duration;
  overlapping edges multiply. Timeline handles preview locally and commit one
  undoable edit; inspector controls use the sequence audio sample grid.
- Fades survive moves, explicit source selection, save/reopen and undo/redo.
  Consolidation requires matching envelopes. Trims clamp fades; splits between
  fades preserve the original envelope and clear inner edges. Splits inside an
  active fade are rejected atomically rather than changing its sound.
- The development FFmpeg compiler and native monitor evaluate the same envelope
  at clip-relative sample positions, independent of block boundaries and seek
  history. Source monitoring and source waveforms still describe original media.
- Linked crossfades, adjacent-cut source-handle extension, live sequence playback,
  bundled helpers, proxies and production export remain open. Native gesture
  interaction and inspector layout still require manual UI testing.
- Verification passed: 95 EditorCore tests (51 XCTest and 44 Swift Testing),
  nine Python regressions, shortcut smoke, expanded app-file smoke, unsigned macOS
  Debug build, baseline render proof and five native playback variants. Fade audio
  differs by at most 1.0 s16 unit from independent FFmpeg output; all seeks,
  replacement and offline sample-clock checks pass. See
  [retained fade evidence](docs/evidence/audio-fades-20261011/README.md).

### Linked audio crossfades checkpoint (2026-10-11)

- Added backward-compatible paired crossfade relations with equal-power defaults,
  editable duration/curve, inspector creation/removal and fade-handle drops onto
  the actual second audio component. Compatible targets highlight during dragging;
  linked clips show duration badges. Release commits one undoable transaction.
- Existing overlaps use their exact overlap duration. Adjacent cuts derive
  sample-aligned audio handles, centered where possible and redistributed to
  available source media. Insufficient handles, incompatible layouts/routes,
  conflicting standalone edge fades and overlapping chain envelopes are rejected.
  Original clip ranges, linked picture and sequence duration remain unchanged.
- Render plans combine both handles on middle clips and use the same paired
  envelopes for development FFmpeg/native playback. Removal restores the original
  audio cut. Compatible joint moves retain relations; invalid geometry or source
  remapping dissolves affected relations atomically while preserving unrelated
  pairs. Splits inside paired envelopes are rejected; splits outside dissolve
  the relation. Undo restores the complete edit.
- Added core/render tests and app smoke checks for persistence, sample alignment,
  chains, history, stale drafts and relink rejection when source handles would be
  lost. Native pointer gestures and inspector layout still need manual testing.
  Live sequence playback, shipping helpers, proxies and production export remain
  open; source monitoring continues to play original media.
- Verification passed: 110 EditorCore tests (66 XCTest and 44 Swift Testing),
  nine Python regressions, shortcut smoke, expanded app-file smoke, unsigned macOS
  Debug build and eight native playback variants. Linked overlap and adjacent-cut
  transitions pass independent sample-envelope checks, asynchronous/offline audio,
  seeks and primed-plan replacement. See
  [retained crossfade evidence](docs/evidence/crossfades-20261011/README.md).
