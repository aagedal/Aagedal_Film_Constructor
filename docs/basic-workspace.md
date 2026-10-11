# Test the basic workspace

Open `Aagedal Film Constructor.xcodeproj` in Xcode 27 or compatible, choose the
**Aagedal Film Constructor** scheme and **My Mac**, then Run. The app requires
macOS 14+. On the initial file dialog choose **New Document** (or use File → New).

1. Import a short MOV/MP4, WAV/M4A, or PNG/JPEG using **Import**, ⌘I, or dropping files from Finder onto the workspace.
   Import inspects media asynchronously. Select each file in the bin to preview
   the original source; video/audio use the monitor's playback controls.
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
5. Change sequence raster/frame rate or clip scaling in the inspector. Scaling
   is stored for future sequence monitoring/export; the source monitor displays
   the original media.
6. In the inspector set **Start timecode**, then **Apply timecode**. Use
   `HH:MM:SS:FF`, or `HH:MM:SS;FF` for drop frame at 29.97/59.94 fps. Invalid
   labels are rejected. Start timecode changes labels without shifting clips.
   Toggle **Remove empty tracks after edits** to preserve unused tracks. Use
   **Panels** in the toolbar or the **View** menu to hide/show the bin, inspector,
   and timeline; these panel choices persist across launches.
7. Save with ⌘S as an `.afcproject`, close, and reopen using ⌘O. Check that files,
   clip timings, links, tracks, and sequence settings survive. Native documents
   autosave after saving and expose the usual Save/Duplicate/Revert commands.
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
   asset, source range, timeline start, linked group, family and gain. Different
   timing or gain must be resolved separately. Try combining two mono components
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

Current limits: AVFoundation-supported source formats; no edited-sequence
playback, export, proxies, or fades. Stills have a
five-second source extent. Default audio assembly accepts matching layouts or mono
(duplicated into stereo); other layouts use the explicit initial selection sheet.
Post-insertion explicit maps support other streams/layouts on existing components.

## Verification

```sh
scripts/verify.sh
scripts/app-file-smoke.sh
scripts/shortcut-smoke.sh
scripts/timeline-preview-smoke.sh
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
