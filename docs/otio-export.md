# OpenTimelineIO sequence export

`OTIOExporter.export(project:projectName:)` creates `.otio` JSON using the canonical OTIO schemas. Export validates the native project. Edits outside the supported editorial subset are left out and listed in the result's `warnings`, which the app shows before the save panel. Timing is never rounded: a clip off the grid is left out rather than moved. No Python runtime or OTIO package is shipped in the app.

## Supported subset

- Cuts and gaps across separate video/audio tracks, including empty tracks. OTIO stack children are written back-to-front because the native project stores the frontmost track first. Every track is padded with an explicit gap to the sequence end.
- Original local file URLs, Unicode names, source in/duration, timeline positions, and available media duration. Files need not be online when writing references; export does not copy or transcode them. Proxy references are not substituted.
- Complete mono/stereo audio streams matching the sequence layout, unity gain, and identity channel routing. Track kind distinguishes video and audio uses of the same file; receiving-editor stream isolation remains unqualified.
- Sequence frame rate and global start frame count. Sequence dimensions, audio sample rate/layout, and DF/NDF display mode are retained in namespaced metadata because this subset does not define receiving-editor settings for them.
- Exact native rational source/timeline times retained in namespaced clip metadata. Video edits use integer sequence-frame counts; audio edits use integer sequence-sample counts. OTIO's rate values are floating point, so fractional rates cannot claim exact rational arithmetic inside the receiving editor.

Available media ranges encode exact seconds as integer numerator/denominator, without inventing a source frame rate. Their OTIO rate is an encoding clock, not measured source fps. Source frame rate, raster, orientation, sample rate, and pixel aspect are not retained in the native core. A receiving editor must inspect original media.

Sequence markers are written as one-frame `Marker.2` objects on the top-level stack
with name, comment (the note), colour and the exact time in namespaced metadata. Markers
off the frame grid or at or after the sequence end are left out with a warning. The official core reads
and round-trips them.

## Transitions and speed

Cross dissolves and audio crossfades are written as `Transition.1` objects of type
`SMPTE_Dissolve` between the two clips that meet at the cut. `in_offset` is the part before
the cut and `out_offset` the part after; clips keep their editorial ranges and the
transition uses their handles. Overlapping crossfades are cut at the middle of the overlap.
The fade curve (linear or equal power) is kept in namespaced metadata.

A clip at another speed has a `LinearTimeWarp.1` effect with `time_scalar` set to the speed.
As in OTIO's adapters, its `source_range` starts at the media in point and keeps the clip's
duration in the track. The exact rational speed is also kept in the clip's metadata.
The official core validator checks transition offsets, that clips meet at each transition,
that the handles lie within the media, and the time warp (`InterchangeTransitionTests`).

## Left out, with a warning

Each warning names the clips or markers it affects.

- **Clips left out:** still images; media without a local original file; nonzero source timecode without a known source rate; source stream offsets; subframe video edits and subsample audio edits; and times beyond the conservative exact IEEE-754 integer range (2^53).
- **Effects left out, clip exported:** audio and picture fades (dips to black), gain and volume keyframes, compression, keying, EQ, stabilisation, colour correction, scale, position and opacity, track and bus effects, and output routing. Partial or reordered channel selections reference the whole stream; with multiple audio or video streams the receiving editor picks one. Differing source and sequence layouts are not converted, and fill and unscaled geometry are fitted.
- **Transitions:** slide, push and wipe transitions are written as SMPTE dissolves. Crossfades between clips on different tracks, transitions off the track's grid, and transitions whose other clip is left out, hidden or muted become cuts.
- **Markers** off the frame grid, beyond the exact integer range, or at or after the sequence end are left out.

Metadata does not make fades, routing, geometry or stream selection portable, so they are left out and reported rather than encoded as ineffective effects.

## Refused

Export is refused only when no file can be written: an empty sequence, one whose clips are all left out, an unsupported sequence audio layout, or a frame rate, start timecode or sequence end beyond OTIO's exact range. The sequence end must lie on a sequence frame boundary and, when any audio track exists, an audio sample boundary, because tail gaps cannot be rounded. Video uses default fit editorial intent; spatial conform is not qualified.

Native project identities and exact timing metadata help inspect exported edits. Link groups, family templates, preferences, and editable project recovery remain features of the native project document; this adapter does not provide a native round trip.

## Official core validation

`OTIOExporterTests` cover layered track order, empty tracks, leading/trailing gaps, exact source ranges, sample-position audio edits, original URLs and Unicode names, fractional frame rates/DF metadata, deterministic output, numeric endpoint bounds, warnings for edits left out, and refusal when nothing can be written.

The optional qualification test runs `scripts/validate-otio.py` with official OpenTimelineIO Python bindings, which exercise OTIO's C++ core. It parses generated files, checks every child type/range and track duration, compares clip timing with native rational metadata, checks media references and bounds, and serializes/reparses with the official library to confirm schema equivalence. It covers 24, 25, 24000/1001, 30000/1001, and 60000/1001 fps.

```sh
python3.12 -m venv /tmp/otio-validation
/tmp/otio-validation/bin/python -m pip install opentimelineio==0.18.1
OTIO_PYTHON=/tmp/otio-validation/bin/python swift test --package-path Packages/EditorCore --filter OTIOExporterTests
```

Without `OTIO_PYTHON`, the official-core test reports an explicit skip; all other exporter tests run. A configured but missing/broken runtime causes a failure. OTIO 0.18.1 on Python 3.12 was used for local qualification on October 12, 2026. The locally installed Python 3.14 build raised `RuntimeError: bad any cast` even when serializing a library-created empty Timeline, so it was unsuitable for qualification.

A direct Swift/C++ core bridge has not been implemented. This JSON writer is a small conservative subset qualified against the official core, not a replacement for the library's arbitrary-schema serialization.

**Receiving-editor native import and spatial conform have not been verified.** Core parsing and serialization establish OTIO structure and timing, not Final Cut Pro, Resolve, or Premiere import behavior. Qualification still requires real-media import with layer order, isolated audio, source ranges, fractional-rate media interpretation, sequence settings/timecode, and fit behavior checked in the receiving editor.
