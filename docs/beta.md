# Beta guide

Aagedal Film Constructor is in beta. You can assemble a cut from everyday camera,
phone, screen-recording and broadcast media, preview it, and export a deliverable.
This page covers what to expect and what is still missing.

## Requirements and build

- An Apple Silicon Mac with macOS 27 or later, and Xcode 27.
- Open `Aagedal Film Constructor.xcodeproj`, choose the **Aagedal Film Constructor**
  scheme and **My Mac**, then Run. The first build downloads the pinned, signed
  FFmpeg/FFprobe helpers and needs internet access; later builds reuse the cache.
  See [helper packaging](media-helper-packaging.md) for offline setup.
- `scripts/verify.sh` runs the automated checks and builds the app.

## Distribution build

`scripts/release-sign-notarize.sh [output-folder]` builds Release and signs it with
Developer ID: sandboxed, hardened runtime, timestamped helpers. It then notarizes
the app with the `notary` keychain profile, staples the ticket and writes
`Aagedal-Film-Constructor-<version>.zip`. The release bundle ID is
`me.aagedal.FilmConstructor`. Override it with `AFC_BUNDLE_ID`, the team with
`AFC_TEAM_ID` and the profile with `AFC_NOTARY_PROFILE`. Set `AFC_SKIP_NOTARIZE=1`
to sign only. On 2026-10-23 the 0.9 build was accepted by Apple's notary service,
and Gatekeeper assesses it as "Notarized Developer ID".

## Quick start

1. Launch the app. An untitled workspace opens ready for media.
2. Drag files from Finder onto the media bin (import) or the timeline (import and
   place). You can also use **Import** or ⌘I.
3. Select a bin item to view it in the Source monitor. Mark In/Out with I/O and
   press **Append** (⌘E) to add it to the timeline.
4. Click the timeline to switch the viewer to Sequence. Space plays and pauses;
   J/K/L also work. Drag clips to move them, drag edges to trim, use ⌘B to split
   and ⌘⌫ to delete. Undo and redo with ⌘Z and ⇧⌘Z. Every shortcut can be
   remapped in Settings.
