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

Current limits: AVFoundation-supported source formats; no edited-sequence
playback, export, proxies, fades, waveforms, or filmstrips. Stills have a
five-second source extent. Default audio assembly accepts stereo or mono
(duplicated into stereo); other layouts await source-selection controls.

## Verification

```sh
scripts/verify.sh
scripts/app-file-smoke.sh
```

The first runs Python regressions, EditorCore tests, and an unsigned app build.
The second compiles the actual importer, project document, and editor store into
a temporary runner and generates its own WAV/PNG fixtures. It checks document
validation, bookmarks, edit history, relink history, and reopen behavior. macOS
bookmark services must be accessible; restrictive command sandboxes can block
those services. The unsigned build verifies compilation; use Xcode's normal
signed Run for testing sandbox grants across launches.
