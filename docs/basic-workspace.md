# Test the basic workspace

Open `Aagedal Film Constructor.xcodeproj` in Xcode 27 or compatible, choose the
**Aagedal Film Constructor** scheme and **My Mac**, then Run. The app requires
macOS 27+. Launch opens an empty untitled workspace. Drop files from Finder
onto the media bin to import or the timeline to import and place clips; no project creation dialog is required. File → New creates
another workspace, while File → Open opens an existing project.

Drop Finder files onto the empty timeline to start at zero. On an existing
timeline, drop onto a lane at the desired time; the starting position snaps to
the nearest sequence frame. Multiple files are placed consecutively in drop
order. A compatible target lane is used, and overlaps create sibling tracks.
Dropping onto the timeline toolbar places at the playhead. Drops onto the media bin import without placing clips. Each destination has
its own tinted outline and short drop hint; moving between them highlights only
the current destination. The monitor and inspector are not drop destinations.
An empty timeline still shows a time ruler, playhead, and placeholder video/audio
lanes. These guides do not create tracks or change the project.

Each successful timeline import and placement is one undoable action, including
its media bookmark. Unsupported files are reported and skipped; an audio layout
requiring explicit mapping is refused without adding it. Import that file into
the bin and choose **Append with audio selection…** to configure it.

1. Import a short MOV/MP4, WAV/M4A, or PNG/JPEG using **Import**, ⌘I, or dropping files from Finder onto the media bin.
   Import inspects media asynchronously. Select each file in the bin to preview
   the original source; video/audio use the monitor's playback controls. **J**
   plays backwards with silent frame seeking, **K** pauses, and **L** plays
   forwards at normal speed. These control the selected original source from
   anywhere in the workspace. From the start, J begins at the source end; from
   the end, L restarts at the beginning. Typing into text fields leaves playback
   unchanged. Playback shortcuts can be remapped in Settings.
   The viewer follows media-bin clicks/selections (Source) and timeline
   clicks, scrubs and clip drags (Sequence). Its header has one icon to switch
   manually; **Tab** switches from any workspace panel and is remappable in
   Settings. Text editing retains normal Tab behavior. Changing viewer preserves
   each viewer's playhead and pauses the viewer being hidden. Sequence monitoring
   requires the opt-in native development runtime described in
   [sequence monitoring](sequence-monitor.md).
2. Click **Append** or ⌘E. Video with audio creates linked components; moving,
   trimming, splitting, and deleting either component edits both. Append more
   sources to build a sequence.
3. Select a clip and drag horizontally, or enter **Timeline start** and click
   **Move clip**. Move into another clip to exercise automatic sibling tracks.
   Change **Source in** and **Duration**, then **Apply trim**. Source bounds are
   validated. You can also drag either clip edge to trim. Start trims keep the
   out point fixed and change source in and timeline start together; end trims
   keep source in fixed. Linked components constrain available source handles.
   Video timing changes round to the nearest sequence frame. The magnet button
   enables snapping within eight screen pixels of clip edges and the playhead.
4. Click/drag the timeline ruler to place the playhead inside a selected clip,
   then **Split at playhead** or ⌘B. Try delete, ⌘Z, and ⇧⌘Z. The orange playhead
   only indicates edit position; it does not play the sequence. Use the frame
   step buttons or ⌥⌘← / ⌥⌘→ to navigate sequence frames. The readout shows
   sequence timecode, including the start offset set in the inspector. Click
   the timecode readout to enter a position and jump to it.
5. Change sequence raster/frame rate or clip scaling in the inspector. Frame
   rate accepts an integer, exact fraction (for example `24000/1001`) or literal
   decimal. **Frame rate presets** includes the standard fractional rates:
   select `30000/1001` or `60000/1001` for drop frame. Decimal `29.97` stays
   exactly `2997/100` and does not support drop frame. Reopening the inspector
   shows the stored fraction without rounding it.