5. Select a clip and press ⌘T to add a transition at its edit nearest the
   playhead: picture cross dissolves and sound crossfades into the next clip on
   the same track, or a free edge fades from or to black and silence. See
   [Transitions](#transitions).
6. Set the sequence resolution, frame rate, audio rate and start timecode in the
   inspector. The first picture you add can match the sequence to its source.
7. Choose **File → Render Sequence…** (⇧⌘E), pick a format, check any warnings,
   then choose a folder.
8. Save with ⌘S. Projects reference your media; they don't copy it.

[Basic workspace testing](basic-workspace.md) describes every editing control.

## Editing at the playhead

| Key | Action |
| --- | --- |
| ⌘E | Append the source (or its marked range) to the end of the sequence |
| , | Insert the source at the playhead, pushing later clips on every track |
| . | Overwrite the sequence at the playhead on the source's tracks |
| ⌘B | Split the selected clip at the playhead |
| ⌘⌫ | Delete the selected clip, leaving a gap |
| ⇧⌘⌫ | Ripple delete: remove the clip and close the gap on every track |
| Q / W | Ripple trim the clip start or end to the playhead |
| ⌘C ⌘X ⌘V | Copy, cut, and paste at the playhead (clip and linked components) |
| ⌘D | Duplicate the selected clip after itself |

Insert and overwrite are also buttons beside **Append** under the media bin.
Insert refuses to split inside a fade or transition, and ripple delete refuses
when another clip crosses the gap; move or trim that clip first. Pasting over
occupied time stacks the copy on a new sibling track rather than overwriting.

## Transitions

- **⌘T (Add Transition)** works on the selected clip and its linked components in
  one undoable edit. It uses the clip edge nearest the playhead. Where another clip
  meets that edge on the same track, picture gets a one-second cross dissolve and
  sound an equal-power crossfade. A dissolve centres on the cut and uses source
  beyond it, shrinking to fit the source that is available. When no media lies
  beyond the cut (whole clips placed end to end), the clips dip through black and
  silence instead. An edge with no neighbour fades the picture from or to black
  (or the layers below) and fades the sound. Edges that already have a
  transition are left as they are.
- In the inspector's **Transition to next clip**, choose a **Style**: cross dissolve,
  slide in from the right or left, push left or right, or wipe left to right or right
  to left. Slides move the next clip in over this one; pushes move both; wipes uncover
  it with a moving edge. They need full-frame clips without their own
  scale, position or keyframes.
- Picture clips have fade handles like audio clips: drag the yellow handle inward
  to fade, or drop it onto the neighbouring clip to dissolve. The inspector sets
  exact fade and dissolve durations and removes dissolves.
- Picture fades and dissolves are linear and snap to whole frames. Exports render
  them exactly. For Rec. 709 media, preview and export match within a few levels.
- FCPXML writes fades as adjustments; FCPXML, OTIO and EDL refuse transitions rather
  than dropping them.

## Scale, position and opacity

Select a picture clip and use **Transform** in the inspector: scale and opacity in
percent, and position as a percentage of the frame (positive X moves right, positive
Y down). The picture-in-picture button shrinks the clip to a third in the lower right
corner, and reset restores it. Layers below show around and through a transformed
picture. Interchange exports refuse transformed clips.

## Motion

To animate a picture or title, set **Scale**, **Position** and **Opacity** under
Transform, move the playhead and click the diamond to add a keyframe; repeat at
another time. The picture moves, scales and fades between keyframes. **Motion presets** (the wand) add a
slide in from the left, a rise from below, a slow zoom or a drift in one step. The
inspector lists keyframes to jump to or remove.

## Speed

Select a clip and enter **Speed (%)** in the inspector (10–1000%), or pick a preset.
The clip keeps its source in and plays the same media faster or slower, so it gets
shorter or longer; linked sound changes with it and keeps its pitch. A longer clip
never overwrites the next one; it moves to a track above. Interchange exports
refuse speed changes.

## Colour

Select a picture clip and drag **Brightness**, **Contrast**, **Saturation**, **Blur**
or the **Levels** sliders (black point, white point, gamma) under **Colour, levels and
blur** in the inspector; each release is one undoable change, and the reset
button restores the original. Sequences with colour correction preview through a
CoreImage compositor; preview colours are within a few levels of the export.

## Titles

Press ⌃T (or the **T** button in the timeline toolbar) to add a five-second title at
the playhead. It goes on a **Titles** track in front of the picture. Select it to
edit the text, font, alignment, size, position, colour, weight and an optional background band in
the inspector, then click **Apply title**. Trim, move, fade and dissolve titles
like any other clip. Titles are drawn as transparent images in the app's
Application Support "Titles" folder and redrawn if missing. Interchange exports
reference those images as stills.

## EQ

Select an audio clip (or a picture with linked sound) and drag **Low** (120 Hz shelf),
**Mid** (1 kHz) or **High** (8 kHz shelf) under **EQ** in the inspector, ±24 dB. The
preview and the export run the same filters.

## Volume, keyframes, mute and solo

Choose **Panels → Mixer** (or View → Show Mixer) for a mixer beside the inspector:
each audio track has mute, solo, a gain fader and a meter that shows its post-fader
peak while the sequence plays.

To ride a level (for example ducking music under speech), select the clip, move the
playhead to where the change starts, enter a volume and click the diamond to add a
keyframe; add another where it should end. Volume ramps linearly between keyframes
and holds before the first and after the last. The orange line on the clip shows it;
the inspector lists keyframes to jump to or remove.

Each track header has quick controls: the eye hides a video track, **M** mutes an
audio track and **S** solos it (while any track is soloed, only soloed audio
plays). Hidden and muted tracks are left out of preview and every export.

Select a clip and enter **Clip volume (dB)** in the inspector (up to +24 dB; −inf
silences it). With a picture selected, the field sets its linked audio. Clip
volume multiplies the track gain set in the track header. The preview plays gain
above 0 dB at 0 dB; the export applies it in full.

## Media support

**Opened directly** (through AVFoundation): MOV, MP4 and M4V with H.264, HEVC
(including iPhone HDR) or ProRes; WAV, AIFF, M4A/AAC, ALAC, MP3 and FLAC audio;
PNG and JPEG stills.

**Converted on import** (through the bundled FFmpeg): MXF (XDCAM, XAVC and AVC-Intra),
MKV, WebM, AVI, MPEG-TS/M2TS, FLV, WMV, Ogg and MPEG files, and H.264 that macOS
can't decode, such as 10-bit 4:2:2. The app writes an edit-ready MOV to
`~/Library/Containers/…/Application Support/Converted Media`. When the codec allows
it, picture is rewrapped. Otherwise it becomes ProRes 422, or ProRes 4444 when the
source has alpha. All audio streams become 24-bit PCM, and timecode is kept.
Conversion takes seconds for rewraps and about real time for transcodes. The bin
shows the original file name. Delete converted files you no longer need from that
folder.

Stills are placed at five seconds by default. Drag the clip edge to hold one for
up to an hour.

## Export

| Format | Use |
| --- | --- |
| ProRes 422 HQ · PCM (MOV) | Mastering and handoff to other editors |
| ProRes 422 · PCM (MOV) | Smaller mezzanine files |
| H.264 · AAC (MP4) | Upload, review links and general playback |
| HEVC · AAC (MP4) | Smaller files using the hardware encoder |

Every export renders at the sequence resolution, frame rate, audio rate and start
timecode. Edit points that fall between frames or samples snap to the nearest one. The app then checks the frame count, sample count, codecs and timecode
before the file appears. Picture is conformed to the sequence frame rate and audio
is resampled to the sequence rate. Rotation and non-square pixels are corrected.

HDR sources (HLG and PQ, such as iPhone video) are tone mapped to SDR Rec. 709
with VideoToolbox. Every export is tagged Rec. 709. The export window lists these
conversions before you export, along with variable frame rate being conformed to
the sequence rate. **Strict source qualification** turns
these warnings into refusals, for when exact decoded parity matters more than
convenience.

FCPXML, OpenTimelineIO and track EDL exports are also available from the File
menu. FCPXML also carries volume, fades, scale, position,
opacity and their keyframes as Final Cut adjustments (DTD-valid; editor import of
these adjustments is not yet verified). DaVinci Resolve 21 imports both with media linked and every clip at the exact
frame, source offset and layer. Resolve's renders of the imported timelines match
the app's own render. Media with embedded timecode (most camera and broadcast
files) is referenced in its own timecode clock, as editors expect. FCPXML writes
audio channel selections (for example dual mono, or two channels of a multitrack
MXF) as `audio-channel-source`, which is valid FCPXML 1.10. Resolve ignores those
selections and plays the clip's first channel, so check the audio routing after
importing multitrack sources into Resolve. OTIO has no channel mapping and refuses
those clips. Final Cut Pro 11 imports the FCPXML with every clip, timecode start
and layer intact. See their pages for supported subsets.

