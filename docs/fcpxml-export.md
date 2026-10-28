# FCPXML sequence export

`FCPXMLExporter.export(project:projectName:)` produces an FCPXML 1.10 document and an export report. The app saves this as a `.fcpxml` file. Export validates the project first. Edits outside the subset are left out of the XML and listed in the report's `warnings`, which the app shows before the save panel so you can export the rest or cancel. Timing is never rounded: a clip that can't be placed exactly is left out rather than moved.

## Supported subset

- Exact rational sequence frame duration, raster dimensions, start timecode, and drop-frame/non-drop-frame display mode. No decimal frame-rate conversion is used.
- Original local file URLs, escaped as XML attributes. Assets are emitted once per referenced asset identity; unused assets are excluded. Export neither copies nor transcodes media, and does not require files to be online when writing a reference.
- Separate video and audio uses of the same media through `srcEnable`, so a video-only timeline component does not accidentally enable embedded audio.
- Layered video: the first video track in the project receives the highest positive lane and remains frontmost. Audio tracks receive separate negative lanes.
- Exact source starts, timeline positions, and clip durations. A gap forms the sequence bed; its offset uses the sequence start timecode while its local start stays zero. Connected clip offsets remain relative to sequence position zero.
- Video fit/fill using `adjust-conform`, and full mono/stereo audio streams with matching sequence layouts, unity gain, and identity output routing.
- Audio source/timeline times remain rational, including sample-position offsets. Video timeline positions and durations, and the sequence end, must fall on sequence frame boundaries; export does not round or pad them.

Source media format attributes are deliberately omitted. The core does not currently retain source frame rate, raster, orientation, pixel aspect, color metadata, or sample rate. Substituting the sequence format would invent source properties. The receiving editor must inspect the original media. Mixed-rate interpretation and fit/fill equivalence, particularly rotated or anamorphic media, remain unqualified; a successful report states this limitation.

## Left out, with a warning

Each warning names the clips or markers it affects.

- **Clips left out:** still images; media without a local original file; nonzero source timecode without a known source frame rate; source stream time offsets; audio channels missing from the source; video positions or durations off the sequence frame grid; and times whose denominator exceeds the DTD's 32-bit limit.
- **Effects left out, clip exported:** compression, keying, EQ, stabilisation, colour correction and blur, track and bus effects, and nonidentity channel routing. Differing source and sequence audio layouts are not converted. The choice among multiple video streams is not written, so the receiving editor picks the stream. Unscaled clips are written with Final Cut's `none` conform.
- **Transitions:** slide, push and wipe transitions are written as cross dissolves. Crossfades between clips on different tracks, and transitions whose other clip is left out, hidden or muted, become cuts.
- **Markers** off the frame grid or at or after the sequence end are left out. Characters XML 1.0 can't represent are replaced with U+FFFD.

## Refused

Export is refused only when no file can be written: an empty sequence, one whose clips are all left out, an unsupported sequence audio layout or sample rate, a sequence end off the frame grid, or a sequence time whose denominator exceeds 32 bits. The refusal also lists what would have been left out.

Track family names, empty track retention, link groups, and editor preferences do not have equivalents in this subset. The export report explicitly states that they are not interchange metadata. The resulting connected-clip structure represents edit timing and layer order, not an exact round trip of the app's track organization.

## Adjustments

Clip and track volume, audio and picture fades, scale, position, opacity and their
keyframes are written as Final Cut adjustments: `adjust-volume` (dB, with `fadeIn`/
`fadeOut` and volume keyframes), `adjust-transform` (position in percent of the frame
height with y up, uniform scale, keyframed `position` and `scale` params) and
`adjust-blend` (opacity, with fades and opacity keyframes). Keyframe times are in the
clip's source time. Equal-power fades are written as ease fades. These elements validate
against Apple's FCPXML 1.10 DTD (bundled with Final Cut Pro). A first import into Final
Cut Pro (2026-10-26) imported the file but ignored every keyframed param because the
keyframes carried `interp`; keyframes now carry only `curve="linear"`. The corrected file imported without
warnings (2026-10-26): picture fades start at 0% opacity and volume keyframes appear on
the audio clip. Resolve's interpretation is still to be checked.

## Transitions and speed

A track with cross dissolves or audio crossfades is written as a connected storyline
(`spine`) on that track's lane, at offset 0 on the sequence bed, so its children share
the bed's time. Gaps hold clips at their places. Clips keep their editorial ranges and
meet at each cut; a `transition` starts `before` the cut and lasts the whole transition,
so the receiving editor plays it from both clips' handles, as Final Cut does. Picture
transitions reference Final Cut's Cross Dissolve (`FxPlug:4731E73A-8DAC-4113-9A30-AE85B1761265`),
and sound uses Audio Crossfade (`FFAudioTransition`). Linked picture and sound stay one A/V
clip only when both clips on each side of a transition merge, so a crossfade never loses a
side. Tracks without transitions keep connected clips exactly as before.

A clip at another speed has a two-point linear `timeMap` across its whole asset (local time
`origin + media / speed`). Its `start` and keyframe times are in that retimed local time, and
`preservesPitch` stays at its default of 1, as the app plays it. These elements validate
against Apple's FCPXML 1.10 DTD (`InterchangeTransitionTests`). Import into Final Cut Pro and
Resolve has not been checked yet.

## Markers

Sequence markers are written as one-frame `marker` elements on the sequence bed gap,
after its anchored clips as the DTD requires, with the name as `value` and the note as
`note`. FCPXML markers have no colour, so colours are not written. Markers off the
sequence frame grid or at or after the sequence end are left out with a warning. A marked fixture
validates against Apple's FCPXML 1.10 DTD; import into Final Cut Pro is still to be checked.

## Validation and remaining qualification

Eight `FCPXMLExporterTests` cover exact 24/25/23.976/29.97/59.94 timing, sequence start timecode, DF/NDF mode, lane order, source offsets, escaped names/URLs, reused media resources, mono audio, unused assets, warnings for edits left out, and refusal when nothing can be written.

An optional test checks fixtures against a locally provided [Apple FCPXML 1.10 DTD](https://developer.apple.com/documentation/professional-video-applications/document-type-definition). Set `FCPXML_DTD` to the downloaded DTD path and run:

```sh
FCPXML_DTD=/path/to/FCPXMLv1_10.dtd swift test --package-path Packages/EditorCore --filter FCPXMLExporterTests
```

This was run successfully against Apple's 1.10 DTD on October 11, 2026, including layered video/audio fixtures at 24, 23.976, 29.97, and 59.94 fps. The DTD is not bundled or downloaded by the test suite. Without the environment variable, the schema test is skipped explicitly.

**Native Final Cut Pro and Resolve import has not been verified.** DTD conformance establishes XML structure, not receiving-editor media interpretation or import success. Native qualification still needs real media import and returned-XML inspection covering sequence dimensions/timecode, clip timing/source ranges, visible layer order, isolated audio, and fit/fill behavior. The successful export report includes this qualification limit rather than claiming an editor round trip.

The implementation follows Apple's [Creating FCPXML Documents](https://developer.apple.com/documentation/professional-video-applications/creating-fcpxml-documents) and DTD documentation. The neighboring Aagedal-Media-Player repository's `Logic/CompareReviewReportExporter.swift` was inspected for its existing rational-time, original-media reference, and XML escaping approach. No source code was copied; this sequence exporter and its tests are new and do not inherit that project's marker/native-import qualification.