6. Set **Audio sample rate (Hz)**, **Output layout** (mono/stereo/5.1), and
   **Start timecode**, then **Apply settings**. Use `HH:MM:SS:FF`, or
   `HH:MM:SS;FF` for drop frame at `30000/1001` or `60000/1001`. Picture,
   audio and timecode settings form one undoable change. Invalid labels or
   incompatible existing track/family output maps reject the complete change.
   Identity-routed tracks require the same sequence layout; explicit routes must
   still address existing output channels. Configure routing in **Audio source
   channels…** before changing the output layout, or start with an empty project.
   Audio sample-rate changes preserve clip times and use the sequence rate in
   render/monitor plans. Export renders mono, stereo and 5.1 outputs. In a 5.1 sequence,
   appended stereo media is routed to front left/right and mono to centre; the
   preview plays a stereo downmix. Source 5.1 components can still map explicitly to
   mono/stereo sequence outputs. Start timecode changes labels without shifting clips.
   Toggle **Remove empty tracks after edits** to preserve unused tracks. Use
   **Panels** in the toolbar or the **View** menu to hide/show the bin, inspector,
   and timeline; these panel choices persist across launches.
7. Save with ⌘S as an `.afcproject`, close, and reopen using ⌘O. Check that files,
   clip timings, links, tracks, and sequence settings survive. Native documents
   autosave after saving and expose the usual Save/Duplicate/Revert commands.
   An edited untitled workspace suggests saving after about five minutes, with
   **Save project…** and **Remind me later** controls. Unchanged empty workspaces
   do not prompt. Saved projects also retain automatic timestamped snapshots:
   after 15 seconds without edits, at least 60 seconds between backups, and
   within 120 seconds during continuous editing. The latest 20 snapshots per
   project path are retained under the app's Application Support directory.
   **Show backups** opens that folder; open a snapshot as a normal `.afcproject`
   and use Save As/Duplicate to recover without replacing your current project.
   Backups preserve project data/bookmarks, not copies of source media. Backup
   failures appear in the workspace and retry on the next allowed interval.
8. To exercise relinking, move a test original in Finder, reopen its project,
   select it in the bin, and click **Relink media…**. Select matching media with
   the same stream identities/channel layouts and sufficient source duration.
   Undo/redo relinking and save/reopen to check the restored file reference.

9. Select an audio timeline component and choose **Audio source channels…** in
   the inspector. Choose mono/stereo/5.1 or a source layout, then explicitly pick
   a source stream/channel and sequence output for every row. Stream labels and
   known speaker positions are shown; unknown speakers retain numbered labels.
   **Create separate mono components** makes linked components on compatible
   tracks. Applying changes preserves source in, duration, and linked picture.
   The **Confirm audio track layout changes** preference controls the second
   confirmation for track reconfiguration/creation/cleanup. Cancel leaves the
   project untouched. Try undo/redo and save/reopen to verify maps and routing.
   Routing several channels to one output explicitly sums them; there is no
   automatic downmix gain or level adjustment. To combine separate components,
   reopen **Audio source channels…** on one and check the additional components
   under **Combine linked audio components**. Choose the resulting layout and
   source/output map, then Apply. Only checked components are replaced; unchecked
   audio and linked picture remain intact. Eligible components share the same
   asset, source range, timeline start, linked group, family, gain and fades. Different
   timing, gain or fades must be resolved separately. Try combining two mono components
   into stereo or selecting a source 5.1 stream with explicit output routing.
   Cancel the confirmation, then apply and undo/redo; save/reopen the result.
   Verify obsolete empty tracks follow the cleanup preference and retained tracks
   survive. Separate mono creation is disabled while combining components.
10. Open **Settings → Keyboard Shortcuts** (⌘,). Select a command, change its key
    and modifiers, and **Apply**. Conflicts and reserved application shortcuts
    block Apply. Clear removes a binding after Apply; reset restores defaults.
    Shortcuts persist across launches. Source/timeline commands respect panel
    focus and leave text entry to native controls.
11. Scroll and zoom the timeline to see source filmstrips and per-selected-channel
    waveforms. Trim to check that imagery follows source in. Previews are bounded,
    generated asynchronously for visible clips, and show placeholders for offline
    or unsupported media. Waveforms show source amplitude before routing/gain.

