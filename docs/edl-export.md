# Cuts-only CMX3600 EDL export

`CMX3600Exporter` exports one explicitly selected timeline track. It does not
flatten the sequence. Other picture/audio layers, linked components on other
tracks and the sequence tail beyond the selected track's last clip are excluded.
Leading and internal gaps become `BL` cut events. Source and record out points
are exclusive; timing is never rounded.

The supported subset is one picture track or one complete mono/stereo audio
track, straight cuts, unity gain and identity audio channels/routing. Fades,
paired crossfades involving the selected track, stills, multiple selected source
streams, source offsets, audio remapping and fill/unscaled geometry fail before
any EDL is returned. Default fit is a receiving-editor conform choice, not an
encoded spatial transform. EDL does not preserve raster, color, scale, layout,
track families, links, preferences or media file paths.

Supported rates are exactly 24, 24000/1001, 25, 30 and 30000/1001. Source and
sequence rates and timecode counting modes must match. Drop-frame is supported
at 30000/1001. The receiving editor must be configured to the same exact rational
rate: the `FCM` header declares counting mode, not frame rate. Labels use colons
even for drop-frame lists. Source and record endpoints, including exclusive out
points, must remain inside a single 24-hour timecode day. The exporter rejects
wraparound rather than emitting ambiguous labels.

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
includes gaps. Empty and missing tracks are rejected.

The pure core exporter never reads or writes media. The app must show the selected
track and report notes before saving and handle the resulting EDL as a track
interchange document. Native Final Cut Pro/Resolve import and media conform remain
unqualified; no rendered picture/audio equivalence is claimed.

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
panel. Unsupported edits show reasons without producing a partial EDL. The panel
shows the format/receiver limitations before saving. Export leaves the document
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
