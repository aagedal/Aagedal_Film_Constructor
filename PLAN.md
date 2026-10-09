# Aagedal Film Constructor — implementation plan

Status: planning; the app is currently the original SwiftUI starter project.
This plan records the intended product and a proposed implementation order. It
does not imply that the editing or audio features already exist.

## Product direction

A focused video editor with a simple workspace inspired by Final Cut Pro: media
browser, viewer, inspector, and timeline, with a mixer available when needed.
The launch target is ready to edit in less than two seconds. Expensive media
inspection, waveform generation, and optional models must load asynchronously.

The core idea is a magnetic editing experience backed by real tracks. Tracks
retain useful mixer controls, output routing, and effects, while the editor
creates additional tracks as clips overlap. Users should spend their time
editing rather than managing track availability.

Exclude Media Converter's download, upload, recording, batch queue, and
transcription workflows from the initial app. Reuse media infrastructure where
it fits, while keeping the new editor's document and timeline model independent.

## Confirmed workflow requirements

- Clips must not overwrite or block each other when moved or extended into an
  occupied region. Create another track automatically when necessary.
- Copy the originating track's output routing and effects to the new track.
- When `Music` gains a sibling, display `Music 1` and `Music 2`, continuing the
  numbering as more tracks are needed.
- Remove empty tracks by default, with a setting to disable automatic removal.
- Keep normal track mixing and track effects available.
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
4. Otherwise insert a new sibling next to the target and copy its mixer state:
   routing, ordered effect configurations, gain, pan, and sends. Use fresh track
   and effect instance IDs; effect parameters are copied by value.
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
sync when a linked clip is moved to another track. Transitions are a later feature.

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
  retained tracks, and tracks with automation that would otherwise be lost.

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
  the selected layout after validating its output route and effect support.
- If other clips use that track, place the changed component on a compatible
  sibling or create one. Do not silently reinterpret other clips' channels.
- If several mono components become one stereo/surround component, create or
  reuse the compatible destination and remove obsolete empty component tracks
  according to the cleanup setting.
- Add an `askBeforeAudioTrackLayoutChanges` preference. When enabled, show the
  source selection and resulting track change before committing. Cancel leaves
  both source selection and track configuration unchanged.
- An effect or output bus may reject the new layout. Keep the existing edit
  intact and offer an explicit compatible route or downmix. Never silently drop
  channels or effects; show unsupported effects and retain their configuration.
- Source selection, layout adaptation, new tracks, and cleanup form one atomic
  undoable edit. Preview playback and export must use the same channel mapping.

## Architecture

Start with a macOS editor. The recovered template currently targets several
Apple platforms and has a macOS 27 deployment target; choose the supported macOS
baseline and narrow platform settings in the implementation phase.

Keep a UI-independent editor core, preferably a local Swift package so timeline
logic can be tested without launching the app:

- `ProjectDocument`: versioned persistence, media references, sequences, and
  document-level undo/save behavior.
- `MediaAsset`: stable identity, security-scoped bookmark, metadata, and available
  video/audio streams. Missing media must remain relinkable.
- `TimelineClip`: source range, rational timeline time, linked components,
  attachment anchors, and per-instance source audio selection.
- `TimelineTrack` / `TrackFamily`: stable IDs, display naming, layout, mixer
  configuration, and retained family templates.
- `EditCommand` / `TimelineEditEngine`: validated placement, trim, split, ripple,
  collision resolution, and transactional undo/redo.
- `PlaybackEngine`: decode/cache/schedule media from a compiled timeline snapshot.
- `AudioGraph`: clip channel maps, track processing, buses, and master output.
- `ExportService`: compile the same source ranges and channel maps for rendering.

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

## Implementation milestones

### 0. Repository repair and baseline

- [x] Join the Xcode initial commit and GitHub history without rewriting either.
- [x] Keep one `origin` remote at the supplied GitHub URL; configure `main` upstream.
- [x] Stop tracking personal `xcuserdata`; preserve the original local settings.
- [x] Verify the original app builds for macOS.
- [x] Record the workflow and reuse audit in this plan.

### 1. Testable timeline core — first implementation

- [ ] Add the editor core, rational time types, tracks/families, and clip ranges.
- [ ] Implement placement, move, trim, split, automatic sibling naming, and cleanup.
- [ ] Add transactional undo/redo including copied routing/effects and preferences.
- [ ] Test adjacent boundaries, multiple overlaps, long clips spanning several
      clips, reused free siblings, duplicate custom names, and failed edit rollback.
- [ ] Verify undo restores exact track IDs, names, effect order, routing, and clips.

Completion example: extending a `Music` clip into another creates `Music 1` and
`Music 2` with copied mixer configurations; one undo restores the original state.

### 2. Minimal editor workspace and project files

- [ ] Build browser/viewer/inspector/timeline panels with sensible resize behavior.
- [ ] Add local media import, sandboxed access, save/open, autosave, and relinking.
- [ ] Connect drag/trim/split/delete, selection, snapping, and keyboard commands.
- [ ] Add filmstrips and waveforms asynchronously; virtualize long timelines.
- [ ] Expose automatic empty-track cleanup in Settings.

Completion example: import two files, edit them into overlapping tracks, save,
close, and reopen with placements and mixer settings intact.

### 3. Source audio components and layout changes

- [ ] Enumerate and label source audio streams/components in the inspector.
- [ ] Support mono, multiple mono components, stereo, and known surround layouts.
- [ ] Add explicit channel mapping and track layout adaptation with optional prompt.
- [ ] Validate occupied-track behavior, effect/output compatibility, and undo.
- [ ] Test sources containing both mono streams and stereo/surround alternatives,
      unknown layouts, cancellation, and repeated changes after save/reopen.

Completion example: change an inserted clip from two mono components to its 5.1
stream, obtain a compatible track, and undo without losing sync or mixer settings.

### 4. Timeline playback and mixer

- [ ] Implement synchronized video composition and multitrack audio scheduling.
- [ ] Add gain, pan, mute, solo, meters, buses, and output channel configuration.
- [ ] Add ordered track effects with per-layout capability checks and saved state.
- [ ] Make preview use the same channel map and routing semantics as export.
- [ ] Validate seek/scrub, reverse/JKL controls, boundaries, long media, and sync.

### 5. Export and performance validation

- [ ] Add focused sequence export with video/audio settings and progress/cancel.
- [ ] Reuse converter process/export infrastructure behind the editor snapshot.
- [ ] Compare preview/export for trims, overlaps, effects, and speaker mapping.
- [ ] Measure launch-to-interaction against the two-second target in Release builds.
- [ ] Profile large projects; keep caches bounded and imports off the main thread.

## Decisions to validate during prototyping

- Exact ripple and attachment behavior, particularly when parents are split/deleted.
- Whether surviving automatic names collapse to their base name after cleanup.
- How users retain empty tracks containing intentional mixer state or automation.
- Default state of the optional layout-change confirmation setting.
- Surround output/downmix policy and effect support when a bus has fewer channels.
- Initial effect formats and real-time/export parity. Start with a small built-in
  set; broader Audio Unit support needs its own hosting and offline-rendering work.
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