12. In the bin choose **Append with audio selection…** to choose streams, channels,
    and outputs before insertion. Default Append opens this sheet when the source
    layout needs explicit routing. Choose separate mono components or one mapped
    layout, or disable audio to append picture only. Cancel leaves the project
    unchanged. Append creates picture, audio, and tracks in one undoable edit.
    Try a 5.1 source in a stereo sequence and explicitly map each desired channel
    to an output.

13. Select an audio component and set its fade-in/out durations and curves in the
    inspector, then apply. Drag the small upper-edge fade handles to change the
    durations; each release commits one undoable edit. Linear is the default;
    equal-power uses a sine amplitude ramp. Fades can overlap and multiply.
    Shortening a clip clamps each fade to the remaining duration. Splitting
    inside an active fade is refused so an edit cannot silently change its
    envelope; splitting between fades preserves the outer fades and clears the
    new inner edges. Move clips, change source channels, undo/redo, and save/reopen
    to check preservation. The source monitor still plays original audio;
    timeline fades are qualified through the separate development render/native
    proof.

14. Select the outgoing audio component and choose **Incoming audio** under
    **Linked crossfade**. Choose a duration and curve, then **Apply crossfade**.
    You can also drag a yellow fade handle onto the second audio clip; a valid
    target highlights yellow and linked clips show a duration badge. Release
    commits one edit. Equal-power is the default. An existing overlap uses its exact duration;
    adjacent cuts use available source audio beyond the cut. Insufficient handles,
    incompatible channel layouts or output routes, and conflicting standalone
    fades are rejected without changing the project. Original clip cuts, linked
    picture and sequence duration remain unchanged. Remove the crossfade to
    restore the original audio cut; try undo/redo and save/reopen. The source
    monitor still plays original audio. Editing a participating endpoint can
    remove its crossfade; undo restores both together. A split inside the paired
    envelope is rejected; a split outside it removes the relation. Compatible
    joint moves preserve the relation. Native gesture interaction and inspector
    layout still need manual testing.

15. Choose **Export → Render sequence…** in the toolbar or **File → Render
    Sequence…** (default shortcut Shift-Command-E). The dialog captures the
    current sequence and displays its resolution, exact frame rate, timecode,
    audio layout, and source qualification limits. Set resolution, frame rate
    and start timecode in the sequence inspector before opening export; audio
    follows the saved sequence settings. Enter a new MOV filename and
    choose an export folder. Folder access permits private staging and atomic
    publication. Progress includes verification; cancellation or failure removes
    partial files, and existing destinations are protected. The result is
    ProRes 422 HQ/24-bit PCM from originals, including timeline gain/fades and
    crossfades. Helpers must be explicitly prepared and bundled using
    [the opt-in build instructions](media-helper-packaging.md); ordinary builds
    show an unavailable-helper message. Before rendering, each selected video
    stream is fully decoded to check zero-origin CFR timestamps and stable raster,
    using exact rational timing with container-tick quantization. Exposed rotation,
    non-square pixels and HDR metadata are refused. Qualification stops after
    30 seconds, 2 MB of probe output, or 100,000 frames; larger or slower sources
    require another workflow. Different source rasters and CFR rates, and audio
    resampling, remain supported. Signed sandbox export, dynamic color management
    and general audio timestamp continuity remain manual qualification steps.

16. Choose **Export → Export FCPXML…** for a sequence in
    [the supported interchange subset](fcpxml-export.md). The save panel explains
    its qualification limits. Unsupported fades, remaps and other edits are
    refused before saving, with specific reasons. Keep originals available to
    the receiving editor. Native Final Cut Pro/Resolve import remains unverified.

17. Select several video sources in the bin, right-click a selected item and
    choose **Create proxies…**. Choose ProRes Proxy (default) or H.264 and a
    resolution, then an output folder. Cancel a batch midway, check completed
    jobs remain usable, and retry remaining assets. Toggle **Prefer HiRes / Prefer Proxy** using the representation icon at
    a nonzero source position, including during playback. Check visible fallback
    status after moving a proxy or changing its original; undo proxy registration
    and save/reopen to check separate media grants. Outputs and exports retain
    originals. See [qualification limits and tests](proxies.md).