## Preview notices

Timeline preview uses AVFoundation. When it can't match the export exactly, a
notice appears under the viewer, but playback continues:

- AAC and MP3 cut points, fade curves and audio at a different sample rate are
  close approximations. The export is exact.
- Gain above 0 dB plays at 0 dB.
- Audio with custom channel routing is silent in preview. It is still exported.

## Known limitations

- Effects beyond basic colour correction and blur (curves, keying, stabilisation; levels cover black/white points and gamma), title animation beyond position, scale and opacity, transitions other than dissolves, slides, pushes, wipes, dips and crossfades, and audio effects beyond the three-band EQ (compression, noise reduction) are not part of this version.
- No HDR output. HDR sources are tone mapped to SDR, and the preview shows them
  as macOS displays them.
- 5.1 sequences export all six channels (L R C LFE Ls Rs). Stereo media is placed
  on front left/right and mono on centre by default, and the inspector can route
  any channel. The preview plays the system's stereo downmix.
- Reverse sequence playback is unavailable. J plays the source backwards silently.
- Stream-copy (no re-encode) export is not available in the app yet.
- Apple Silicon only.

## Checking your own media

To check that your files import, preview and export without opening the app, run:

```sh
scripts/real-media-export-check.sh "/path/to/Aagedal Film Constructor.app/Contents/Resources/Helpers" h264 4 /path/to/media/*
```

It runs the app's importer and conversion, preview and export code on the first
four seconds of each file. It prints PASS/FAIL, timings and warnings, and keeps the
rendered files in a temporary folder. The format can be `h264`, `hevc`,
`proRes422` or `proRes422HQ`.

To exercise the real application window end to end, run the command below. Pass
`generate` instead of media to have the bundled FFmpeg create test files inside
the run. With `AFC_ACCEPTANCE_CONTAINER=1`, this also works for the signed,
sandboxed release build.

```sh
scripts/app-acceptance.sh "/path/to/Aagedal Film Constructor.app" /path/to/media/*
```

The app comes to the front for a few minutes. It imports the files onto the
timeline (converting any that need it) and overlaps a second placement. It then
applies fades and a crossfade, changes a multitrack clip's source streams,
relinks one original, generates proxies and switches to Prefer Proxy. Next it
remaps Play / Pause, switches to the Sequence viewer with Tab, plays and pauses
with Space, and opens Render Sequence with ⇧⌘E. Finally it renders H.264 and
ProRes 422 HQ, then saves, closes and reopens the project. It prints PASS/FAIL
for each step and keeps window snapshots, renders and the project in the printed
folder. Use media outside Desktop, Documents and Downloads, or macOS asks for
folder access. With `AFC_ACCEPTANCE_PANEL_PROBES=1`, short extra launches check that ⌘I opens the real Import panel and
that Return in Render Sequence opens the real folder panel. They also check that
the folder panel round-trips: it navigates, confirms, returns the destination to
the app (export starts) and cancels cleanly. The main run exports and saves
through the same calls the panels make. The probes are off by default: an unsigned build can be refused by the
system panel service, which leaves an "open file operation failed" alert to dismiss.

To watch the app cut a short film from your own shots (marks, dissolves, slow motion,
grade, title, music bed with ducking, playback, export and save), run:

```sh
scripts/story-edit.sh "/path/to/Aagedal Film Constructor.app" "shot1.mov@8-13" "shot2.mov@20-25" "shot3.mov@5-9" "shot4.mov@60-66"
```

Each argument is a file and its source in/out in seconds; the third shot plays at 50%.

## Reporting problems

Please include the message shown in the app, the file's FFprobe summary
(`ffprobe -hide_banner file`) and, if possible, the
`real-media-export-check.sh` output for that file.
