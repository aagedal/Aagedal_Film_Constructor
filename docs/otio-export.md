# OpenTimelineIO sequence export

`OTIOExporter.export(project:projectName:)` creates `.otio` JSON using the canonical OTIO schemas. Export validates the native project and refuses edits outside the supported editorial subset before returning a document. No Python runtime or OTIO package is shipped in the app.

## Supported subset

- Cuts and gaps across separate video/audio tracks, including empty tracks. OTIO stack children are written back-to-front because the native project stores the frontmost track first. Every track is padded with an explicit gap to the sequence end.
- Original local file URLs, Unicode names, source in/duration, timeline positions, and available media duration. Files need not be online when writing references; export does not copy or transcode them. Proxy references are not substituted.
- Complete mono/stereo audio streams matching the sequence layout, unity gain, and identity channel routing. Track kind distinguishes video and audio uses of the same file; receiving-editor stream isolation remains unqualified.
- Sequence frame rate and global start frame count. Sequence dimensions, audio sample rate/layout, and DF/NDF display mode are retained in namespaced metadata because this subset does not define receiving-editor settings for them.
- Exact native rational source/timeline times retained in namespaced clip metadata. Video edits use integer sequence-frame counts; audio edits use integer sequence-sample counts. OTIO's rate values are floating point, so fractional rates cannot claim exact rational arithmetic inside the receiving editor.

Available media ranges encode exact seconds as integer numerator/denominator, without inventing a source frame rate. Their OTIO rate is an encoding clock, not measured source fps. Source frame rate, raster, orientation, sample rate, and pixel aspect are not retained in the native core. A receiving editor must inspect original media.

## Refused features

Audio fades/crossfades and nonunity gain; partial/reordered audio channels; multiple audio streams; nonidentity output routing; differing source/sequence layouts; selecting among multiple video streams; source stream offsets; still images; fill/unscaled geometry; nonlocal/missing original references; nonzero source timecode without a known source rate; unsupported sequence audio layouts; empty sequences; subframe video edits; subsample audio edits; and values or source/record endpoints beyond the conservative exact IEEE-754 integer range (2^53).

The sequence end must lie on a sequence frame boundary and, when any audio track exists, an audio sample boundary. This includes empty audio tracks: tail gaps cannot be rounded. Video uses default fit editorial intent; spatial conform is not qualified. Metadata does not make unsupported fades, routing, geometry, or stream selection portable, so these features fail instead of being encoded as ineffective effects.

Native project identities and exact timing metadata help inspect exported edits. Link groups, family templates, preferences, and editable project recovery remain features of the native project document; this adapter does not provide a native round trip.

## Official core validation

`OTIOExporterTests` cover layered track order, empty tracks, leading/trailing gaps, exact source ranges, sample-position audio edits, original URLs and Unicode names, fractional frame rates/DF metadata, deterministic output, numeric endpoint bounds, and rejection of unsupported edits.

The optional qualification test runs `scripts/validate-otio.py` with official OpenTimelineIO Python bindings, which exercise OTIO's C++ core. It parses generated files, checks every child type/range and track duration, compares clip timing with native rational metadata, checks media references and bounds, and serializes/reparses with the official library to confirm schema equivalence. It covers 24, 25, 24000/1001, 30000/1001, and 60000/1001 fps.

```sh
python3.12 -m venv /tmp/otio-validation
/tmp/otio-validation/bin/python -m pip install opentimelineio==0.18.1
OTIO_PYTHON=/tmp/otio-validation/bin/python swift test --package-path Packages/EditorCore --filter OTIOExporterTests
```

Without `OTIO_PYTHON`, the official-core test reports an explicit skip; all other exporter tests run. A configured but missing/broken runtime causes a failure. OTIO 0.18.1 on Python 3.12 was used for local qualification on October 12, 2026. The locally installed Python 3.14 build raised `RuntimeError: bad any cast` even when serializing a library-created empty Timeline, so it was unsuitable for qualification.

A direct Swift/C++ core bridge has not been implemented. This JSON writer is a small conservative subset qualified against the official core, not a replacement for the library's arbitrary-schema serialization.

**Receiving-editor native import and spatial conform have not been verified.** Core parsing and serialization establish OTIO structure and timing, not Final Cut Pro, Resolve, or Premiere import behavior. Qualification still requires real-media import with layer order, isolated audio, source ranges, fractional-rate media interpretation, sequence settings/timecode, and fit behavior checked in the receiving editor.
