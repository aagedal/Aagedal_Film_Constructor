# CMX3600 track EDL export

`CMX3600Exporter` exports one explicitly selected timeline track. It does not
flatten the sequence. Other picture/audio layers, linked components on other
tracks and the sequence tail beyond the selected track's last clip are excluded.
Leading and internal gaps become `BL` cut events. Source and record out points
are exclusive; timing is never rounded.

The supported subset is one picture track or one complete mono/stereo audio
track with cuts, dissolves, fades and speed changes, unity gain and identity audio
channels/routing. Anything else is left out and listed in the report's `warnings`,
which the app shows before the save panel:

- **Clips left out:** stills, speeds that aren't a whole tenth of a frame per second,
  missing or inconsistent source timing evidence, invalid or shared reels, multiple
  selected source streams, source offsets, edit points off the frame grid (including
  those a speed change puts between source frames), and timecodes outside one day.
  The space they leave becomes a `BL` gap.
- **Effects left out, clip exported:** gain, volume keyframes, compression, keying,
  EQ, stabilisation, colour correction, scale, position and opacity, track effects,
  audio remapping, partial channel selections, fill/unscaled geometry, and fades
  off the frame grid. Names and marker text outside printable ASCII are written with
  `?` in their place.
- **Transitions:** slides, pushes and wipes are written as dissolves. Crossfades with
  a clip on another track, dissolves off the frame grid or over 999 frames, and
  dissolves whose other clip is left out become cuts.

Default fit is a receiving-editor conform choice, not an encoded spatial transform. EDL does not preserve raster, color, scale, layout,
track families, links, preferences or media file paths.

Supported rates are exactly 24, 24000/1001, 25, 30 and 30000/1001. Source and
sequence rates and timecode counting modes must match. Drop-frame is supported
at 30000/1001. The receiving editor must be configured to the same exact rational
rate: the `FCM` header declares counting mode, not frame rate. Labels use colons
even for drop-frame lists. Source and record endpoints, including exclusive out
points, must remain inside a single 24-hour timecode day; a clip that would wrap
is left out rather than given ambiguous labels.

Each used asset requires caller-supplied `CMX3600SourceTiming`, keyed by its asset
UUID: source frame rate, start timecode, selected stream index and reel identity.
Video additionally requires verified constant-frame-rate timing. A nominal
FFprobe rate tag alone is not sufficient evidence of CFR, and absent source
timecode must not be replaced with zero. These values are a caller evidence
contract, not an exporter probe or persisted metadata. Callers must acquire
evidence from the original source snapshot they export, reject stale results
and obtain an explicit source timecode from media metadata or a user who knows
the source. The exporter cross-checks stored source timecode when present.

Reels must be unique across distinct assets, 1–8 uppercase ASCII letters/digits;
`BL` is reserved for gaps. Repeated uses of one asset share its reel. Names and
the title must contain printable ASCII on one line, preventing comments from
injecting additional EDL records. Clip names appear as `FROM CLIP NAME` comments;
reel identity remains the explicit media-matching key. Maximum 999 events
includes gaps. Export is refused only when no EDL can be written: a missing or
empty track, one whose clips are all left out, an unsupported rate or audio layout,
an invalid title, or more than 999 events.

The pure core exporter never reads or writes media. The app must show the selected
track and report notes before saving and handle the resulting EDL as a track
interchange document. Native Final Cut Pro/Resolve import and media conform remain
unqualified; no rendered picture/audio equivalence is claimed.

## Dissolves, fades and speed

A cross dissolve or crossfade centred on a cut becomes a dissolve event: the
outgoing clip's event ends where the transition starts, then a zero-length `C` line
for the outgoing source is followed by a `D` line (with the length in frames) for
the incoming source, which starts that many frames before its in point. A fade in is
a dissolve from `BL`, and a fade out a dissolve to `BL`. Dissolves and fades must
fall on frame boundaries and last at most 999 frames; otherwise a dissolve becomes
a cut and a fade is left out, with a warning.

A clip at another speed gets an `M2` line with its speed in timecode frames per
second (speed × the nominal rate, one decimal, at most 999.9) and its source in.
Its source out is the source in plus the source it plays, so each edit point must
fall on a whole source frame; otherwise the clip is left out rather than rounded. Dissolve events
name both clips (`* FROM CLIP NAME` and `* TO CLIP NAME`).

## Markers

Sequence markers inside the selected track's events become Avid-style locator comments
under the event that contains them: `* LOC: <record timecode> <colour> <name - note>`.
Orange becomes RED and purple and pink become MAGENTA, the nearest of the eight classic
locator colours. Markers off the frame grid or after the track's final clip are left
out, and text that isn't printable ASCII is written with `?`, each with a warning.
Receiving-editor import of locators is unqualified.

## App workflow

Choose **Export track EDL…** in the toolbar Export menu or File menu. The sheet
captures the project when opened and initially selects the selected clip's track
(or the first nonempty track). Choose the intended track explicitly; other tracks
and any later sequence tail are excluded. Enter a unique uppercase reel, exact
source rate and start timecode for each original on that track, then confirm that
you verified those values and each video's constant frame rate. These are manual
source declarations, not automatic probe results. Changing a field or track clears
the confirmation. No zero timecode or sequence-rate default is supplied.

**Choose EDL file…** validates the entire selected track before opening the save
panel. If anything is left out, an alert lists it first, and you can export the
rest or cancel. A track that can't be written at all shows the reasons instead. The
panel shows the format/receiver limitations before saving. Export leaves the document
and undo history intact, and protects original media destinations, including
symlink and hard-link aliases. The command is remappable in shortcut Settings;
it has no assigned default shortcut. Source declarations remain local to the
sheet and are not project metadata.

## Format references and verification

The [OpenTimelineIO adapter documentation](https://opentimelineio.readthedocs.io/en/v0.15/tutorials/adapters.html)
identifies CMX3600 and SMPTE 258M as EDL interchange references.
The [Blackmagic Design Resolve reference manual](https://documents.blackmagicdesign.com/UserManuals/DaVinci_Resolve_10_Reference_Manual.pdf)
describes numbered CMX3600 events carrying reel, edit type, source in/out and record
in/out. This implementation deliberately limits the format to cuts, printable
reels and one track; it does not claim full SMPTE 258M implementation.

Run `swift test --package-path Packages/EditorCore` for exact-output, source
evidence, selected-track isolation, gaps, event limits, fractional/drop-frame,
day-wrap, channel/envelope and rejection regressions. These structural tests do
not replace native receiving-editor import qualification.
