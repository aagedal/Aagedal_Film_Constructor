# FCPXML sequence export

`FCPXMLExporter.export(project:projectName:)` produces an FCPXML 1.10 document and an export report. The app saves this as a `.fcpxml` file. Export validates the project first and refuses unsupported edits with concrete reasons before producing XML.

## Supported subset

- Exact rational sequence frame duration, raster dimensions, start timecode, and drop-frame/non-drop-frame display mode. No decimal frame-rate conversion is used.
- Original local file URLs, escaped as XML attributes. Assets are emitted once per referenced asset identity; unused assets are excluded. Export neither copies nor transcodes media, and does not require files to be online when writing a reference.
- Separate video and audio uses of the same media through `srcEnable`, so a video-only timeline component does not accidentally enable embedded audio.
- Layered video: the first video track in the project receives the highest positive lane and remains frontmost. Audio tracks receive separate negative lanes.
- Exact source starts, timeline positions, and clip durations. A gap forms the sequence bed; its offset uses the sequence start timecode while its local start stays zero. Connected clip offsets remain relative to sequence position zero.
- Video fit/fill using `adjust-conform`, and full mono/stereo audio streams with matching sequence layouts, unity gain, and identity output routing.
- Audio source/timeline times remain rational, including sample-position offsets. Video timeline positions and durations, and the sequence end, must fall on sequence frame boundaries; export does not round or pad them.

Source media format attributes are deliberately omitted. The core does not currently retain source frame rate, raster, orientation, pixel aspect, color metadata, or sample rate. Substituting the sequence format would invent source properties. The receiving editor must inspect the original media. Mixed-rate interpretation and fit/fill equivalence, particularly rotated or anamorphic media, remain unqualified; a successful report states this limitation.

## Refused features

Audio fades and crossfades; nonunity gain; source stream time offsets; partial/reordered audio selections; multiple audio streams; nonidentity channel routing; mono-to-stereo or other differing layout conversion; selection among multiple video streams; still images; unscaled video geometry; missing/nonlocal original URLs; nonzero source timecode without a known source frame rate; unsupported sequence audio layouts/sample rates; empty sequences; times whose denominator exceeds the DTD's 32-bit limit; XML 1.0-incompatible text; and video or sequence timing that would require rounding.

Track family names, empty track retention, link groups, and editor preferences do not have equivalents in this subset. The export report explicitly states that they are not interchange metadata. The resulting connected-clip structure represents edit timing and layer order, not an exact round trip of the app's track organization.

## Validation and remaining qualification

Eight `FCPXMLExporterTests` cover exact 24/25/23.976/29.97/59.94 timing, sequence start timecode, DF/NDF mode, lane order, source offsets, escaped names/URLs, reused media resources, mono audio, unused assets, and rejection of unsupported edits.

An optional test checks fixtures against a locally provided [Apple FCPXML 1.10 DTD](https://developer.apple.com/documentation/professional-video-applications/document-type-definition). Set `FCPXML_DTD` to the downloaded DTD path and run:

```sh
FCPXML_DTD=/path/to/FCPXMLv1_10.dtd swift test --package-path Packages/EditorCore --filter FCPXMLExporterTests
```

This was run successfully against Apple's 1.10 DTD on October 11, 2026, including layered video/audio fixtures at 24, 23.976, 29.97, and 59.94 fps. The DTD is not bundled or downloaded by the test suite. Without the environment variable, the schema test is skipped explicitly.

**Native Final Cut Pro and Resolve import has not been verified.** DTD conformance establishes XML structure, not receiving-editor media interpretation or import success. Native qualification still needs real media import and returned-XML inspection covering sequence dimensions/timecode, clip timing/source ranges, visible layer order, isolated audio, and fit/fill behavior. The successful export report includes this qualification limit rather than claiming an editor round trip.

The implementation follows Apple's [Creating FCPXML Documents](https://developer.apple.com/documentation/professional-video-applications/creating-fcpxml-documents) and DTD documentation. The neighboring Aagedal-Media-Player repository's `Logic/CompareReviewReportExporter.swift` was inspected for its existing rational-time, original-media reference, and XML escaping approach. No source code was copied; this sequence exporter and its tests are new and do not inherit that project's marker/native-import qualification.