The viewer header icon or **Tab** switches Source/Sequence; timeline interactions
select Sequence automatically and expose edited-sequence controls.
An [opt-in development build](sequence-monitor.md) enables the native runtime;
default builds explain that it is unavailable. Sequence mode uses originals,
pauses on edits, follows timeline scrubs and frame steps, and routes K/L to
pause/forward play. Reverse sequence playback is unavailable. Device/display
synchronization and runtime distribution still need qualification.

Current limits: AVFoundation-supported source formats. Proxies, sequence
monitoring and rendering are qualified development subsets; shipping
helper provenance, signed sandbox execution, source geometry/color/VFR and
native interchange import remain open. Stills have a
five-second source extent. Default audio assembly accepts matching layouts or mono
(duplicated into stereo); other layouts use the explicit initial selection sheet.
Post-insertion explicit maps support other streams/layouts on existing components.

## Verification

Still source previews decode asynchronously on a serial ImageIO worker, retain
at most a 2048-pixel longest edge, and apply embedded orientation. Import validates
stills with a 64-pixel thumbnail rather than a full raster. Source switching,
deselection, document replacement and closing reject obsolete results. Originals
and timeline/export coordinates remain intact. These are retained-pixel limits;
ImageIO codec scratch allocations and filesystem latency are not bounded here.

```sh
scripts/verify.sh
scripts/app-file-smoke.sh
scripts/shortcut-smoke.sh
scripts/timeline-preview-smoke.sh
scripts/export-service-smoke.sh
scripts/proxy-service-smoke.sh
scripts/proxy-workspace-smoke.sh
```

The first runs Python regressions, shortcut model smoke, EditorCore tests, and an
unsigned app build.
The second compiles the actual importer, project document, and editor store into
a temporary runner and generates its own WAV/PNG fixtures. It checks document
validation, bookmarks, edit history, relink history, and reopen behavior. macOS
bookmark services must be accessible; restrictive command sandboxes can block
those services. The unsigned build verifies compilation; use Xcode's normal
signed Run for testing sandbox grants across launches.

The shortcut smoke checks defaults, conflicts, normalization and reserved bindings.
The preview smoke generates WAV/PNG fixtures and uses development FFmpeg, when
available, for a two-color video; it verifies channel maps, source ranges, cache
limits and cancellation. These checks do not qualify edited-sequence playback.

## Organizing media with sub-bins

Use the folder-plus menu in the Media header to create a sub-bin inside the
current bin. Open child folders with their folder rows; use the header menu to
jump to any bin or the root Media browser. The folder menu also offers rename,
move to another parent, go to parent, and **Remove bin, keep contents**. Removing
promotes its media and child folders to its parent; it never deletes source files
or timeline clips. Moves that would create a parent cycle are refused.

Select one or several media rows and right-click **Move to bin** to organize them
in one undo step. Imports and Finder drops capture the current bin before
asynchronous inspection; switching bins while importing does not redirect the
files. If that destination is removed before inspection completes, media goes
to the root. Selecting an imported asset reveals its containing bin.

Bins and media assignments persist in `.afcproject` and automatic backups.
Existing projects without these fields open with their media at the root.
Organization preserves media identities, proxy references, security bookmarks,
timeline timing and exports. Bin-only edits do not restart sequence playback.
The folder tree is organizational metadata; it does not move files on disk.

Run `scripts/app-file-smoke.sh` for nested navigation, batch undo/redo, captured
imports, removed-destination fallback, bookmarks and save/reopen checks. macOS
bookmark services must be accessible. Core `MediaBinTests` cover legacy decoding,
malformed references/cycles, rollback and unchanged render plans.

## Matching the first picture source

Import and select a video before adding timeline clips. The Sequence inspector
offers **Match Video** with its dimensions and exact frame rate for each qualified
video stream. Choose it to set picture settings in one undoable edit, then append
the source. Audio sample rate/layout and sequence start timecode remain as set;
an incompatible drop-frame timecode refuses the whole match. Imports never change
sequence settings automatically, and matching is unavailable after clips exist.

