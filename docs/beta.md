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
5. Set the sequence resolution, frame rate, audio rate and start timecode in the
   inspector. The first picture you add can match the sequence to its source.
6. Choose **File → Render Sequence…** (⇧⌘E), pick a format, check any warnings,
   then choose a folder.
7. Save with ⌘S. Projects reference your media; they don't copy it.

[Basic workspace testing](basic-workspace.md) describes every editing control.

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
menu. See their pages for supported subsets.

## Preview notices

Timeline preview uses AVFoundation. When it can't match the export exactly, a
notice appears under the viewer, but playback continues:

- AAC and MP3 cut points, fade curves and audio at a different sample rate are
  close approximations. The export is exact.
- Gain above 0 dB plays at 0 dB.
- Audio with custom channel routing is silent in preview. It is still exported.

## Known limitations

- Effects, titles, transitions other than audio crossfades, keyframes and a mixer
  are not part of this version.
- No HDR output. HDR sources are tone mapped to SDR, and the preview shows them
  as macOS displays them.
- 5.1 sequences export all six channels (L R C LFE Ls Rs). Stereo media is placed
  on front left/right and mono on centre by default, and the inspector can route
  any channel. The preview plays the system's stereo downmix.
- Reverse sequence playback is unavailable. J plays the source backwards silently.
- Stream-copy (no re-encode) export is not available in the app yet.
- Apple Silicon only. Distribution signing and notarization are not set up, so build
  from source.

## Checking your own media

To check that your files import, preview and export without opening the app, run:

```sh
scripts/real-media-export-check.sh "/path/to/Aagedal Film Constructor.app/Contents/Resources/Helpers" h264 4 /path/to/media/*
```

It runs the app's importer and conversion, preview and export code on the first
four seconds of each file. It prints PASS/FAIL, timings and warnings, and keeps the
rendered files in a temporary folder. The format can be `h264`, `hevc`,
`proRes422` or `proRes422HQ`.

To exercise the real application window end to end, run:

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
folder access. The system file panels are skipped unless `AFC_ACCEPTANCE_PANELS=1`
is set.

## Reporting problems

Please include the message shown in the app, the file's FFprobe summary
(`ffprobe -hide_banner file`) and, if possible, the
`real-media-export-check.sh` output for that file.