The importer retains optional qualified format metadata with the original stream.
It scans compressed sample presentation timestamps/durations, sorting B-frames
into presentation order, and requires a single exact constant cadence and stable
format. It accepts only identity orientation and square-pixel full-raster picture.
The scan runs off the main actor with a 100,000-sample/five-second budget; exhausting
that budget leaves matching unavailable while retaining ordinary import. A blocking
filesystem/AVFoundation read can exceed the time budget. This is sample-metadata
qualification, not a decoded-pixel, color-management or broad-format guarantee.
VFR, rotated/anamorphic picture and legacy projects without qualified metadata
use manual settings. Relinking re-inspects the replacement source.

`scripts/source-format-smoke.sh` uses local development FFmpeg fixtures to check
exact fractional CFR/B-frame timing and VFR/rotation/anamorphic refusal. Core tests
cover explicit stream selection, persistence, legacy decoding and atomic refusal;
`scripts/app-file-smoke.sh` checks the actual store's matching undo/redo history.

## Track controls

Click the sliders icon in a timeline track header. Enter a custom track name and
apply with the checkmark; blank restores family numbering. Apply a family name
separately to update automatically named siblings while preserving custom names.
Enable **Keep track when empty** to retain a lane and its settings after deleting
its last clip. Disabling it on an empty lane removes that lane when automatic
cleanup is enabled. These changes support undo/redo and save/reopen.

Audio tracks accept gain from −96 to +24 dB. Apply with the checkmark or Return.
The speaker icon sets zero amplitude (silence); clicking it again restores 0 dB.
It does not remember a previous gain. Gain applies to every clip on that track,
including its fades, in sequence playback and rendered export. Source preview
plays source audio. Existing siblings keep independent settings; a newly created
collision sibling copies the originating track's gain and routing. Family
creation templates remain independent of individual track gain edits.

Naming and retention flag changes preserve active sequence playback. Removing an
empty lane can rebuild the sequence. Gain changes pause
and rebuild the sequence at its current position; press Play to resume. Native
sequence playback still requires the development runtime. Toolbars and the bin
footer use icon actions: hover for their names, or use the existing keyboard
shortcuts. Menus and confirmation dialogs retain descriptive text.

### Select a source range before appending

Scrub or pause in the Source monitor, then mark In with the inward arrow icon
(or **I**) and Out with its matching icon (or **O**). Out is an exclusive boundary:
the appended range ends at that position. The compact readout shows the selected
start, end and duration. Clear with the × icon or **Option-X** to append the full
source again. These shortcuts can be remapped in Settings and apply in the source
workspace; typing into a field does not set marks.

Marks snap to the source frame rate when qualified CFR metadata is available.
Audio and sources without qualified cadence use microsecond positions. In must
precede Out; an invalid mark leaves the previous range intact. Append uses the
same range for linked picture and audio, including **Append with audio selection…**.
The audio sheet captures the range when opened. Undo/redo applies to the completed
append. Marks remain with each source during the session and clear when loading
another document; saved clips retain their exact selected ranges. Finder drops
onto the timeline use the full imported media.

### Timeline fit and ripple-trim shortcuts

Use **Shift+Z** with timeline focus to fit the full sequence in the available
width; repeat to restore the previous zoom. The timeline toolbar also has a fit
button. Long sequences can fit below the zoom slider's former minimum.

Select a timeline clip and put the playhead inside it. **Q** removes the portion
from its start to the playhead; **W** removes the portion from the playhead to its
end. Aligned linked video/audio components trim together. Both commands close the
removed time on every track, moving later clips by the same amount and preserving
source ranges on those later clips. Q moves the playhead to the resulting start
cut; W leaves it at the end cut. Each command is one undoable edit.

This first ripple implementation refuses unrelated clips crossing the removed
interval, mismatched linked extents, and link groups straddling the ripple boundary.
It does not implicitly split or discard overlapping picture/audio. Existing fades
are bounded to the remaining extent; invalidated crossfade relations dissolve as
with ordinary trims. No trim occurs when the playhead is outside or on a clip edge.

The **Timeline** menu and **Settings → Keyboard Shortcuts** expose these commands.
Q/W and Shift+Z are remappable and are suppressed during text entry. If an existing
custom shortcut already uses a newly introduced default, that custom binding is
preserved and the new command starts unbound. I/O source marks and J/K/L transport
remain available; source J runs silent reverse and sequence reverse remains unavailable.
