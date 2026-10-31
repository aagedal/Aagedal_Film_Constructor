# Aagedal Film Constructor — implementation plan

Status: milestone 1 in progress. EditorCore now compiles a qualified prototype
subset of its render plan into FFmpeg, with decoded-frame/sample integration
evidence. Headless sequential MPV parity passes, but exact seeking and graph
rebuilding fail. The native FFmpeg-library fallback now passes decoded video/audio
seeks, edited-plan replacement, native image captures and AVAudioEngine offline
parity for qualified fixtures. Bounded asynchronous decoding, stale-result
rejection and exact sample-driven transport now pass the same fixtures and native
offline clock checks. Milestone 2 now has a basic assembly workspace with source
preview, media import, project documents, and linked editing. Live sequence
playback, release helper packaging and full export qualification stay
in progress. Project-bin proxies now have a scoped constant-frame-rate workflow
and source-preview switching; full proxy qualification remains open.
A scoped render workflow now has progress/cancellation, verified
publication and opt-in helper packaging; FCPXML has a validated structural subset.
This plan records the intended product and implementation order; unchecked
items remain planned capabilities.

## Current priority: usable editor (2026-10-26)

The beta assembles, previews and exports cuts. These are the remaining everyday
editing tools needed before the editor is usable for finished pieces. Each item
renders exactly in export, previews through the system backend, persists, undoes
as one step, and is refused (never dropped) by interchange exports that cannot
express it.

- [x] Picture fades and cross dissolves: linear opacity fades on video and still
  clips; dissolves between pictures meeting on one track reuse the paired
  crossfade relation on the frame grid with centred source handles. ⌘T adds a
  dissolve/crossfade (or edge fades) to the selected clip and its linked
  components. Decoded-pixel checks: `VideoTransitionRenderTests` (export, with
  `AFC_FFMPEG`) and `scripts/system-transition-smoke.sh` (preview vs export).
- [x] Titles: ⌃T adds a title at the playhead on a Titles track in front of all
  pictures. The asset stores its text and style (size, colour, position, weight,
  background band); the app draws it to a transparent PNG at the sequence raster,
  so render, preview, thumbnails, fades and interchange treat it as a still.
  Missing images are redrawn on open. Any installed font family (missing fonts fall
  back to the system font) and left/centre/right alignment. `scripts/title-smoke.sh`
  checks export and preview composite the text, fonts and alignment.
- [x] Per-clip audio volume in dB (up to +24, or silence), multiplied with track
  gain in render and preview. Selecting a picture sets its linked audio. Split,
  trim and save keep it; consolidation requires equal volumes; FCPXML, OTIO and
  EDL refuse non-unity volume.
- [x] Ripple delete (⇧⌘⌫) removes a clip with its linked components and closes the
  gap on every track; clips crossing the gap refuse it, like ripple trim. Insert (,)
  splits clips at the playhead and pushes later clips; overwrite (.) trims, splits or
  removes what lies on the destination tracks. Both use the source marks, keep
  transitions whose clips still meet, and leave the playhead after the new clip.
- [x] Picture transform: per-clip scale (1–1000%), position (fractions of the frame)
  and opacity after the scaling mode, with a picture-in-picture preset. Transformed
  pictures reveal lower layers in render and preview; split, copy and save keep it;
  interchange and stream copy refuse it. `PictureTransformTests` checks decoded export
  pixels; `scripts/system-transition-smoke.sh` compares preview and export.
- [x] Position keyframes and motion presets: picture scale and position keyframes in source
  time, linear between points (opacity stays static), with slide-in, rise, slow-zoom and
  drift presets that also animate titles. Export uses time-based `scale`/`overlay`
  expressions; the system preview uses transform ramps and the CoreImage compositor
  evaluates the same placement per frame. `TransformKeyframeTests` measures the decoded
  inset's position and size; the preview matches export at the keyframes and between.
- [x] Editorial run on real footage (2026-10-26, `scripts/story-edit.sh`): the real app cut a
  24-second film from four 4K25 H.264 drone shots: marked source ranges appended with
  ⌘E, a fade up, three dissolves with source handles, one shot at 50%, a grade on every
  shot, a rising two-line title, and a music bed faded in and out and ducked by 10 dB with
  keyframes. It played in the sequence viewer, exported a verified 600-frame 1080p H.264
  with no warnings and saved. Frames and per-second loudness of the export match the edit.
- [x] FCPXML adjustments: volume, fades, scale, position, opacity and their keyframes are
  written as `adjust-volume`, `adjust-transform` and `adjust-blend` with params; an
  adjusted fixture validates against Apple's 1.10 DTD. Import into Final Cut Pro and
  Resolve is still to be checked. Transitions, EQ, speed, colour and wipes stay refused.
- [x] Opacity keyframes: each transform keyframe carries opacity (multiplying the static
  opacity). Export scales alpha with a time-based `geq` only for such clips; the system
  preview ramps opacity through the same curve and the CoreImage compositor evaluates it
  per frame. Export pixels are checked in `OpacityKeyframeTests`; previews agree within
  3 levels.
- [x] Slide and push transitions: an optional style on the transition relation; the render
  plan turns it into keyframes on the incoming (and, for pushes, outgoing) picture, so
  export and both preview compositors animate it. Decoded export and preview agree on
  the picture split at 25%, 50% and 75% of a push.
- [x] Wipes: the incoming picture carries a reveal; export builds a sliding white-on-black
  mask and `alphamerge`s it, the system preview ramps the layer crop rectangle and the
  CoreImage compositor crops the placed picture. Export and both previews agree exactly
  at 25%, 50% and 75%.
- [x] Clip speed (10–1000%): `sourceRange.duration` stays timeline time and the clip plays
  `duration × speed` of source; splits, trims, overwrite, transition handles, volume
  keyframes and thumbnails map through the speed. Export retimes picture in a fine
  timebase and sound with pitch-preserving `atempo`; preview scales the inserted source
  with spectral pitch correction. `ClipSpeedTests` checks decoded frame numbers, exact
  sample counts and pitch; the preview matches export frame for frame.
- [x] Preview measurement fix: the smokes read preview frames in their own colour space
  (drawing into device RGB had lifted greys by up to ~13 levels).
- [x] Colour correction: per-picture brightness, contrast and saturation on encoded values
  (export: `lutyuv` in video range; preview: a CoreImage custom compositor without colour
  management, used only when a sequence has colour, which also reproduces transforms,
  opacity, fades and dissolves). Export pixels are checked in `ColorAdjustmentTests`;
  preview matches export within 5 levels (`system-transition-smoke.sh`), and real-window
  acceptance plays and exports a colour-corrected timeline.
- [x] Volume keyframes: audio clips carry source-anchored volume points (linear between
  points, held outside), multiplied with clip volume and fades. Trims and splits keep
  them on the same sound. The inspector adds a keyframe at the playhead with the volume
  field and lists, jumps to and removes them; the timeline draws the envelope. Export
  levels (`VolumeKeyframeTests`) and preview levels (`system-transition-smoke.sh`)
  measure 1 : 0.625 : 0.25 at the expected points.
- [x] Stabilise: FFmpeg deshake renders a stabilised HEVC copy of the clip's source range
  (±1 s) into Application Support; one undoable edit adds it and points the picture at it
  (`replacePictureMedia`, keyframes shifted with the source), leaving linked sound on the
  original. `scripts/stabilise-smoke.sh` measures 43% less frame-to-frame motion on shaky
  synthetic footage.
- [x] Chroma key: per-picture key colour, similarity and blend. Export runs FFmpeg
  `chromakey` on the picture's chroma before padding; the preview applies a 32³ colour cube
  built from the same formula (Rec. 709 chroma of the picture against FFmpeg's BT.601 key
  chroma) in the CoreImage compositor. `ChromaKeyTests` checks a keyed composite; preview
  matches export within 3 levels.
- [x] Levels: black point, white point and gamma per picture on RGB (export `lutrgb` between
  `gbrap` conversions; preview `CIColorMatrix`, clamp and `CIGammaAdjust`). Export greys are
  checked in `LevelsTests`; preview matches export within 4 levels.
- [x] Blur: a Gaussian blur on the fitted, frame-sized picture before placement (export
  `gblur`, preview `CIGaussianBlur` on the same canvas). Export pixels are checked in
  `BlurTests`; preview and export edge profiles agree within 18 levels.
- [x] Compressor and limiter per audio component: export runs FFmpeg `acompressor` (peak,
  hard knee, linked) after volume; the preview tap runs a Swift port that matches FFmpeg
  to within 1e-4 per sample (`AudioDynamicsTests`). The tap restores the 3 dB the system
  mixer takes from stereo before compressing and metering, so preview compression matches
  the model exactly and meters read true levels.
- [x] Linked drags: linked components follow a clip's live move or trim while dragging,
  not only after the drop. Option-dragging an edge trims that component alone
  (`trimAlone`) and keeps the link; linked trims and moves apply equal deltas, so the
  offset survives (`TimelineEditEngineTests`).
- [x] Preview gain and routing: the preview tap restores gain above 0 dB (volume ramps are
  scaled by the loudest point and the tap multiplies it back before EQ and dynamics) and
  maps a stereo stream's selected channels onto the stereo outputs as export's `pan` does,
  each selected channel with its own EQ and compressor. `system-transition-smoke.sh`
  measures +12 dB, a swap, dual mono and one channel sent right exactly.
- [x] Noise reduction: a noise-reduced copy of the component's channels (afftdn, 12 dB, noise
  floor from the quietest half second) replaces its media in one undoable edit. The smoke
  measures about 10 dB less hiss with the tone unchanged.
- [x] Three-band EQ per audio component (120 Hz low shelf, 1 kHz peak, 8 kHz high shelf,
  ±24 dB): EditorCore computes RBJ biquads; export runs them with FFmpeg `biquad`, the
  preview tap runs them per channel. Decoded export changes match the computed response
  within 0.3 dB; the preview within 0.001 dB.
- [x] Mixer panel: per-track mute, solo, gain fader and a post-fader peak meter fed by
  MTAudioProcessingTap taps on the preview's audio tracks (falling peak hold). The
  smoke checks the meter reports a known tone; acceptance checks it moves in playback.
- [x] Track mute/solo: the eye hides a video track; M mutes and S solos audio tracks.
  The render plan (preview and every export) leaves them out; collision siblings
  inherit the state.
- [x] Real-window acceptance (2026-10-26, `scripts/app-acceptance.sh … generate`): ⌘T,
  ⌃T and title editing, clip volume, insert, overwrite, ⌘C/⌘V, ⌘D and ⇧⌘⌫ pass
  alongside the beta steps; H.264 and ProRes renders of the edited timeline verify.
  It found and fixed: ⌘T failing whole-clip cuts (now a dip through black when no
  media lies beyond the cut), ⌘T refusing everything when one linked edge already had
  a transition (that edge is now left alone), and clipboard keys depending on stale
  menu focus (now routed by the keyboard router).
- [x] Cut, copy and paste (⌘X/⌘C/⌘V) and Duplicate Clip (⌘D) act on the selected clip
  and its linked components when no text field has focus. Pastes go to the original
  tracks at the playhead with new identities, stacking on siblings over occupied time.
- [x] Sequence markers (2026-10-27): M adds a marker on the playhead's frame, ⇧M/⌥M jump
  between markers and ↓/↑ between cuts on any track. Markers are flags on the ruler (click to
  edit name, note and colour in the inspector, drag to move, right-click to recolour or
  delete), are snap targets, stay at their sequence time when clips move, belong to their
  sequence and save with it. FCPXML writes them on the bed (validated against Apple's 1.10
  DTD), OTIO as stack `Marker.2` (official OTIO 0.18.1 reads and round-trips them), and track
  EDLs as `* LOC:` comments; off-frame markers, markers past the end and (EDL) non-ASCII text
  are refused. `MarkerTests` and the exporter tests cover them; real-window acceptance adds,
  names, jumps between and saves a marker and jumps between cuts.
- [x] Shortcut defaults reach customised maps (2026-10-27): acceptance found ⌫ no longer ripple
  deleted for anyone who had remapped any shortcut, because the whole map was stored and froze
  the old ⇧⌘⌫ default. Only changed shortcuts are now stored, and saved former defaults
  (⇧⌘⌫ ripple delete, ⌘⌫ delete) load as the current ones.

- [x] Live stabilisation (2026-10-28): "Analyse and stabilise" registers each frame against the
  previous one with Vision on a 480-pixel copy (plus a second each side for trims) and stores the
  content path on the clip in display-oriented frame fractions; nothing is rendered. Correction is
  the Gaussian-smoothed path (smoothing 0.1–5 s) minus the path, with automatic or manual zoom
  (100–150%) and shifts clamped so edges never show. The CoreImage compositor shifts and zooms the
  fitted picture per frame; export crops a moving window through a per-frame `sendcmd` list and
  scales it back up. Smoothing and zoom edits apply instantly. `StabilizationTests` and
  `scripts/mix-stabilise-smoke.sh` hold a jittering box still in export, and preview matches export
  within 2 pixels. The FFmpeg deshake copy stays available as an alternative.
- [x] Track and bus insert effects: six-band parametric EQ (cuts, shelves, bells), linked
  compressor and brickwall limiter (20:1 stage plus a clip at the ceiling), each bypassable and
  ordered. Export runs FFmpeg `biquad`, `acompressor link=maximum` and an `aeval` clip; the Swift
  `AudioEffectProcessor` matches them within 1e-4 per sample. Track inserts sit after the fader and
  new siblings copy them.
- [x] Buses: any number of main and submix buses per sequence (Resolve style). Tracks send to one
  or more buses, submixes feed main buses, buses have faders, mutes and inserts. Export builds the
  bus graph only when needed (a plain single main stays one `amix`); preview runs each clip's
  track and bus chains in its tap and plays the monitored main bus, chosen in the mixer. Bus
  compressors hear each clip separately in preview (noted); EQ and gains are exact.
- [x] Loudness: BS.1770-4 / EBU R 128 momentary, short-term, gated integrated loudness, LRA and
  peak per main bus in the mixer, fed by time-aligned sums of every tap's bus contribution. The
  EBU reference tone reads −23.0 LUFS (`LoudnessTests`); preview reads −20.0 LUFS on a −20 dBFS
  tone (`mix-stabilise-smoke.sh`).
- [x] Multi-track audio export: Main 1 only, every main bus, or Main 1 plus a stem per track, each
  a named audio stream that verification checks individually (`AudioBusTests`).
- [x] Video scopes (⇧⌘W): waveform, RGB parade, vectorscope with 75% targets and skin line, and
  histogram, one at a time or all four. SDR plots 0–100% of encoded Rec. 709; HDR plots
  PQ-encoded luminance (0–10 000 nits, 1.0 linear = 100 nits) with a peak-nits readout. The source
  viewer reads half-float decoded frames, so HDR media keeps its range; the sequence viewer reads
  its SDR preview.
- [x] Interchange (FCPXML, OTIO, EDL) and stream copy refuse stabilisation, track/bus effects and
  extra buses.
- [x] Interchange transitions and speed (2026-10-28): cross dissolves and crossfades are written at
  their editorial cuts using both clips' handles (`Project.interchangeCuts()`; overlapping
  crossfades are cut at the middle of the overlap). FCPXML puts a track with transitions in a
  connected storyline at offset 0 with gaps and Final Cut's Cross Dissolve and Audio Crossfade,
  keeping A/V pairs only where both sides of each transition pair; speed is a linear `timeMap`.
  OTIO writes `SMPTE_Dissolve` transitions and `LinearTimeWarp` effects; the official OTIO 0.18.1
  core reads them, and the validator checks offsets, meeting clips, handles and time scalars.
  Track EDLs write dissolve events, fades as dissolves from or to `BL`, and `M2` speed lines,
  never rounding source points off the frame grid. The FCPXML fixtures validate against Apple's
  1.10 DTD. A scripted Resolve 21 import could not run (Resolve refused every script import that
  day), so editor import of the new elements is still to be checked.
- [x] Interchange warnings instead of refusals (2026-10-28): FCPXML, OTIO and EDL exports leave out
  what a format can't carry and return grouped warnings naming the affected clips and markers
  (`ExportWarnings`); the app lists them in an alert before the save panel, with Export Anyway or
  Cancel. Effects are dropped and the clip kept; a clip that can't be placed exactly (offline,
  still, off the grid, stream offsets, unverified EDL timing) is left out, never moved; slides,
  pushes and wipes become dissolves; cross-track crossfades and transitions that lose a side
  become cuts; bad markers are left out. Exports are refused only when no file can be written
  (no exportable clips, unsupported sequence rate/layout, sequence end off the grid), and the
  refusal also lists what would have been left out.

## Earlier priority: usable beta (2026-10-23)

Prioritize everyday usability over further qualification proofs. Unqualified
sources now render or preview with visible approximations instead of refusing;
strict qualification stays available for parity work. See [the beta guide](docs/beta.md).

This checklist is the beta exit criteria. All items are complete as of 2026-10-24;
the 0.9 beta is notarized and on PR #58. The unchecked items in the later milestone
sections are version-one qualification work and are not beta criteria.

- [x] Export ProRes 422 HQ/422 MOV, H.264 MP4 and HEVC MP4 with verified frame
  counts, sample counts, codecs and timecode; name the failing check on error.
- [x] Render VFR, rotated, HDR, offset, full-range, anamorphic and long sources by
  default, reporting approximations before export.
- [x] Preview dual-mono placements, MP3, other-rate audio and boosted gain with
  notices; mute custom routing in preview instead of failing the sequence.
- [x] Convert MXF/MKV/WebM/AVI/TS and undecodable H.264 to edit-ready MOV on import.
- [x] Hold stills up to an hour; Space toggles play/pause.
- [x] `scripts/real-media-export-check.sh` checks import, preview and export of
  real files through the app code. Local iPhone HLG, screen recordings, XDCAM/AVC
  MXF, MPEG-TS, WebM, MP3/M4A and HDR MOV samples pass.
- [x] Real-window acceptance (`scripts/app-acceptance.sh`): mixed iPhone HDR,
  screen-recording, XDCAM/AVC-Intra MXF, WebM, MP3 and M4A timelines import,
  preview, play/pause with Space, open Render with ⇧⌘E and export H.264/ProRes.
  It found and fixed: a source-monitor crash (AVKit not linked), stale shortcut
  enablement and launch text focus disabling all shortcuts, sequence playback
  stopping on its own playhead echo, and off-grid clip durations making sequences
  unexportable (render now snaps edit points to the nearest frame/sample).
- [x] Real-window save/reopen: the project saves through NSDocument save-as and
  reopens with every clip and converted media linked. ⌘I opens the real Import
  panel, and Return in Render Sequence opens the real folder panel. The folder
  panel round-trips in acceptance: one-shot modal-mode timers navigate and
  confirm, the app receives the destination and starts exporting, and cancelling
  through the sheet leaves nothing behind. The save sheet opens and accepts a
  folder and name, but confirming it from a script doesn't complete, so the save
  write path is checked through NSDocument save-as. Return in the filename field now starts the
  export like the default button.
- [x] Launch: repeated launches of one Release bundle reach the first processed
  interaction in 1.61–1.74 s (`scripts/repeat-launch-timing.py`, 2026-10-23);
  fresh first launches reach a visible, loaded workspace in 1.74–1.95 s.
  Earlier that day, under heavier load, the isolated proof (a fresh unsigned bundle
  per run) measured 2.1–2.6 s for both this beta and the pre-beta commit.
- [x] Tone map HDR (HLG/PQ) sources to SDR Rec. 709 with VideoToolbox, with explicit
  rotation, and tag every export Rec. 709; verified on iPhone HLG and PQ samples.
- [x] Render 5.1 sequences (L R C LFE Ls Rs) with stereo placed front left/right
  and mono centre by default; preview monitors a stereo downmix. Verified with
  per-channel levels on rendered files.
- [x] Distribution: `scripts/release-sign-notarize.sh` signs with Developer ID
  (sandbox, hardened runtime, timestamped helpers), notarizes, staples and zips.
  The 0.9 build was accepted by the notary service and Gatekeeper reports
  "Notarized Developer ID". The signed sandboxed build passes real-window
  acceptance with bundled-FFmpeg fixtures (conversion, proxies, exports).
- [x] Interchange: DaVinci Resolve 21 imports FCPXML and OTIO exports with media
  linked, exact clip frames, source offsets and layering; its renders match the
  app's render (40–58 dB PSNR). Fixes found by this check: source timecode is now
  probed at import and used as the media clock (Resolve aborted any import that
  referenced timecoded media from zero); linked picture and sound are one A/V clip
  (Resolve ignores srcEnable); references use realpath. FCPXML now expresses audio
  channel selections (audio-channel-source), which Resolve ignores.
- [x] Final Cut Pro 11 imports the FCPXML (manual check, 2026-10-24): every clip,
  A/V link, timecode start and layer order arrive intact. Its one warning (unnamed
  sequence format) is fixed by writing Final Cut's format names; the re-import
  imports without warnings and with the same timeline.

Deferred past beta by decision on 2026-10-24: in-app stream-copy export and
sample-exact preview audio (preview keeps visible approximation notices; exports
are sample-exact and verified).

## Earlier priority: usable timeline preview (2026-10-14)

Prioritize normal-build timeline playback ahead of further assembly features.
The existing MPV exact-seek and graph-rebuild failures remain the reason to keep
MPV as a future source-viewer candidate. The native FFmpeg runtime remains the
broader sequence-engine path. The macOS 27 baseline now accommodates the local
dependency closure; redistributable attribution and distribution qualification
remain required. Explicit local Xcode Debug selection compiles and embeds it.

- [x] Enable a system AVFoundation sequence backend in ordinary Xcode builds.
  It consumes the canonical timeline render plan and existing monitor transport,
  scrub/step controls, edit invalidation and verified proxy selection.
- [x] Exercise decoded trims, upper-video precedence, reverse/repeated seeks,
  black picture gaps, live play/pause, cleanup and unsupported routing rejection.
- [x] Qualify generated ProRes/PCM, H.264/AAC and closed-GOP HEVC/AAC decoded seeks
  at 24, 24000/1001, 30000/1001 and 60000/1001; preserve rational trim boundaries.
- [x] Qualify generated same-rate mono/stereo PCM and AAC decoded audio mixes
  against FFmpeg within explicit amplitude bounds; fix initial delayed-clip gain.
- [x] Exercise generated AAC cuts one sample before/at/after an interior packet
  boundary at matching rates; reject cross-rate system audio after decoded
  resampling parity failures. AAC priming/end padding remains unqualified.
- [x] Qualify generated same-rate ALAC source boundaries; diagnose AAC source-edge
  failures and refuse MP3 after decoded trim/mix parity failures.
- [ ] Qualify broader real-world streams (open-GOP HEVC random access currently
  fails), broader compressed-audio boundaries and faithful resampling, hardware
  synchronization and signed sandbox media grants.
- [x] Compile and embed explicitly selected native playback libraries in ordinary
  Xcode Debug builds; enforce the macOS 27 baseline and clean selection removal.
- [x] Enable bounded single-frame PNG/JPEG still preview in ordinary builds,
  preserving exact holds, scaling, orientation and transparent picture layers.
- [x] Reuse nonoverlapping system picture tracks in separate still/movie pools
  and schedule visible layers from exact boundary events instead of per-cut
  full-timeline scans; preserve transparent layers and decoded cut/seek behavior.
- [x] Qualify native 16/24-bit mono/stereo ALAC at 44.1/48 kHz with exact source
  samples and packet-edge seeks, plus 48 kHz native offline sequence parity.
- [ ] Complete redistributable native runtime attribution, signing and sandbox
  qualification for explicit channel mapping, gain above unity and broader formats.

System preview currently accepts video and whole mono/stereo audio streams whose
layout and actual sample rate match the sequence, with identity routing and gain
up to unity. Audio
fades/crossfades use bounded piecewise volume ramps, so nonlinear fades are an
approximation rather than sample-exact export parity. Single-frame PNG/JPEG stills up to 4096 pixels per dimension use bounded system
preparation; unsupported selections fail visibly. Native-enabled development builds retain
the native engine. Use `scripts/system-sequence-smoke.sh /absolute/path/ffmpeg`
for generated-media checks; FFmpeg creates test fixtures only and is not required
by the system preview at runtime.

## Product direction

A focused native Swift/SwiftUI video editor with a simple workspace inspired by
Final Cut Pro and quickly toggled panels inspired by DaVinci Resolve. FFmpeg is
required for media compatibility, proxy generation, and rendered sequence export.
MPV/libmpv is the preferred broad-format source preview candidate; prove its
timeline suitability before committing to a complete playback design.
The launch target is ready to edit in less than two seconds. Expensive media
inspection, waveform generation, and optional models must load asynchronously.

The core idea is a magnetic editing experience backed by real tracks. The editor
creates additional tracks as clips overlap. Version one prioritizes assembly,
multitrack audio/video playback, and dependable export. Track identity and routing
must leave room for a future mixer and effects without requiring plugin hosting
or an effects engine in the first release.

Exclude Media Converter's download, upload, recording, batch queue, and
transcription workflows from the initial app. Reuse media infrastructure where
it fits, while keeping the new editor's document and timeline model independent.

## Version-one scope

| Workspace region | Contents |
| --- | --- |
| Top left | Project browser/bin, media metadata, right-click proxy creation. |
| Top middle | Preview monitor, transport, source/sequence timecode, hires/proxy toggle. |
| Top right | Contextual settings/inspector for clips, source audio, sequence, and export. |
| Bottom half | Full-width multitrack timeline with video, waveforms, trim/fade handles. |

Use resizable panels. Future effects and title browsers belong in the upper
workspace and should toggle quickly; reserve their placement without building
empty panels in v1.

Required v1 capabilities:

- Assemble video, audio, and still images with overlapping video/audio tracks,
  trimming, splitting, moving, undo/redo, save/open, and relinking.
- Dynamic track creation, family naming, optional empty-track removal, and
  post-insertion mono/multiple-mono/stereo/surround source selection.
- FFmpeg-backed rendered export at the selected sequence resolution, exact frame
  rate, and start timecode, with explicit audio channel mapping.
- Stream-copy export without re-encoding when the timeline and source packets
  permit it, with explicit eligibility and exact-cut checks before export.
- Project-bin proxy generation: ProRes Proxy by default, optional H.264, and a
  global hires/proxy playback toggle. Final renders use originals by default.
- Default scale-to-fit, with scale-to-fill and no-scaling choices per clip.
- Audio fade handles and crossfades, including dragging a fade handle to a second
  clip to create a linked crossfade.
- A keyboard shortcut editor with remapping, conflict detection, and defaults.
- At least one useful sequence interchange export. Proposed first target:
  FCPXML; evaluate OpenTimelineIO export as the next target.

Defer audio/video effects, title tracks, general keyframing, VST hosting, built-in
EQ/compressor/limiter, and a full bus/fader mixer until after v1. Static gain and
fade envelopes are basic editing operations and do not require a general effects
or keyframing UI. Retain the original requirement that future dynamically created
tracks copy routing and effects once those features exist.

## Dynamic track requirements

- Clips must not overwrite or block each other when moved or extended into an
  occupied region. Create another track automatically when necessary.
- Copy the originating track's available routing and static audio settings to
  the new track. Later, copy its effects as independently instantiated processors.
- When `Music` gains a sibling, display `Music 1` and `Music 2`, continuing the
  numbering as more tracks are needed.
- Remove empty tracks by default, with a setting to disable automatic removal.
- Design for conventional track mixing and effects in later releases.
- Allow changing a timeline clip's selected source audio after insertion:
  one mono stream, several mono streams, stereo, or surround from the source.
- Adapt the destination audio track to the selected channel layout, with an
  optional confirmation prompt.

## Proposed editing rules

These rules make the requested behavior deterministic. They should be validated
in an early working prototype before expanding the UI.

### Placement and magnetic editing

1. Resolve snapping, the requested start time, and any explicit ripple edit.
2. Try the target track at that time. Adjacent clip boundaries are allowed;
   intervals overlap only when their interiors intersect.
3. If it is occupied, prefer a compatible free sibling in the same track family.
4. Otherwise insert a new sibling next to the target and copy the v1 track state,
   including routing and static gain. Later copy pan/sends and ordered effects
   with fresh instance IDs and parameters copied by value.
5. Place the edited clip on the available track without moving unrelated clips
   in time merely to resolve the collision.
6. Apply automatic names and remove eligible empty tracks after the edit commits.
   Preview track creation during a drag without accumulating permanent tracks.
7. Record placement, track creation, naming, and cleanup as one undoable action.

A proposed primary video sequence supports ripple insert/delete/reorder, while
connected video and audio clips follow their explicit attachment anchors.
Collision-driven track creation is separate from ripple timing. Define which
operations ripple, and how anchors behave when a parent clip is split or deleted,
as part of the first timeline prototype.

Overlapping video also needs a defined compositing order. Initially use explicit
track order, with the upper visible clip taking precedence; preserve audio/video
sync when a linked clip is moved to another track. Video transitions are a later
feature; audio fades and crossfades are included in v1.

### Track identity, names, and cleanup

- Store a stable track ID and track-family ID independently of display names.
  Keep `Music` as the family's base name; do not repeatedly parse number suffixes.
- Automatically named siblings display `Music 1`, `Music 2`, and so on in track
  order. Proposed behavior: collapse to `Music` when one sibling remains.
- Preserve manually assigned names. Renaming a family and renaming a single track
  should be separate actions; numbering must not overwrite a custom name.
- A family is a relationship between tracks, not a hidden shared mixer. New
  tracks start with copied settings, then remain independently editable.
- Persist a family template so that removing its last empty track does not lose
  the routing/effects needed when a clip is added to that family again.
- Default `automaticallyRemoveEmptyTracks` to true. With it disabled, retain
  empty tracks and their mixer settings. Cleanup runs on committed edits rather
  than each drag update. Proposed exemptions: master/bus tracks, explicitly
  retained tracks, and (in later releases) tracks with automation that would
  otherwise be lost. Do not remove a track still referenced by a crossfade.

### Source audio selection and layout adaptation

Source audio streams and mixer tracks are different entities. A timeline clip
stores its own source selection so two uses of the same media can differ.

The inspector should list stream index, label/language where available, channel
count, and channel layout. Support selecting individual mono streams, multiple
mono streams as separately controllable components, a stereo stream, or a
surround stream. Combining mono channels into stereo/surround requires an explicit
channel mapping; selecting several mono streams must not silently guess their
speaker order. Preserve source in/out points, timeline duration, and video sync.

Store speaker positions/channel maps, not just a channel count: six channels
without known speaker labels are not automatically a known 5.1 layout.

Proposed layout-change behavior:

- If the selected clip is the only clip on the track, reconfigure the track to
  the selected layout after validating its output route. Validate effect support
  as well when effects are introduced in a later release.
- If other clips use that track, place the changed component on a compatible
  sibling or create one. Do not silently reinterpret other clips' channels.
- If several mono components become one stereo/surround component, create or
  reuse the compatible destination and remove obsolete empty component tracks
  according to the cleanup setting.
- Add an `askBeforeAudioTrackLayoutChanges` preference. When enabled, show the
  source selection and resulting track change before committing. Cancel leaves
  both source selection and track configuration unchanged.
- An output route (or a future effect/bus) may reject the new layout. Keep the
  existing edit intact and offer an explicit compatible route or downmix. Never silently drop
  channels. Future effects must retain their configuration when unsupported.
- Source selection, layout adaptation, new tracks, and cleanup form one atomic
  undoable edit. Preview playback and export must use the same channel mapping.

## FFmpeg and playback compatibility

FFmpeg handles demux/decode-dependent jobs, proxies, and final encoding. Probe
streams using existing metadata services plus FFprobe where needed. Ship a known
bundle of codecs/helpers and report its actual capabilities; do not depend on a
user-installed FFmpeg or assume every decoder has a corresponding encoder.

Use MPV/libmpv for the source viewer and evaluate it for timeline monitoring.
It supports external streams and complex libavfilter graphs, including audio
mixing, but the app must still provide timeline offsets, source ranges, clocking,
seeking, track selection, and graph invalidation. This is a proposed integration,
not proof that an existing source-player wrapper is a ready-made editing engine.
See the [MPV complex-filter documentation](https://mpv.io/manual/stable/#options-lavfi-complex).

Before substantial UI work, prototype two overlapping videos with different
source in-points, multiple selected audio streams, seek/scrub, and a crossfade.
Compare a monitored frame/audio segment against an FFmpeg render. If MPV graph
rebuilding or seeking is unsuitable, keep MPV for source viewing and use a
FFmpeg-library bridge with native rendering/audio scheduling for the sequence.
Any helper bridge may use C/C++; the application and UI remain Swift/SwiftUI.

Playback and export builds can differ even when both use FFmpeg libraries.
Maintain a format fixture matrix for import, metadata, hires preview, proxy
generation, proxy preview, and export. Allow proxy-mediated editing for formats
that can be transcoded but cannot be monitored directly, and display that status.

## Sequence settings, timecode, and scaling

- Store sequence width/height, exact rational frame rate (including fractional
  rates), audio sample rate/layout, and start timecode with explicit DF/NDF mode.
  Offer first-clip matching when creating a sequence; do not change it silently
  when another clip is imported.
- Retain source start timecode independently from the sequence start. Source
  ranges and timeline positions use exact time/frame counts; timecode strings
  are a display/interchange representation, not the arithmetic model.
- Make mixed-frame-rate conforming explicit. Define which source frame is chosen
  for each output frame and preserve audio duration; handle variable-frame-rate
  media with timestamp-aware mappings or a normalized intermediate.
- Export with exact output dimensions/frame rate and sequence start timecode.
  Use a timecode-capable output such as MOV for the baseline acceptance case;
  explain unsupported container/codec combinations before rendering. Verify
  metadata and frame counts with FFprobe rather than only checking command text.
  FFmpeg documents MOV/MP4 timecode tracks in its
  [format options](https://ffmpeg.org/ffmpeg-formats.html).
- Store `fit` (default), `fill`, or `none` per clip. Apply to stills and video:
  fit preserves the full image and pads, fill preserves aspect ratio and crops,
  none uses the oriented native dimensions centered in the sequence canvas.
  Viewer zoom is separate from clip scaling.
- Account for rotation, pixel aspect ratio, and color metadata. Proxy dimensions
  must not change the source geometry used for scaling; validate the same result
  in preview and export.

## Stream-copy export

Offer a distinct **Copy original streams (no re-encoding)** export mode when
feasible. This preserves encoded media quality while remuxing packets; it does
not promise an identical container file. Assess video and audio independently,
so copying video while rendering edited audio is possible when timing/container
compatibility is validated. Clearly label which streams are copied or encoded.

Start with one source range, then qualify contiguous cuts-only sequences of
compatible sources. Eligibility requires probed codecs/codec parameters, raster,
pixel format/color, exact timing, audio layout/sample rate, container support,
and packet/random-access boundaries. A matching codec name alone is insufficient.
Do not conform copied video to a different sequence frame rate or raster.
Reject copying any stream needing compositing, generated gaps, scaling,
transitions, filters, speed changes, audio mixing, gain/fades, or sample-channel
remapping. Selecting whole original audio streams can remain copyable.

For interframe codecs, exact trim starts require independently decodable random
access points and valid dependencies at the outgoing boundary; an arbitrary
keyframe flag is not sufficient for every open-GOP source. Audio cuts must respect
packet framing, codec delay/padding, and container edit support. Intra-frame media
may allow more cut points, but still needs timing validation. FFmpeg documents
that input seeking can preserve preroll when copying rather than discard it.
See [streamcopy and seeking](https://ffmpeg.org/ffmpeg.html#Streamcopy).

Never silently shift cuts or change sequence duration to permit copying. Show
reasons when exact copying is unavailable, and offer rendered export or an
explicit, previewable adjustment to safe cut boundaries. Re-encoding boundary
GOPs while copying interiors is a later smart-render experiment, not a promise
of entirely unencoded export. Preserve source originals and validate timestamps,
A/V sync, decoded first/last frames, duration, and packet payload hashes (allowing
documented container-required bitstream transformations). Test ProRes/PCM,
closed/open-GOP H.264/HEVC, and compressed audio before declaring support.

The current render-plan compiler always encodes ProRes/PCM. Stream-copy needs
additional codec/packet metadata and its own compiler path; it must bypass the
filter graph rather than attach `-c copy` to filtered outputs.

## Proxies

- In the project bin, right-click one or several items to create proxies. Default
  to ProRes Proxy in MOV; offer H.264 as an alternative. Choose proxy resolution
  in the creation dialog, with a proposed half-resolution default.
- Reuse FFmpeg process/progress infrastructure. Its ProRes encoder supports the
  [Proxy profile](https://ffmpeg.org/ffmpeg-codecs.html#ProRes); do not copy Media
  Converter's different default proxy codec unchanged.
- Track proxy identity, preset, status, source fingerprint, and timeline mapping
  on the media asset. Preserve frame correspondence, duration, source timecode,
  orientation/aspect ratio, and all audio stream selections. Keep audio on the
  original source if a proxy container/codec cannot preserve its organization.
- A global hires/proxy toggle changes playback representation, never source
  identity, edits, source ranges, or sequence settings. Missing/stale proxies
  fall back to originals with visible status. Switching must preserve playhead.
- For VFR or unusual sources, validate the mapping explicitly; reject a proxy
  that cannot represent edits faithfully rather than guessing frame offsets.
- Generation is asynchronous, cancellable, and resumable per asset, with bounded
  concurrency. Keep existing proxies usable until replacements finish. Originals
  are retained; partial output is not registered as a valid proxy.
- Final export and interchange reference originals by default. Missing originals
  require relinking or an explicit proxy-resolution export choice.

## Audio fades and crossfades

- Show fade-in/out handles on audio clip components. Store duration and curve
  independently from future generic effect/keyframe data. Clamp fades to usable
  media and keep all selected channels synchronized.
- Drag a fade handle to another compatible audio component to create a paired
  crossfade. Use their overlap when present. At an adjacent cut, extend into
  available source handles without changing sequence duration; shorten or refuse
  the transition when there is insufficient source media.
- Crossfades may span dynamically created sibling tracks. Validate layout/channel
  compatibility, make duration/curve editable, and keep the relation coherent
  during move, trim, split, delete, cleanup, and undo.
- Proposed defaults: equal-power crossfade, linear standalone fades. Let users
  select another curve. Correlated audio may peak during a crossfade; do not add
  a hidden limiter or automatic loudness normalization.
- Preview and export evaluate the same envelopes at the audio sample clock.
  FFmpeg has [fade, crossfade, and mixing filters](https://ffmpeg.org/ffmpeg-filters.html),
  but compile them around absolute timeline placement; a sequential crossfade
  operation must not accidentally shorten an already overlapped sequence.

## Sequence interchange

Keep the native project document independent of interchange adapters so dynamic
track families, proxy links, and preferences remain recoverable on save/open.

Proposed v1 order: FCPXML sequence export first, then OpenTimelineIO export if it
fits the release. FCPXML is concrete XML interchange and has locally tested helper
code. FCP7 XMEML is a distinct target for Premiere-style workflows, not a synonym
for FCPXML. Import/round-trip editing is a later milestone.

Export source media references, source in/out, timeline offsets, gaps, multiple
audio/video tracks, source stream/channel selections where supported, sequence
dimensions/rate/start timecode, scaling, and audio fades. Validate with the
destination application's native import, and report any feature the adapter
cannot represent rather than silently flattening or omitting it.

OpenTimelineIO represents layered tracks, clips, gaps, transitions, and a global
start time in its [canonical structure](https://opentimelineio.readthedocs.io/en/latest/tutorials/architecture.html).
Evaluate its [official C++ core](https://github.com/AcademySoftwareFoundation/OpenTimelineIO)
through a small Swift bridge before choosing a writer. Its
[format specification](https://opentimelineio.readthedocs.io/en/latest/tutorials/otio-file-format-specification.html)
recommends using the library. Avoid shipping a Python runtime solely for adapters.
Custom metadata can retain app-specific routing/fades, but other apps may not
apply it; define a supported subset and validate with the official library.

EDL is a limited fallback. Media Player's existing Resolve EDL exports markers,
not an assembled sequence. Reuse timecode/escaping/validation helpers while
writing a new edit-event exporter if needed. The requested interchange candidates
are EDL, XML, and OpenTimelineIO. Define EDL's supported
cuts-only subset and source/record timecode mappings. Offer per-track EDLs or an
explicit flattened cut list when needed, explaining what happens to overlapping
layers and audio. Do not promise a lossless multitrack timeline through EDL.

## Architecture

Start with a macOS editor. The application now targets macOS 27 and later (baseline updated 2026-10-14). The project file remains in
the Xcode 27 format inherited from the recovered starter; building the app
requires a compatible Xcode, while the standalone core uses Swift 6.

Keep a UI-independent editor core, preferably a local Swift package so timeline
logic can be tested without launching the app:

- `ProjectDocument`: versioned persistence, media references, sequences, and
  document-level undo/save behavior.
- `MediaAsset`: stable identity, security-scoped bookmark, metadata, and available
  video/audio streams, source timecode, geometry, and original/proxy representations.
  Missing media must remain relinkable.
- `TimelineClip`: source range, rational timeline time, linked components,
  attachment anchors, scaling mode, fades, and per-instance source audio selection.
- `TimelineTrack` / `TrackFamily`: stable IDs, display naming, layout, mixer
  configuration, and retained family templates. Effect hosting is deferred.
- `SequenceSettings`: exact raster/rate, start timecode, and audio output format.
- `AudioCrossfade`: paired components, duration/curve, and source handle constraints.
- `EditCommand` / `TimelineEditEngine`: validated placement, trim, split, ripple,
  collision resolution, and transactional undo/redo.
- `TimelineRenderPlan`: canonical source ranges, absolute positions, layer order,
  scaling, channel maps, and fade envelopes shared by preview and export.
- `PlaybackEngine`: decode/cache/schedule from that plan, resolving hires/proxies.
- `AudioGraph`: v1 channel maps, static gain, fades/mixing, and output layout;
  add processing, buses, and plugin hosting later.
- `ProxyService`: generation queue, validation, representation links, and relinking.
- `ExportService`: compile the render plan into FFmpeg processing and encoding.
- `InterchangeExporter`: compile the document to a validated target format.
- `EditorCommandRegistry`: stable action IDs, menu/timeline command dispatch,
  shortcut scopes, editable bindings, conflict detection, and reset-to-defaults.

Keyboard remapping must apply consistently to menus and the editor. Respect text
entry, application/system-reserved combinations, and focused-panel contexts.

Use integer/rational media time rather than accumulating floating-point seconds.
Separate UI drag previews from committed document edits. Media services should
operate asynchronously, with cancellation and bounded caches. Persist references
and configurations rather than player objects or effect runtime instances.

## Media Converter reuse audit

The following files exist in the local `Aagedal-Media-Converter` checkout. Paths
below are relative to its `Aagedal Media Converter/` source directory. Audit
dependencies and preserve licensing/attribution before extracting code.

| Area | Existing code | Reuse approach |
| --- | --- | --- |
| Sandboxed file access | `Utils/SecurityScopedBookmarkManager.swift` | Reuse bookmark resolution and balanced access leases behind a media-access service. |
| Helper processes | `Utils/SubprocessRunner.swift` | Reuse cancellation and process handling for probing/export; keep helper paths bundle-based. |
| Media metadata | `Logic/VideoMetadataService.swift` and SwiftMediaMetadata dependency | Adapt to editor assets instead of conversion queue items; enumerate source streams once. |
| Audio selection/export mapping | `Logic/AudioRoutingModels.swift`, `Logic/Conversion/AudioRoutingService.swift` | Reuse mapping and validation ideas; separate source components from timeline tracks and real-time mixing. |
| Filmstrips and waveforms | `Logic/Previews/PreviewAssetGenerator.swift`, `Logic/Previews/NativeWaveformRenderer.swift` | Extract reusable cache/rendering services with per-channel support where needed. |
| Preview playback | `Logic/TrimPlayer/PreviewPlayerController.swift`, `Logic/MPV/MPVPlayer.swift` | Reuse source playback/decoder abstractions after untangling UI/settings; neither is a complete multitrack compositor. |
| Timeline edits and undo | `UI/VideoQueueViews/StitchingEditorView.swift` (`StitchingTimeline`, `StitchingEditHistory`) | Port useful algorithms and regression cases; build a new multitrack model rather than importing this queue-based view. |
| Timecode | `Utils/TimecodeFormatter.swift`, `Logic/Conversion/StitchMarkerTimecodeRate.swift` | Reuse formatting/rate handling after checking rational-time and drop-frame behavior. |
| Export progress | `Logic/Conversion/FFMPEGProgressParser.swift` | Reuse progress parsing and selected process lifecycle code; create a dedicated timeline render plan instead of importing the converter's entire command builder. |

Do not import the entire converter app or its binaries as a first step. Keep
dependencies small and load optional decoding/export tools when needed.

Useful existing tests to adapt include `SecurityScopedBookmarkManagerTests.swift`,
`MetadataScopeLifecycleTests.swift`, `AudioRoutingPlanTests.swift`,
`StitchingTimelineTests.swift`, and `StitchMarkerExportTests.swift`. Existing audio
routing plans handle a single input and source playback picks one stream at a
time; simultaneous clips, buses, effects, and arbitrary mono-to-surround mapping
require editor-specific work.

## Media Player reuse audit

Paths below are relative to the local `Aagedal-Media-Player` checkout:

| Existing code | Reuse and limits |
| --- | --- |
| `Aagedal Media Player/UI/TimecodeFormatter.swift` | Exact frame-count/rational rate and DF/NDF formatting; extract with its boundary tests. |
| `Aagedal Media Player/Logic/CompareReviewReportExporter.swift` | Rational XML time, escaping, source timecode/raster handling, and export validation. Resolve EDL is review markers; FCPXML is one browser asset with markers; XMEML is a one-source review sequence. None is the required general multitrack exporter. |
| `Aagedal Media Player/Logic/ExportCommandBuilder.swift` | Inspect format/timecode command construction; adapt selected helpers to a canonical timeline render plan. |
| `Aagedal Media Player/Logic/AudioChannelRouting.swift` | Reuse known speaker roles and monitoring channel-map ideas; the current helper monitors a single audio stream rather than a timeline mix. |
| `Aagedal Media Player Tests/TimecodeFormatterTests.swift`, `CompareReviewReportExporterTests.swift` | Reuse DF boundaries, overflow, fractional rates, XML safety, and geometry regression cases. |
| `docs/evidence/` editor-import fixtures | Use existing native conform evidence when designing new sequence-export tests; do not assume marker round trips prove sequence fidelity. |

Inspect other open-source editors for scheduling, transition, proxy, and interchange
ideas where useful. Prefer small proven library integrations and algorithms over
porting another application's UI/framework. Keep license notices for reused code.

Do not inherit silent frame-rate fallback or unsupported DF-to-NDF coercion from
existing helper constructors. Validate sequence settings explicitly. Preserve
unwrapped positions/durations separately from timecode's 24-hour display wrap,
and use exact probe fractions as timing authority rather than rounded metadata
rates. Track stable container stream indices and per-stream timing offsets.

## Implementation milestones

### 0. Repository repair and baseline

- [x] Join the Xcode initial commit and GitHub history without rewriting either.
- [x] Keep one `origin` remote at the supplied GitHub URL; configure `main` upstream.
- [x] Stop tracking personal `xcuserdata`; preserve the original local settings.
- [x] Verify the original app builds for macOS.
- [x] Record the workflow and reuse audit in this plan.

### 1. Timeline core and media-engine proof — first implementation

- [x] Add rational time, validated sequence settings, tracks/families, stable
      source stream identities, clip ranges, scaling modes, and a render plan.
- [x] Implement move/trim/split/placement, sibling naming, cleanup, and undo/redo.
- [x] Bundle/audit FFmpeg and prototype MPV-based source/timeline monitoring.
      Pinned signed FFmpeg/FFprobe 9.0.2 are bundled automatically; MPV proofs
      are retained under docs/evidence.
- [ ] Render a minimal sequence with two overlapping videos and several audio
      components at different source in-points. Verify seeking and preview/export
      agreement before selecting the final playback path.
- [x] Prototype the native FFmpeg-library fallback after MPV seek failure; verify
      exact frame/sample requests, forward/backward seeks, decoder rebuilding,
      edited-plan invalidation and native offline output against rendered fixtures.
- [x] Add bounded asynchronous decoder requests, shared decoded-payload caching,
      cancellation and stale seek/edit rejection; verify exact transport against
      the native offline sample clock and independent frame/sample renders.
- [x] Qualify bounded native video fit/fill/none against decoded spatial fixtures,
      including odd rasters, seek/rebuild and primed plan replacement.
- [x] Qualify single-frame PNG/JPEG native stills, transparent PNG composition,
      fit/fill/none, synthetic source trims, seeks and primed plan replacement.
- [x] Add standalone live monitor observations and scripted transport checks;
      handle startup preroll and pause safely on audio configuration changes.
      Acoustic/display synchronization and shipping integration remain open.
- [x] Preserve the last accepted position on underrun, support explicit restart,
      cancel priming across lifecycle changes and release abandoned monitors;
      qualify these policies with injected output clocks and cancellation tests.
- [x] Bound retained native source decoders with configurable LRU context/decoded
      source byte limits; qualify eviction/reopen using PNG and PCM sources.
- [x] Preserve exact edit duration when sample-aligned audio ends between video
      frames; qualify final-frame coverage, final-sample seeks and offline clock
      parity with rendered output.
- [x] Test adjacency, multiple overlaps, free siblings, custom names, failed edit
      rollback, exact fractional rates, DF boundaries, and preserved audio sync.

Implemented foundation: `Packages/EditorCore` contains exact checked rational
arithmetic, DF/NDF formatting, validated project decoding, explicit source channel
selection and stream offsets, ordered render components, and non-ripple edit
commands. Linked components move/trim/split/delete transactionally. Split refuses
a cut outside any linked component rather than breaking sync. Family templates
survive cleanup; retained tracks and custom names are respected. The app's small
synthetic example demonstrates an extension creating a sibling and undo/redo.

This is not the complete playback model: source geometry/color, proxy
mappings, live playback and ripple/attachment rules remain work for the
relevant milestones. The development FFmpeg compiler now
handles frame-aligned video layers and sample-aligned explicitly routed audio;
it is not yet a production export service. See
[the media-engine audit](docs/media-engine-audit.md) for artifact evidence and the
standalone FFmpeg smoke proof. Headless sequential MPV parity passes for the
qualified fixture, but exact seeking and graph rebuilding fail. The native fallback
passes four frame/sample parity fixtures, including H.264 B-frames, video gaps,
overlapping audio and replacement of a primed playback plan. It uses native
CGImage captures and AVAudioEngine offline scheduling. Real-time monitoring
remains unqualified; no media helpers have been bundled.

Completion example: extending a `Music` clip creates `Music 1` and `Music 2`
with copied routing/static settings; undo restores the original state. A fixture
sequence previews and renders at the same positions with exact output timing.

### 2. Native workspace, persistence, and shortcuts

- [x] Build the top-left bin, middle source monitor, top-right inspector, and
      full-width timeline with resizable panels.
- [x] Add persistent nested media bins, batch organization, captured import
      destinations and undoable rename/move/removal that preserves media.
- [x] Launch directly into an untitled drop-ready workspace while retaining native
      document open/save/autosave behavior.
- [x] Suggest first saving edited untitled work after approximately five minutes;
      keep bounded, automatic recoverable snapshots for saved projects.
- [x] Add persistent panel visibility controls in the toolbar and View menu.
- [x] Add compact track/family naming, retained-empty-track controls and undoable
      static audio gain with shared monitor/render planning and inherited siblings.
- [x] Add edited-sequence monitoring. Ordinary builds use the AVFoundation
      sequence backend; verified in the real window by `scripts/app-acceptance.sh`.
- [x] Connect Source/Sequence monitor selection, edited-plan rebuilding, coalesced
      scrubs and K/L transport to the native runtime in an opt-in development
      workspace; qualify real controller pixels and live sample-clock progress.
      Default builds remain explicitly unavailable until runtime packaging.
- [x] Add sandboxed AVFoundation import, versioned project save/open, native
      DocumentGroup autosave, validated relinking, and basic sequence setup.
- [x] Connect horizontal drag/move, inspector trim, split/delete, selection, and
      atomic linked-component undo/redo; video edits snap to sequence frames.
- [x] Add per-source In/Out working marks, exact qualified CFR snapping,
      source-scoped remappable I/O shortcuts and atomic range append for linked
      picture/audio including explicit channel selection.
- [x] Add linked drag trim handles, adjacency snapping, frame stepping, and
      sequence/start timecode controls.
- [x] Expose lossless rational frame-rate entry/presets and sequence audio output
      rate/layout with atomic timecode application, route validation and undo.
- [x] Offer explicit first-picture source matching before timeline placement for
      qualified square-pixel, unrotated CFR video streams; persist exact source
      dimensions/cadence and preserve audio settings/timecode with atomic undo.
      Broad-format, orientation and VFR matching remain open.
- [x] Add live sequence transport. Space/K/L play and pause the sequence with an
      advancing playhead in the real window (playhead echo regression fixed).
- [x] Add asynchronous filmstrips/waveforms and fit/fill/no-scaling controls.
      Scaling is persisted; sequence preview/render geometry remains unqualified.
- [x] Expose the automatic empty-track cleanup preference.
- [x] Expose layout-confirmation preferences with the source-layout workflow.
- [x] Add a command registry and keyboard shortcut editor with conflict checks,
      focus-aware dispatch, persistence, and reset-to-defaults.

Completion example: edit overlapping clips, change scaling, customize a shortcut,
and save/reopen without losing placements, preferences, or source identity.

### 3. Audio components, fades, and crossfades

- [x] Support initial and post-insertion mono, multiple mono, stereo, and surround selection
      on a selected component, including explicit consolidation of aligned linked
      components with matching source, track family, and gain.
- [x] Implement explicit channel maps and compatible track layout adaptation.
- [x] Add standalone audio fade handles, inspector durations/curves, persistence,
      atomic undo/redo, trim clamping and envelope-preserving split rules.
- [x] Qualify standalone linear/equal-power fades, including overlapping edges,
      fractional durations, seeks and edited-plan replacement in development
      FFmpeg/native sample-parity fixtures.
- [x] Add linked crossfades, including drag-to-second-clip creation.
- [x] Handle insufficient source handles, adjacent cuts, overlapping siblings,
      layout compatibility, subsequent trims/moves, cancellation, and atomic undo.
- [ ] Validate output layout and monitor/render the same sample-timed mix.

Completion example: switch two mono components to the source's 5.1 stream, obtain
a compatible track, create a crossfade, and undo both operations without lost sync.

### 4. Project-bin proxy workflow

- [x] Add batch right-click proxy creation with ProRes Proxy default and H.264 option
      for the qualified constant-frame-rate video subset.
- [x] Implement progress/cancel, bounded jobs and atomic verified registration,
      retaining prior proxies until replacement succeeds.
- [x] Add explicit proxy relinking with recorded byte identity and atomic grants/history.
- [x] Add a persisted, manually resumable proxy job queue with source validation,
      cancellation, interrupted-publication recovery and destination-conflict handling.
- [x] Add a document-session hires/proxy source-preview toggle with
      missing/stale-proxy status and fallback. Qualified native sequence switching
      is connected in the opt-in development workspace.
- [ ] Test frame/timecode correspondence, geometry, multiple audio streams, VFR
      mapping, switching at a nonzero playhead, and save/reopen.
- [x] Verify proxy playback does not change edits and final exports use originals.
      Core tests compare original/proxy render commands; real-window acceptance
      plays with Prefer Proxy and renders from originals (warnings name originals).
- [x] Connect the global representation preference to opt-in native sequence
      playback with integrity verification, original geometry/audio, nonzero
      playhead preservation and cancellable rebuilds. Shipping runtime and
      broader format/hardware qualification remain open.
- [x] Compare reopened native hires/proxy frames, timestamp-aligned mono/stereo
      PCM including delayed edits/tails, nonzero switching beyond proxy picture,
      and unchanged original-only render commands within the qualified subset.

The scoped workflow preserves original edit coordinates and keeps original audio
in source preview. Proxy references and independent sandbox bookmarks persist
and are restored by undo/redo. Original relinking clears derived references
atomically; missing proxies can be regenerated. See [proxy scope](docs/proxies.md)
for timestamp/raster qualification, probe limits, metadata fingerprints and
remaining signed/native playback checks.

### 5. Sequence export and interchange

- [x] Implement FFmpeg sequence render with correct raster, rational frame rate,
      start timecode, compositing order, scaling, audio selections, and fades.
      ProRes 422 HQ/422, H.264 and HEVC with verified counts, codecs and timecode;
      mono/stereo/5.1, HDR tone mapping and edit-point snapping (2026-10-23).
- [x] Add a fixed MOV/ProRes HQ/PCM development workflow using sequence output
      settings and timecode, progress, cancellation and verified publication.
      Additional output presets and full source/container qualification remain open.
- [x] Qualify zero-origin CFR source timestamps through bounded full decoded-frame
      scans, including misleading average/nominal rate metadata, while preserving
      mixed CFR rates, differing rasters and audio resampling.
- [ ] Add stream-copy eligibility using codec/packet metadata; qualify exact
      single-source trims, compatible cuts-only concatenation, and video-copy /
      audio-render export, with clear reasons and no silent boundary shifts.
- [x] Add a pure, conservative single-range assessment with separate picture/audio
      reasons and an explicit source/range/container packet-evidence contract.
      Producing that evidence and performing qualified copy exports remain open.
- [x] Add a separate development ProRes HQ/PCM MOV range verifier with exact packet
      cuts, payload/timestamp comparisons, isolated boundary decoding and decoded
      frame/sample/timecode qualification. App export integration remains open.
- [x] Extend that verifier to exact two-to-four-range compatible cuts-only joins
      and DF timecode at 30000/1001 and 60000/1001, checking every joined packet,
      decoded frame/sample and independent cut-boundary decoding. This remains a
      development proof without importer-connected app eligibility/export.
- [ ] Verify copied packet payloads, decoded boundary frames, timestamps, duration,
      timecode, and A/V sync across supported containers/codecs.
- [ ] Verify outputs using FFprobe, decoded frame checks, channel identification
      audio fixtures, and native-player/editor import at integer/fractional rates.
- [x] Verify decoded CFR frame identities/timestamps, stereo channel routes/sample
      counts and MOV timecode packets at 24, 24000/1001, 30000/1001 DF and
      60000/1001 DF. Native receiver and broader source acceptance remain open.
- [x] Add FCPXML sequence export and validate real layered-video/audio imports.
      Verified in DaVinci Resolve 21 (scripted import, exact timing and layers);
      Final Cut Pro import remains unverified.
- [x] Evaluate OTIO export using its official core/validator; document its subset.
      Layered cuts/gaps pass official core read/write and timing qualification;
      receiving-editor import and spatial conform remain unqualified.
- [x] Define and implement a conservative selected-track cuts-only CMX3600 EDL
      exporter with explicit source timing declarations, exact source/record
      timecode and no flattening. Native receiver conform remains unqualified.

V1 requires rendered export plus one validated sequence interchange target; it
does not require implementing every proposed interchange adapter.

### 6. Version-one acceptance and performance

- [x] Exercise mixed-format media, multiple overlapping video/audio tracks,
      source audio changes, fades, proxies, relinking, and customized shortcuts.
      `scripts/app-acceptance.sh` passes all 15 real-window checks (2026-10-23)
      with iPhone HLG, XDCAM MXF, HEVC, WebM and MP3 media: overlapping sibling
      tracks, fades and a linked crossfade, multitrack source-stream changes,
      relinking, ProRes proxies with Prefer Proxy playback, a remapped Play/Pause
      key, Tab/Space/⇧⌘E key events, verified H.264/ProRes renders and save/reopen.
- [ ] Check preview/export parity, deterministic frame counts, start timecode,
      dropped/duplicated conform frames, geometry, channel maps, and audio sync.
- [x] Measure launch-to-interaction against the two-second target in Release builds.
  Repeat launches 1.61–1.74 s to interaction; fresh first launches 1.74–1.95 s to a
  visible loaded workspace (2026-10-23, unsigned local build). See
  [launch performance](docs/release-launch-performance.md).
- [x] Add opt-in actual Release workspace/input instrumentation and isolated launch
      measurement. Local fresh-preference/warm-cache evidence passes; cold launch,
      populated projects and signed distribution acceptance remain open.
- [ ] Profile large projects; bound caches and keep import/generation off the UI thread.
- [x] Add reproducible synthetic 5,000/10,000-clip profiling, remove quadratic
      overlap and repeated asset/crossfade scans, and cache workspace derived
      lookups across transport updates. Full app/media/launch profiling remains open.
- [x] Bound timeline preview metadata/decode admission, cancel queued requests
      without polling, release hidden previews and serialize bounded still
      source thumbnails off the main actor. Full project profiling remains open.
- [x] Cull offscreen timeline clip views using viewport geometry while preserving
      scroll extents, selected clips and active gestures; measure a 3,000-clip
      offline Release project below two seconds in five local warm-cache runs.
- [x] Replace per-cut full-picture scans with exact event/heap scheduling and
      reuse nonoverlapping system picture tracks in separate still/movie pools.
      Synthetic scheduling and decoded reuse checks pass; full preparation and
      large-project live playback profiling remain open.

### After version one

- Audio/video effects, title browsers and title tracks, and general keyframing.
- Built-in EQ, compressor, limiter, and a fuller mixer with buses and faders.
- VST audio plugin hosting, capability checks, saved state, and offline rendering.
  Evaluate a native SDK bridge; do not assume it is a pure Swift package or
  automatically interchangeable with Audio Units.
- When effects arrive, dynamic siblings copy settings/routing while instantiating
  independent processors. Extend undo/persistence and preview/export parity tests.
- Additional interchange adapters/import, transitions, and optional classification.

## Decisions to validate during prototyping

- Exact ripple and attachment behavior, particularly when parents are split/deleted.
- Whether surviving automatic names collapse to their base name after cleanup.
- How users retain empty tracks containing intentional routing/static state, and
  later mixer automation.
- Default state of the optional layout-change confirmation setting.
- Surround output/downmix policy when monitoring hardware has fewer channels.
- MPV timeline graph viability versus a dedicated FFmpeg-backed sequence engine.
  The unchanged canonical export graph passed sequential capture but failed
  exact later/backward seeks and rebuilding. FFmpeg-library exact frame/sample
  selection and native offline output now pass qualified fixtures. Continue with
  this native sequence-engine direction, qualify live display/audio clocking and
  packaging next, and retain MPV as a source-viewer candidate.
- Mixed-frame-rate/VFR conform policy and proxy resolution/storage defaults.
- Crossfade geometry at adjacent cuts and curve choices when audio is correlated.
- First interchange target's native round-trip fidelity and explicit EDL subset.
- Long-term VST version/SDK choice, plugin isolation, and offline-rendering parity.
- Manual family assignment first; optional automatic audio classification later.

## Baseline verification

The recovered starter builds with Xcode 27 using:

```sh
xcodebuild -project "Aagedal Film Constructor.xcodeproj" \
  -scheme "Aagedal Film Constructor" -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/aagedal-film-constructor-derived-data \
  CODE_SIGNING_ALLOWED=NO build
```

This checks the starter's compilation only. No editor functionality or
launch-performance claim has been validated yet.


### First implementation verification (2026-10-09)

- Standalone EditorCore suite: 16 tests passed (10 edit-engine XCTest cases and
  6 model Swift Testing cases).
- macOS Debug app build: passed with Xcode 27, signing disabled. This proves
  package integration and compilation, not GUI interaction or macOS 14 runtime
  compatibility; the build was run on the current development machine.
- Development FFmpeg proof: decoded 180 frames at 30000/1001 and 288,288 audio
  samples per channel, with layer colors, channel routing, fade amplitudes, and
  MOV timecode checked. See the audit for limitations and reproduction.

### Render-plan compiler verification (2026-10-09)

- Core suite: 25 tests pass; unsigned macOS Debug build passes with Xcode 27.
  Tests include fractional collision/linked-sync cases,
  rollback after sibling creation, custom names, and compiler rejection cases.
- New `scripts/render-plan-proof.py` compiles a persisted fixture project through
  EditorCore, executes the emitted argument array, and decodes its actual output.
  It passes 180 frames at 30000/1001, 288,288 stereo samples, MOV DF timecode,
  exact layer cut boundaries, distinct source frame identities, swapped mono
  stream routing, static gain, and exact silence boundaries.
- Preview/export parity is still unchecked: the proof has no MPV monitor.
  Helper packaging, source geometry/color, VFR, nonzero stream offsets, stills,
  fades, process cancellation/progress, and native interchange remain open.

### MPV canonical-graph experiment (2026-10-09)

- Added an experimental `MPVRenderCompiler` adapter that uses the exact FFmpeg
  export graph, explicit file/stream-to-MPV track bindings, and split/asplit for
  repeated source use. It does not assume container stream indices are MPV IDs.
- The persisted render fixture now emits `mpv-command.json`; the development
  runner records MPV capabilities and actual graph initialization/playback.
- The local MPV 0.41.0-dirty / FFmpeg n8.1.2 build cannot initialize this graph.
  Its build disables required filters including asetpts, adelay, anullsrc, pad,
  and setsar. This is a package capability failure, not a completed parity or
  seek test. Select/build a filter-enabled candidate before evaluating timeline
  seeking; keep the milestone unchecked. See the media-engine audit for evidence.

### Runtime MPV parity and seeking verification (2026-10-09)

- Added strict runtime `track-list` resolution by file, kind, and `ff-index`,
  requiring libavformat demuxing. Missing/ambiguous identities fail explicitly;
  repeated stream use resolves once and retains split/asplit behavior.
- Added a reproducible development headless MPV build using local source and
  installed full FFmpeg libraries, with per-file source hashes and build commands.
  It is dynamically linked to Homebrew and is not a shipping package.
- Replaced potentially colliding frame colors with binary frame/source barcodes.
  MPV sequential capture matches all 180 frames and 288,288 stereo samples;
  maximum frame mean RGB error is 1.8 and maximum PCM sample error is 1.
- Exact seek checks pass at frames 0, 2, and 3, but fail at 60, 119, 120, 179,
  backward 60/15, and rebuilding at 15. Reported time positions are accurate;
  displayed pixels differ by 58.7–154.2 (tolerance 12). Do not use this unchanged
  graph as the interactive timeline engine. Evaluate the native fallback next.
- 33 core tests and 5 IPC tests pass; unsigned macOS Debug app build passes.
  Audio seeks, native display/CoreAudio, crossfades, helper packaging, and the
  full workspace remain unqualified. Milestone 1 remains in progress.
- Reproduction and retained results: [media-engine audit](docs/media-engine-audit.md#runtime-track-resolution-sequential-parity-and-seek-failure-2026-10-09).

### Native sequence fallback verification (2026-10-09)

- Added exact `NativePlaybackPlan` frame and sample-block requests with 14 tests
  for layer/cut/gap boundaries, fractional counts, explicit stream/channel routes,
  overlapping audio, stateless seeks, invalid models and overflow.
- Added a separate development FFmpeg C bridge with exact timestamp qualification,
  backward seek/flush/forward decode, RGB output and matching-rate PCM extraction.
  The app does not link local development libraries.
- Four fixtures pass all 180 frames and 288,288 stereo samples each, plus ten
  video and eight audio seeks each. They cover original barcodes, gaps, overlapping
  audio, H.264 B-frames and replacement of a primed plan with changed edits.
  CGImage/PNG captures and AVAudioEngine offline output match independent exports.
  Maximum RGB error is 2.0 (tolerance <12); audio error is 0.75 s16 units (limit 1).
- A reproducible direct decoder matrix passes 65 ASan/UBSan checks, including
  four-channel PCM and explicit rejection of unsupported timing/geometry/audio.
- 47 core tests, 9 Python tests and the unsigned macOS Debug build pass.
- Continue the native sequence-engine direction. Full-stream initial qualification
  is development behavior; live output/clocking, asynchronous caching/cancellation,
  crossfades, format/rate/geometry coverage and macOS 14-compatible shipping
  dependencies remain open. Milestone 1 remains in progress.
- Reproduction and evidence: [native media-engine audit](docs/media-engine-audit.md#native-sequence-fallback-proof-2026-10-09).


### Asynchronous native playback verification (2026-10-11)

- Added exact sample-driven play/pause/seek transport with seven tests covering
  fractional anchors, frame boundaries, stale clock callbacks, monotonic counts,
  exact-end clamping, replacement and checked failure rollback.
- Extracted the development decoder/output into `NativePlaybackRuntime`. A
  serial worker keeps media I/O off the caller executor; its actor session bounds
  pending requests and shares a byte-limited LRU across video/audio. Seek/edit
  epochs invalidate queued work and prevent stale results from entering the cache
  or being accepted for presentation. Cleanup jobs are coalesced.
- Nine runtime tests cover cancellation during decode/initialization, saturated
  admission, queued read rejection, repeated replacements, close, rejected edits,
  invalid requests and mixed-cache eviction. A running FFmpeg call cannot yet be
  interrupted; cancellation skips pending calls and discards obsolete output.
- 54 EditorCore tests, nine runtime tests, nine Python tests and the unsigned
  macOS Debug app build pass. The app still uses its synthetic timeline.
- Four actual media variants pass asynchronous parity for every 180 frames and
  288,288 stereo samples, ten video and eight audio seeks each, plus replacement
  of primed decoder state. Every variant passes 282 actual AVAudioEngine offline
  clock observations checked against independent exact frame arithmetic.
- Retained payload cache is 90,112 bytes under a 131,072-byte test limit; pending
  requests finish at zero. Internal codec/index memory remains unprofiled.
- Live display/audio scheduling, latency/underrun recovery, helper packaging and
  broader format coverage remain open. Milestone 1 remains in progress. See
  [the evidence](docs/evidence/native-playback-20261011/README.md).

### Basic assembly workspace checkpoint (2026-10-11)

- Replaced synthetic UI with a resizable bin/source monitor/inspector/timeline.
  AVFoundation probes run asynchronously off the main actor; AVKit previews
  original video/audio and the monitor displays stills. Edited-sequence playback
  remains unavailable, and AVFoundation format coverage is the current limit.
- Added `.afcproject` versioned JSON documents, validated decoding, native
  document commands/autosave, security-scoped bookmarks and required entitlements.
  Document reload resets editor state; relinking checks stream identities/layouts
  and source bounds, with locations and grants restored together by undo/redo.
- Added atomic core asset registration/assembly, linked A/V placement, mono to
  stereo mapping, sibling collision placement, basic sequence/scaling controls,
  horizontal move, numeric trims, split/delete, and focus-scoped default commands.
- Added eight assembly/persistence regressions plus a generated WAV/PNG app smoke
  harness covering real importer/document/store paths, import/relink grant undo,
  save/reopen, bookmark resolution, failed relink, reload, and corrupt/schema/model
  rejection. Core tests and macOS Debug build pass; see `docs/basic-workspace.md`.
- Timeline playback, FFmpeg packaging, filmstrips/waveforms, fading/proxies/export,
  full source audio selection, panel visibility, and shortcut customization remain
  unchecked. Basic workflow testing is ready; full v1 acceptance is not complete.

### Workspace editing controls checkpoint (2026-10-11)

- Added Finder URL drops through the same asynchronous importer as the file
  panel, persistent panel visibility controls, and project-persisted automatic
  empty-track cleanup controls.
- Clip-edge gestures preview locally and commit one linked edit on release.
  Shared geometry clamps trim deltas to all linked source/timeline bounds and
  preserves at least one sequence frame for video. The magnet toggle snaps moves
  and trims to other clip edges and the playhead within eight screen pixels.
- Added strict non-drop/drop-frame timecode parsing, skipped-label rejection,
  exact containing-frame formatting with sequence start offset, start timecode
  editing, go-to-timecode, and previous/next frame navigation. These navigate edit positions;
  live edited-sequence playback remains unfinished.
- Added core timecode/gesture regressions and app/store smoke coverage for linked
  trims, boundaries, undo/redo, timecode persistence, and cleanup. Verification
  passed: 9 Python regressions, 42 Swift Testing cases plus 27 XCTest cases,
  unsigned macOS Debug build, and the expanded app-file smoke harness. Native UI
  automation reached the initial document dialog but disconnected before workspace
  interaction; manual gesture and panel-layout checks remain part of user testing.


### Timeline previews, shortcuts, and audio source selection checkpoint (2026-10-11)

- Added visible-region asynchronous video/still filmstrips and channel-mapped
  source waveforms. Two active decoder jobs, twelve pending jobs, twelve images
  per request, 512 waveform bins, and a 24 MB/32-entry LRU bound retained preview
  work. Trims/zoom, source channel maps, media revisions and file fingerprints
  invalidate stale results; offline/unsupported media retains a placeholder.
- Added a shared command registry and Settings shortcut editor with persistent
  remapping, clearing, defaults reset, conflict/reserved-key validation, and
  panel/text-entry dispatch guards. Document shortcuts remain native.
- Added atomic post-insertion source selection and explicit output routing for
  mono, multiple mono, stereo, surround and unknown speaker layouts. The inspector
  previews track adaptation and optionally confirms it before committing. Source
  timing and linked picture remain intact; stale drafts and invalid routes fail
  without changing the document. Undo/redo and persistence include all tracks/maps.
- Collision-driven moves/trims now reuse siblings only when routing and gain
  match the originating track, protecting differently routed mono components.
- Initial placement of non-mono/stereo-only sources and consolidation of existing
  separate components remain open. Waveforms describe source channels before
  routing/gain; source monitoring still plays original media. Live edited-sequence
  monitoring, helper packaging, fades/crossfades, proxies and export remain open.
- Verification passed: 76 EditorCore tests (34 XCTest and 42 Swift Testing),
  nine Python regressions, shortcut model smoke, expanded native app-file smoke,
  generated audio/still/video preview stress smoke, and the unsigned macOS Debug
  build. Preview checks cover duplicate cache misses, queue saturation, active
  cancellation, same-path replacement invalidation, source/channel windows and
  image bounds. Native workspace gestures, focus transitions, and sheet layout
  still need manual UI testing; no live sequence-playback claim is made.

### Audio component consolidation checkpoint (2026-10-11)

- The audio source inspector now lists compatible linked components for explicit
  replacement with one mapped mono/stereo/surround component. Only checked
  components are removed; linked picture and unchecked audio remain intact.
  Source channels and sequence outputs still require explicit selection.
- Consolidation requires matching asset, source range, timeline start, link group,
  track family and static gain. Differing timing or gain requires a separate edit;
  it is never silently resolved by choosing one component's settings. The selected
  clip identity and gain survive, occupied tracks keep their settings, and empty
  tracks follow the cleanup/retention preferences. Family templates survive.
- Preview and optional track-change confirmation include component removal.
  Cancellation and stale drafts leave the document intact. Consolidation, routing,
  track adaptation and cleanup commit as one undoable document edit.
- Added five core regressions covering mono-to-surround maps, explicit subsets,
  occupied tracks, cleanup/retention, persistence, linked moves, invalid component
  identities/maps, ambiguous timing/gain and redo preservation. The app smoke
  harness exercises preview, rejection, commit, save/reopen and undo/redo.
- Verification passed: 81 EditorCore tests (39 XCTest and 42 Swift Testing),
  nine Python regressions, shortcut smoke, expanded app-file smoke and the
  unsigned macOS Debug build.
- Initial placement of non-mono/stereo-only assets, live edited-sequence monitoring,
  helper packaging, fades/crossfades, proxies and export remain open. Inspector
  checkbox interactions and confirmation layout still need manual UI testing.

### Initial audio placement checkpoint (2026-10-11)

- Added explicit source/channel/output selection before insertion, including
  separate mono components, surround and unknown layouts, and picture-only
  placement. Unsupported default append opens the selection sheet.
- Preview and optional confirmation leave the document untouched; append, linked
  picture/audio, track creation and routing commit as one undoable edit. Stale
  drafts and invalid maps are rejected atomically. Existing track reconfiguration
  cannot change requested routing or gain during initial placement.
- Uses the component consolidation implementation already merged in PR #11;
  this checkpoint adds initial placement rather than another consolidation API.
- Added six core regressions and app-store preview/commit/history/persistence
  checks. Verification passed: 87 EditorCore tests (45 XCTest and 42 Swift
  Testing), nine Python regressions, shortcut smoke, expanded app-file smoke,
  and the unsigned macOS Debug build.
- Live sequence monitoring, helper packaging, fades/crossfades, proxies and export
  remain open. Native sheet interactions still need manual UI testing.

### Standalone audio fades checkpoint (2026-10-11)

- Added backward-compatible per-component fade-in/out durations and linear or
  equal-power curves. Each edge is independently bounded by clip duration;
  overlapping edges multiply. Timeline handles preview locally and commit one
  undoable edit; inspector controls use the sequence audio sample grid.
- Fades survive moves, explicit source selection, save/reopen and undo/redo.
  Consolidation requires matching envelopes. Trims clamp fades; splits between
  fades preserve the original envelope and clear inner edges. Splits inside an
  active fade are rejected atomically rather than changing its sound.
- The development FFmpeg compiler and native monitor evaluate the same envelope
  at clip-relative sample positions, independent of block boundaries and seek
  history. Source monitoring and source waveforms still describe original media.
- Linked crossfades, adjacent-cut source-handle extension, live sequence playback,
  bundled helpers, proxies and production export remain open. Native gesture
  interaction and inspector layout still require manual UI testing.
- Verification passed: 95 EditorCore tests (51 XCTest and 44 Swift Testing),
  nine Python regressions, shortcut smoke, expanded app-file smoke, unsigned macOS
  Debug build, baseline render proof and five native playback variants. Fade audio
  differs by at most 1.0 s16 unit from independent FFmpeg output; all seeks,
  replacement and offline sample-clock checks pass. See
  [retained fade evidence](docs/evidence/audio-fades-20261011/README.md).

### Linked audio crossfades checkpoint (2026-10-11)

- Added backward-compatible paired crossfade relations with equal-power defaults,
  editable duration/curve, inspector creation/removal and fade-handle drops onto
  the actual second audio component. Compatible targets highlight during dragging;
  linked clips show duration badges. Release commits one undoable transaction.
- Existing overlaps use their exact overlap duration. Adjacent cuts derive
  sample-aligned audio handles, centered where possible and redistributed to
  available source media. Insufficient handles, incompatible layouts/routes,
  conflicting standalone edge fades and overlapping chain envelopes are rejected.
  Original clip ranges, linked picture and sequence duration remain unchanged.
- Render plans combine both handles on middle clips and use the same paired
  envelopes for development FFmpeg/native playback. Removal restores the original
  audio cut. Compatible joint moves retain relations; invalid geometry or source
  remapping dissolves affected relations atomically while preserving unrelated
  pairs. Splits inside paired envelopes are rejected; splits outside dissolve
  the relation. Undo restores the complete edit.
- Added core/render tests and app smoke checks for persistence, sample alignment,
  chains, history, stale drafts and relink rejection when source handles would be
  lost. Native pointer gestures and inspector layout still need manual testing.
  Live sequence playback, shipping helpers, proxies and production export remain
  open; source monitoring continues to play original media.
- Verification passed: 110 EditorCore tests (66 XCTest and 44 Swift Testing),
  nine Python regressions, shortcut smoke, expanded app-file smoke, unsigned macOS
  Debug build and eight native playback variants. Linked overlap and adjacent-cut
  transitions pass independent sample-envelope checks, asynchronous/offline audio,
  seeks and primed-plan replacement. See
  [retained crossfade evidence](docs/evidence/crossfades-20261011/README.md).

### App icon and source playback shortcuts checkpoint (2026-10-11)

- Added a film/assembly-track app icon with every macOS asset size and configured
  Debug/Release to use it. A retained AppKit drawing script regenerates the assets.
  The unsigned app bundle contains `AppIcon.icns` and its icon metadata.
- Added remappable J/K/L commands in the Playback menu and source monitor buttons:
  J plays backwards through silent, bounded serial seeks; K pauses; L plays
  forwards at normal speed. J at the start begins at the source end, and L at the
  end restarts from zero. Playback controls the selected original source across
  workspace panels and preserves text entry. Still images have no transport.
- Source changes and document close cancel the transport task. Reverse seeks use
  elapsed monotonic time and keep at most one seek outstanding. Shuttle speed
  changes, reverse audio and edited-sequence playback remain open.
- Verification passed: 110 EditorCore tests (66 XCTest and 44 Swift Testing), nine
  Python regressions, shortcut smoke, expanded app-file smoke and the unsigned
  macOS Debug build. Playback smoke covers forward/pause, silent reverse, both
  source boundaries, restart, source replacement and document-close cancellation.
  Physical key delivery and native focus interactions still need manual UI testing.

### Sequence render, helper preparation and FCPXML checkpoint (2026-10-11)

- Added a snapshot-based native export dialog, toolbar/File menu commands and
  remappable render shortcut. MOV/ProRes 422 HQ/24-bit PCM uses sequence raster,
  rational frame rate, start timecode, original media, channel maps, gain and
  fade/crossfade envelopes. PNG/JPEG stills preserve alpha and fit/fill/none;
  synthetic still source trims do not change the decoded image. Audio retains
  exact sample duration when video covers a final partial frame.
- Added source FFprobe preflight, bounded progress/diagnostic handling, explicit
  cancellation with subprocess reaping, independently scoped media access,
  private staging and atomic no-overwrite publication after output metadata/count
  verification. The folder picker grants staging access. Unsupported/mismatched
  source stream indices, nonzero offsets, known rotation/non-square/HDR markers,
  obvious VFR and insufficient source ranges fail without publishing output.
- Added opt-in helper preparation and an Xcode copy/sign phase. Matching helpers,
  required capabilities, system-only dependencies, file hashes and supplied
  notices/provenance are recorded. Unset configuration removes stale helpers;
  ordinary builds contain none. Development preparation does not certify release
  source attribution or licensing; signed sandbox export remains unqualified.
- Added a scoped FCPXML 1.10 exporter with exact sequence timing, layered picture,
  complete matching mono/stereo audio and original references. Unsupported fades,
  crossfades, remaps, gain and geometry are rejected before saving. The save panel
  shows qualification notes. Apple's DTD passes; native editor import is open.
- Verification passed: 121 EditorCore tests (74 XCTest and 47 Swift Testing), nine
  Python regressions, shortcut smoke, expanded app-file smoke, export-service
  lifecycle/failure checks, original render proof, independent still alpha/scaling
  and audio-tail proof, helper copy/sign/tamper tests, and unsigned macOS builds
  with/without opt-in helpers. See [retained evidence](docs/evidence/sequence-export-20261011/README.md).
- Live edited-sequence monitoring, proxies, stream-copy export, full geometry/color/
  VFR qualification, native interchange import and release helper review remain
  open. No production media compatibility or completed v1 acceptance is claimed.

### Qualified project-bin proxy checkpoint (2026-10-11)

- Added batch selection and right-click proxy creation with ProRes Proxy default,
  optional H.264, full/half/quarter raster, output-folder grants, per-asset progress,
  cancellation and failure summaries. Each batch runs sequentially; the shared
  service admits at most two jobs across windows and reports excess requests.
- Generation scans all original and proxy frame timestamps with exact rational
  arithmetic. It verifies selected stream identity, zero-based CFR timing, codec/
  profile, raster/aspect, frame count, available source timecode and known SDR
  color tags before atomic no-overwrite publication. VFR, offset/rotated/anamorphic,
  HDR and full-range sources are refused. Probe output remains bounded to 2 MB.
- Added backward-compatible persisted proxy metadata and separate sandbox grants.
  Successful registration is undoable; previous proxies remain registered until
  replacements verify. Relinking originals invalidates their proxies atomically.
  Document/source revisions prevent stale jobs from registering into changed media.
- Added document-session hires/proxy source switching, preserving nonzero position
  and forward-play intent across rapid asynchronous switches. Native composition
  uses proxy picture and all original audio tracks, including audio tails beyond
  picture. Missing/stale/unusable proxies visibly fall back to originals. Timeline
  edits, source previews in the timeline, render plans and interchange use originals.
- Fixed a confirmed Foundation subprocess hang by removing redundant synchronous
  `waitUntilExit` after asynchronous termination polling. Cancellation still
  escalates termination, drains bounded pipes and verifies child reaping.
- Verification passed: 125 EditorCore tests, nine Python regressions, shortcut
  smoke, expanded app-file smoke, existing export smoke, proxy service/workspace
  smoke and unsigned macOS Debug build. Both codecs pass all 24 decoded frame
  correspondence checks at 24000/1001. Actual AVFoundation composition checks
  cover multiple original audio streams, longer audio tails, transport switching,
  grants, history, reopen, fallback and stale registration rejection.
- Large-file/VFR mappings, signed sandbox grants, native gestures and hardware
  A/V quality remain open. Source freshness uses size/mtime rather than a content
  hash. Live edited-sequence playback is still unimplemented. See
  [proxy scope and reproduction](docs/proxies.md).

### Proxy integrity, relocation and stream-copy assessment checkpoint (2026-10-11)

- Newly generated proxies persist file size and SHA-256 identity. Cancellable
  verification streams bounded chunks off the main actor before proxy playback;
  changed files visibly fall back to originals. Source freshness still uses
  size/mtime. Legacy unhashed references remain playable without a byte guarantee.
- Added explicit MOV proxy relinking in the bin. Only the recorded proxy bytes
  are accepted; originals must remain unchanged. URL and independent sandbox
  grant update as one undoable edit, preserve timeline/source identity and source
  transport, and survive save/reopen. Legacy references require regeneration
  before relinking. Cancellation and stale document/source completions are refused.
- Added independent picture/audio stream-copy assessments with typed rejection
  reasons, exact source/range/container binding and an explicit packet-verifier
  evidence contract. The current importer cannot produce this evidence; packet
  verification, remuxing, copy/render combinations and cuts-only concatenation
  remain open. See [assessment scope](docs/stream-copy.md).
- Verification includes core integrity and assessment regressions, real ProRes/H.264
  generation, moved-file validation, same-size/mtime tampering, and unsigned macOS
  builds. Native dialog gestures and signed sandbox grants remain unqualified.

### Persistent proxy queue and pending transport checkpoint (2026-10-12)

- Proxy jobs persist source snapshots/fingerprints, preset/resolution, unique
  destinations, output-folder grants, state and verified publication metadata.
  Reopened running jobs become interrupted and require explicit resume. Closing
  the queue keeps jobs running; closing the document cancels them.
- The queue supports bounded progress, cancellation, individual retries, explicit
  fresh-file retries and safe removal. Saved verified publications recover by
  exact-byte validation. Existing outputs without saved verification metadata
  are preserved and require a fresh destination. Queue state uses ordinary
  document save/autosave, remains outside timeline undo and is not a crash journal.
- Source changes and stale completions cannot register a proxy into changed
  media. Successful registrations remain undoable. Legacy projects decode with
  an empty queue; invalid jobs and duplicate identities/destinations are refused.
- Forward/pause controls now remain usable during proxy verification and loading,
  updating pending transport intent. Reverse requires a loaded source player.
- Final verification passed: 135 core tests, with one additional XCTest skipped;
  nine Python regressions, shortcut smoke, project-file smoke, proxy service and
  workspace smoke, queue lifecycle smoke, export service smoke and unsigned macOS
  Debug builds. Queue checks cover resume/recovery, collisions, stale originals,
  cancellation, history separation, removal and backward compatibility. Native
  gestures, signed grants and hardware playback remain unqualified.
- Live edited-sequence monitoring, broad-format/color/VFR qualification, actual
  stream-copy export and release helper review remain open.


### Selected-track EDL and live monitor development checkpoint (2026-10-12)

- Added a conservative CMX3600 exporter for one explicitly selected video or
  complete mono/stereo audio track. Exact cuts and leading/internal gaps use
  exclusive out points; source/record frame alignment, rational-rate agreement,
  timecode modes, reel identity, event limits and day boundaries are validated.
  Unsupported processing and unknown source timing are refused before serialization.
- Added an app export sheet, menu command and remappable shortcut entry. Original
  source rate/timecode/reel values require explicit user declarations and CFR
  confirmation. The sheet keeps an immutable project snapshot, reports its track
  scope and receiver limitations, and protects original-file aliases when saving.
  Declarations are not imported metadata or automatically verified source evidence.
- Expanded proxy queue checks cover individual retry isolation, saving active jobs,
  document replacement cancellation and stale cleanup against a new document.
- Added a standalone native live monitor development path; it remains separate
  from the shipping app. Hardware A/V synchronization, decoder deadline behavior,
  signed dependency packaging and live edited-sequence app monitoring remain open.
- Verification passed: 144 core tests with one optional DTD test skipped, nine
  Python regressions, shortcut smoke, expanded app-file and proxy-queue smokes,
  unsigned macOS Debug app build, standalone live proof build and 14 native
  runtime tests. Hardware playback and native EDL import were not exercised.
- See [EDL scope and usage](docs/edl-export.md) and the
  [native development package](Packages/NativePlaybackProof/README.md).

### Native spatial conform and live lifecycle checkpoint (2026-10-12)

- Native video now applies clip fit/fill/none with bounded bicubic scaling and
  centered RGB padding/cropping. Source, sequence and intermediate dimensions
  are limited to 4096 per direction. Unsupported rotation/PAR/HDR/VFR checks
  remain explicit; still alpha and general color conformance remain open.
- Baseline plus nine geometry variants pass all 180 synchronous/asynchronous
  frames, 288,288 stereo samples, ten video and thirteen audio seek/rebuild cases,
  native PNG capture, primed plan replacement and offline transport observations.
  Active-picture checks exclude black padding. Maximum mean RGB error is 2.0;
  maximum audio error is 0.5 s16 units. Lossless RGB source fixtures qualify this
  spatial subset; arbitrary subsampled-source edge alignment remains open.
- Audio-engine configuration changes and unexpected stops cancel pending work,
  flush output and pause at the last accepted position without automatic resume.
  Observers are removed on close/deallocation. Scripted hardware output exposed
  negative startup node sample times; preroll now waits for a nonnegative clock
  under the two-second deadline, while established-clock regressions still fail.
- The standalone runner retains periodic/action/error/final JSON observations
  and offers an explicit play/seek/pause/resume script. The three-second local
  output exercise passed without errors, with at most 4096 queued samples.
  This is transport evidence, not acoustic/display A/V synchronization.
- Verification passed: EditorCore suites (one optional DTD test skipped), 17
  Python regressions, shortcut smoke, unsigned macOS Debug app build, standalone
  native builds and 22 runtime tests. Subsequent PR verification passed 22 Python
  regressions after rejecting incomplete/out-of-order scripted exercises, and
  repeated the app/core and complete live exercise on the rebased head. The complete nine-variant geometry proof
  and scripted live run use actual local FFmpeg libraries and macOS audio services.
- Shipping-app sequence monitoring, measured A/V sync/latency, physical device
  changes, underrun recovery, broad formats/color/VFR, still alpha, sequence
  proxies and signed dependency packaging remain open. See retained
  [spatial evidence](docs/evidence/native-geometry-20261012/README.md) and
  [live transport observations](docs/evidence/native-live-20261012/README.md).


### Native stills, live recovery and preview admission checkpoint (2026-10-12)

- Native playback now accepts single-frame PNG/JPEG stills with synthetic source
  trims, fit/fill/none geometry and straight-alpha PNG composition over lower
  layers. Actual demuxer/codec identity and single-frame extent are checked;
  ambiguous, animated/multiple-frame images and alpha-bearing motion video are
  refused. General color management and image-format qualification remain open.
- Baseline plus twelve PNG/JPEG variants pass every synchronous/asynchronous
  decoded frame/sample, ten video and thirteen audio seeks per variant, native
  PNG capture and primed plan replacement. Separate no-scaling alpha oracles
  exercise transparent, partial and opaque pixels. The complete ten-case prior
  geometry suite also passes after these changes.
- Live starvation now pauses at the last accepted sample without rereading or
  clamping a rejected clock. Explicit Play resets the output-clock epoch. Final
  manual Pause uses the same clock validation. Owned priming work cancels across
  pause/seek/replacement/close/caller cancellation; polling tasks release abandoned
  monitors. Injected clock/device tests verify recovery policy, not physical
  starvation or acoustic/display synchronization.
- Timeline preview admission bounds metadata fingerprinting and decoding together
  to two active jobs and twelve FIFO waiters. Cancellation removes queued work
  without polling. Existing 24 MB/32-entry cache limits now have real eviction
  regressions; disappearing clips release retained previews.
- Still source previews use a serial off-main-actor ImageIO decoder, apply
  orientation and retain at most a 2048-pixel longest edge. Import validates with
  64-pixel thumbnails. Selection/document epochs reject obsolete results.
- Verification passed: 146 core tests with one optional DTD test skipped, 22 Python
  regressions, shortcut smoke, app-file and timeline-preview smokes, proxy queue
  and workspace smokes, unsigned macOS Debug build and 32 native runtime tests.
  Actual scripted macOS output completed play/seek/pause/resume/close with no errors
  and at most 4096 queued samples. macOS media/bookmark/audio checks required
  services outside the restrictive command sandbox.
- Retained pixel/cache limits do not bound ImageIO/FFmpeg probing or codec scratch
  memory. Native source decoder buffers are outside the async output-cache budget.
  Shipping sequence monitoring, dependency packaging, full project/launch profiling,
  measured hardware recovery/latency/A/V sync and broad color/VFR remain open. See
  [still parity evidence](docs/evidence/native-stills-20261012/README.md),
  [live recovery evidence](docs/evidence/native-recovery-20261012/README.md) and
  [native package reproduction](Packages/NativePlaybackProof/README.md).

### Large-project, decoder retention and export-rate checkpoint (2026-10-12)

- Core validation now uses exact sorted intervals and indexed asset/family lookup.
  Crossfade validation, rendering and edit cleanup reuse endpoint/geometry maps.
  Optimized synthetic 5,000-clip medians improved validation from 359 to 5.4 ms,
  render planning from 1513 to 15.2 ms and move/undo/redo from 1384 to 29.2 ms.
  The 10,000-clip workload passes. Peak process memory increased from about
  138 to 151 MB at 5,000 clips; this benchmark excludes the UI and media I/O.
- Workspace duration and selected/media lookups cache until the project changes.
  Regression coverage checks nested mutation, undo/redo and document replacement.
- Native retained source decoders use configurable LRU context and decoded-source
  byte budgets. Defaults are 16 contexts and 128 MiB, separate from returned
  payload caching. PNG/WAV tests cover eviction, exact reopen/seek, failed calls,
  lifetime release and visiting more than 64 sources. Codec/probe/internal memory
  is excluded; eviction can add requalification latency.
- The complete 13-variant still and 10-variant geometry parity suites pass with
  this retention policy, as do 39 runtime tests. Host access was required for
  actual macOS offline audio services. Hardware sync/latency remains unqualified.
- Rendered MOV/ProRes HQ/PCM exports at 24, 24000/1001, 30000/1001 DF and
  60000/1001 DF pass every decoded barcode frame and exact timestamp, sample
  counts/routes/gain/phase, and actual MOV timecode packet checks. Native receiver,
  mixed rates, VFR and broad source/container qualification remain open.
- See [performance evidence](docs/evidence/project-performance-20261012/README.md),
  [retention evidence](docs/evidence/native-retention-20261012/README.md) and
  [export-rate qualification](docs/fractional-render-export-proof.md).

### Immediate editing and save protection checkpoint (2026-10-12)

- Empty launches/reopens now request an ordinary untitled DocumentGroup workspace
  instead of the default Open dialog. File-open/restoration takes precedence;
  deferred requests coalesce. Finder drops can import without first choosing a
  project name. Native save/open/autosave remains the document controller's job.
- Edited untitled work suggests saving after approximately five minutes, with
  Save and snooze actions. Unchanged new workspaces do not prompt. Saving clears
  the first-save reminder and enables timestamped backup snapshots.
- Saved projects snapshot after 15 idle seconds, with at least 60 seconds between
  writes and a 120-second continuous-edit deadline. At most 20 completed backups
  are retained per standardized project path in app Application Support. Encoding
  and durable staging/publication run on a worker actor. Backups never write the
  source project and include the normal document envelope/bookmarks/proxy queue;
  originals are referenced rather than copied. Show backups opens recovery files.
- Failures remain visible and retry at the next permitted interval. Tests cover
  five-minute timing/snooze, untouched state, debounce/minimum/maximum intervals,
  bounded retention, reopenable snapshots, source preservation, symlink refusal,
  retry and edits/Save As during an in-flight write. The smoke compiles with Swift
  6 and default MainActor isolation; value serialization is explicitly nonisolated.
- Final verification passed 151 core tests with one optional DTD test skipped,
  22 Python regressions, shortcut and startup/save-protection smokes, app-file,
  proxy-queue and timeline-preview smokes, and the unsigned macOS Debug build.
  Native runtime/parity and export-rate evidence is recorded above. Release
  launch-to-interaction measurement and signed sandbox acceptance remain open.
- Native cold-launch UI inspection of an isolated unsigned app copy timed out
  without returning a window state. Startup policy is covered by deterministic
  tests and compilation; the updated launch window was not visually qualified.
  The existing installed app was left untouched after automatic review rejected
  quitting it because its unsaved-document state was unknown.

### Save-restoration review follow-up (2026-10-12)

- Recovered untitled project content now starts the first-save reminder without
  waiting for another edit; untouched default workspaces remain silent.
- Temporary workspace disappearance releases resources. Reappearance restores
  bookmark access and source preview while retaining project, selection, sequence
  playhead and undo/redo history, without resetting reminder/snooze deadlines.
- Strict Swift 6 save-protection smoke, real bookmarked-media close/resume with
  pre-hide edit undo/redo, app-file smoke and unsigned macOS Debug build pass.

### Embedded local helpers and proxy qualification checkpoint (2026-10-12)

- Debug builds can persistently select an explicitly prepared helper directory
  using an ignored local xcconfig. This checkout selects `.local/media-helpers`,
  containing the matching local static FFmpeg/FFprobe 9.0.1 full build. The
  preparer's matching-build, capability, system-dependency and hash checks remain
  intact. Release does not inherit the local selection; binaries are not committed.
- The unsigned Xcode Debug app builds with both helpers. Copied hashes match the
  manifest; separate helper signing/strict signature verification passes. Source
  attribution and notice completeness remain unreviewed development material.
- A disposable app harness tests the production `Bundle.main` lookup with cleared
  developer loader paths. Both ProRes Proxy and H.264 generate 24 fractional-rate
  frames at 80x48, verify recorded SHA256, and preserve original fixture bytes.
- Expanded generation tests pass on local 9.0.1 and Homebrew 9.0.2: every decoded
  spatial/frame correspondence, half/quarter geometry, two-audio/two-video source
  stream selection, actual MOV timecode/SDR/rational-rate metadata, and rotation,
  HDR, full-range, VFR, SAR and invalid scaled-raster rejection.
- Verification passes 151 core tests (one optional DTD test skipped), 22 Python
  regressions, shortcut/startup/save-protection smokes, proxy workspace switching
  and persisted queue smokes. Xcode and bookmark tests required host cache/services.
  Signed sandbox execution, native proxy dialog gestures, broad-format/VFR mapping,
  sequence proxy monitoring and release packaging remain open. See
  [helper setup](docs/media-helper-packaging.md) and [proxy tests](docs/proxies.md).

### OTIO and live output route checkpoint (2026-10-12)

- The app exports OpenTimelineIO from the workspace and File menu, with optional
  shortcut assignment. Layered cuts/gaps, original references, source ranges and
  sequence start are retained. Unsupported effects, stream/channel mappings,
  geometry, stills and edits requiring rounding fail before choosing a destination.
  Original alias protection and snapshot media access follow existing interchange
  exports; refusal preserves document and undo history.
- Official OTIO 0.18.1 core read/write, schema equivalence and every child timing
  pass at 24, 25, 24000/1001, 30000/1001 and 60000/1001 using Python 3.12.
  Exact rational timing and DF/NDF intent are retained in namespaced metadata;
  receiving-editor import, spatial conform and a direct C++ bridge remain open.
  See [the supported subset and reproduction](docs/otio-export.md).
- Native live output checks canonical hardware mono/stereo channels before/after
  priming and engine startup. Canonical tags and explicit ordered speaker labels
  are accepted; incompatible routes pause without discarding position and permit
  explicit retry. Actual local output uses Left/Right channel descriptions.
- Verification passes 158 core cases (one optional FCPXML DTD check skipped),
  including official OTIO qualification; 43 native runtime cases; 22 Python
  regressions; shortcut and app-file smokes; and unsigned macOS Debug build.
  Actual scripted play/seek/pause/resume/close passes with no errors or underruns
  and at most 4096 queued samples. macOS service checks required host access.
- Physical device switching, measured A/V timing, shipping-app sequence playback
  and release dependency packaging remain open. See retained
  [output route evidence](docs/evidence/native-output-route-20261012/README.md).

### Direct timeline Finder drops checkpoint (2026-10-12)

- Empty launch/reopen still suppresses the document Open panel and automatically
  creates an ordinary untitled editing workspace. Startup policy smoke passes;
  no project name or save location is needed before importing or placing media.
- Finder drops onto the timeline now import and place media, starting at zero
  for an empty timeline or at the frame-aligned drop position on its canvas.
  Canvas/viewport geometry accounts for both scroll offsets. Toolbar drops use
  the playhead. Files in a batch follow one another by their exact durations.
- Compatible target tracks are honored; occupied tracks create collision
  siblings. Import, bookmark and placement are one undoable action per file.
  Failed files leave no bin/clip/bookmark entry and do not advance the cursor;
  incompatible audio provides explicit channel-selection guidance. Document
  replacement/close cancels obsolete imports. Other workspace drops remain
  bin-only imports.
- Real WAV/PNG smoke checks cover ordered placement, exact captured fractional
  time, undo/redo grants, target placement/order/fallback, overlap siblings,
  failed audio in a mixed batch and stale-document cancellation. Startup and
  shortcut smokes and unsigned macOS Debug build pass.
- Native visual startup and Finder gesture inspection remain unverified: the
  computer-use pipe closed before responding, Apple events were unauthorized,
  and the read-only window query could not produce a window capture. The isolated
  app process did start; no user documents were closed or changed.

### Partial-frame playback and render-source qualification checkpoint (2026-10-12)

- Native playback now retains exact edit duration independently from the ceiled
  output frame count. Sample-aligned audio tails can end between video frames;
  uncovered picture stays black and transport stops at the exact edit end.
  Frame-aligned video edits and sample-aligned audio edits remain required.
- Real native/FFmpeg parity passes baseline and primed-plan replacement with
  181 video frames and 288,289 stereo samples. Final-frame/last-sample seeks,
  backward seeks, rebuilding and 282 offline clock observations pass. Maximum
  mean RGB error is 2.0; PCM error is 0.5 s16 unit. Core regressions cover 24,
  24000/1001, 30000/1001 and one-sample audio-only playback. See
  [retained evidence](docs/evidence/native-partial-tail-20261012/README.md).
- Render preflight fully scans selected decoded video timestamps using exact
  rational arithmetic and half-tick container quantization. It rejects a real
  irregular-timestamp source whose average and nominal rates both report 24,
  decoded raster changes, exposed rotation/SAR/HDR metadata, invalid audio sample
  rates and inadequate decoded source coverage. Different CFR rates/rasters and
  44.1-to-48 kHz audio resampling still pass.
- Preflight stops and reaps helpers after 30 seconds or 2 MB output; the full scan
  also caps 100,000 frames. Long/slow sources are refused rather than partially
  qualified. Export and shared-process proxy smokes pass, including timeout and
  output overflow. Dynamic color management and general audio timestamp continuity,
  live display/device timing and shipping-app sequence playback remain open.

### Exact single-range stream-copy development checkpoint (2026-10-12)

- Added a separate bounded ProRes HQ/PCM MOV remux verifier. It requires exact
  shared picture/PCM packet cuts and directly rejects MOV edit-list media offsets,
  preroll, rate changes and multi-edit timing hidden by zero-based probe results.
- Real nonzero ranges pass at 24, 25, 24000/1001, 30000/1001 and 60000/1001:
  every packet payload hash, exact rebased PTS/DTS/duration, decoded picture frame,
  integer PCM sample and advanced MOV timecode packet matches. First/last ProRes
  packets also decode independently in fresh processes. Originals are unchanged.
- Ten regressions pass with explicit real helpers, including unsupported
  closed/open-GOP H.264, AAC, unaligned cuts, hidden MOV offsets, bounded capture
  and overwrite refusal. See [scope and reproduction](docs/stream-copy.md).
- The proof supplies no importer-connected evidence and enables no app export
  mode. Cuts-only concatenation, mixed copied/rendered streams, interframe/
  compressed-audio copy, DF timecode and signed/native receiver qualification
  remain open. This is a qualified development subset, not complete stream-copy.

### Release workspace startup and responsiveness checkpoint (2026-10-12)

- Actual isolated Release launches exposed a missing-window startup path:
  AppKit could finish launching without calling the untitled-file callback.
  A guarded did-finish fallback now requests the existing deferred/coalesced
  workspace creation only for AppKit's explicit default-launch flag. File,
  print, service and restoration launches are excluded; existing and queued
  documents retain precedence. The expanded startup policy smoke passes.
- Opt-in instrumentation waits for a loaded, visible, key document window and
  routes mouse events to a native control, recording the action actually handled
  on a later main-loop turn. Normal sessions create no probe control or timer.
- The first successful five-run Release experiment handles interaction in
  1.157–1.284 seconds (median 1.215), including Launch Services/process startup
  and harness observation overhead. Each run has fresh preferences; later runs
  use warm OS caches. A repeat creates/loads all five workspaces but records
  interaction in only four: one never reaches the visible/key-window gate before
  timeout. The passing repeat samples are 1.108–1.383 seconds. Activation/readiness
  consistency remains unqualified; the failed sample is retained. See
  [method and retained evidence](docs/release-launch-performance.md).
- Verification passes 32 Python regressions (three optional real-media cases
  skipped), 86 XCTest cases (two optional dependency checks skipped), 74 Swift
  Testing cases, shortcut/startup/save-protection smokes and unsigned Debug and
  Release builds. The real stream-copy matrix and 43 native runtime cases pass
  separately. Xcode/cache and macOS audio/window checks required host access.
- Reboot-cold startup, populated-project controls, signed sandbox/notarization,
  media/helper initialization and physical/compositor latency remain open. The
  full two-second Release acceptance target is not marked complete.

### App monitoring, proxy correspondence and cuts-only copy checkpoint (2026-10-12)

- Source/Sequence selection now connects the actual workspace to a native
  controller: original-media scopes, edited-plan replacement, coalesced scrubs,
  sample-clock positions and K/L transport. Delayed priming tests cover pause
  and preserving a pending scrub. Default Xcode builds explicitly report the
  absent native runtime; an opt-in script builds an isolated enabled SwiftUI
  workspace against explicitly selected development libraries.
- The actual controller qualifies seek position 0.5/frame 12 and edited-plan
  frame zero against independent FFmpeg pixel captures, plus live PCM sample
  clock progress, pause and replay. Runtime packaging/signing, sequence proxies
  and measured acoustic/display timing remain open. See
  [sequence monitor scope and reproduction](docs/sequence-monitor.md).
- Native proxy qualification now compares five exact reopened frames of an
  asymmetric moving fixture, timestamp-aligned mono/stereo PCM including delayed
  MOV edits and original audio tails, and switching beyond proxy picture extent.
  A core regression confirms proxy metadata never changes final render commands
  or original input URLs; missing originals remain refused. VFR mapping and
  signed sandbox/native UI acceptance remain open.
- Exact ProRes HQ/PCM copy proof now handles compatible two-to-four-range
  cuts-only joins and drop-frame labels at both NTSC fractional rates. Eighteen
  real-media tests pass, including every packet's payload and exact timestamps,
  every decoded picture/sample, independent decoding at internal cut boundaries,
  underlying MOV timecode format checks and reordered/repeated sources. App
  evidence generation/export, interframe/compressed-audio copy and mixed
  copied/rendered streams remain open. See [retained evidence](docs/stream-copy.md).

### Populated Release workspace culling checkpoint (2026-10-12)

- Readiness instrumentation retries its deferred native click until the actual
  action runs and records failed gate states; the harness waits for each isolated
  process to quit and validates saved-project asset/track/clip counts.
- A deterministic offline project with two assets, three tracks and 3,000 clips
  initially takes 4.106–4.784 seconds (median 4.500). Eager offscreen clip-view
  creation is removed using horizontal viewport culling, bounded first layout,
  overscan and selection/active-gesture pinning, without reducing canvas extent.
- Five final isolated unsigned Release runs confirm the complete saved project
  and process input in 0.769–1.191 seconds (median 0.844), all below two seconds.
  Pure visibility checks cover coordinate conversion, boundaries, zoom, tiny/
  spanning clips, overscan and pinning. Reboot-cold startup, online media,
  physical input/display and signed distribution acceptance remain open. See
  [launch evidence](docs/release-launch-performance.md).
- Verification passes the Python regression suite (44 tests, eight optional
  media/dependency skips), all 18 explicit real stream-copy cases, the EditorCore
  XCTest/Swift Testing suites, sequence lifecycle/visibility and existing startup/
  shortcut/save-protection smokes, host app-file/native proxy checks, unsigned
  Debug/Release builds and the enabled native development workspace build.
  Xcode caches, macro, bookmark and audio checks require host access; the
  sandbox-only `verify.sh` invocation could not finish Xcode package resolution,
  so the app build was separately completed with host access.

### Nested media-bin workspace checkpoint (2026-10-13)

- Projects now persist named nested bins and stable asset-to-bin assignments.
  Existing documents decode with media at the root. Validation refuses duplicate
  identities, missing parents/assets/destinations and cycles; failed edits roll
  back without changing timeline or media state.
- The workspace supports folder navigation, create/rename/reparent, batch media
  moves and bin dissolution that promotes media and child folders to the parent.
  Each organization action is undoable. Media URLs, bookmarks, proxies and
  render plans remain unchanged by organization.
- Asynchronous imports and timeline file drops capture the selected destination
  before inspection. Removed destinations fall back to the root, and selecting
  imported media reveals its containing bin. Bin-only changes are excluded from
  sequence runtime identity, preserving active playback.
- Verification passes `scripts/verify.sh`: 44 Python tests (eight optional skips),
  90 XCTest cases (two optional skips), 74 Swift Testing cases, workspace policy
  smokes and an unsigned Debug build. The expanded macOS app-file smoke passes
  nested-bin save/reopen, grants, batch history, captured destinations and deleted
  destination fallback; the sequence lifecycle smoke preserves a playing backend
  across bin creation, rename, media moves and removal. An unsigned Release build
  also passes. Host access was needed for Xcode caches and bookmark services.
- Native interactive UI acceptance remains unqualified; this checkpoint adds
  media organization and does not close runtime packaging, stream-copy app export,
  signed distribution or receiver-conform milestones.


### Exact sequence output settings checkpoint (2026-10-13)

- The inspector accepts integer, literal decimal and exact fractional frame rates,
  offers standard integer/NTSC fraction presets and restores the exact stored
  fraction. Decimal values no longer silently select a nearby NTSC rate. Core
  parsing uses checked integer arithmetic and exact upper-bound comparisons.
- Width, height, frame rate, audio sample rate, mono/stereo/5.1 output layout and
  start timecode apply as one validated undoable edit. Existing clip/source times
  and routing remain intact. Incompatible track or retained family maps reject
  the complete change without losing undo/redo history. Saved custom layouts
  remain available without reinterpretation.
- First-clip matching remains open: the importer does not yet retain qualified
  source raster, orientation/pixel aspect or exact frame-rate metadata. This
  checkpoint does not close full output-layout/hardware parity or release runtime
  qualification.
- Verification: the regression suite passes 44 Python tests (eight optional
  dependency/media skips), 90 XCTest cases (two optional skips), 78 Swift Testing
  cases and the workspace policy smokes. The expanded macOS app-file smoke checks
  exact entry, decimal/DF refusal, unwrapped timecode preservation, output-plan
  propagation, persistence and atomic route/history rejection. Unsigned Debug
  and Release app builds pass. Xcode package caches and bookmark services require
  host access; sandboxed Xcode package resolution cannot finish.


### Contextual viewer and representation preference checkpoint (2026-10-13)

- Source/Sequence selection uses one accessible icon button in the viewer header.
  Tab toggles the viewer through the remappable command registry while text entry
  remains protected. Media-bin clicks/selections choose Source; timeline clicks,
  ruler scrubs and clip move/trim interactions choose Sequence, including clicking
  an already selected clip. Switching preserves positions and pauses hidden playback.
- Source representation selection uses one Prefer HiRes/Prefer Proxy icon toggle.
  The preference remains independent of the actual playback representation; missing,
  stale or modified proxies fall back to originals. Verified generated proxy picture
  can be used when HiRes is unavailable, with explicit unavailable-original-audio
  status. Offline fallback refuses unchecked legacy or modified proxies and retains
  original asset identity and export references.
- Sequence monitoring still requires the opt-in native runtime and uses originals;
  this checkpoint does not qualify proxy sequence decoding or release packaging.
- Verification passes `scripts/verify.sh`: 44 Python tests (eight optional skips),
  90 XCTest cases (two optional skips), 79 Swift Testing cases, workspace policy
  smokes and an unsigned Debug app build. Expanded app-file and native proxy
  workspace smokes pass viewer command/selection state, verified offline picture,
  explicit missing audio, nonzero seek preservation, unavailable audio-tail
  position retention and restored-original seeking. Native fixtures cover readable
  playable and missing originals; unsupported-codec fallback detection is present
  but is not yet qualified with a native unsupported-codec fixture.

### Qualified first-picture sequence matching checkpoint (2026-10-13)

- Imported video streams retain optional validated raster and exact rational
  cadence metadata. Older saved streams decode without it. The off-main-actor
  importer scans compressed sample timing in presentation order and requires
  stable format, full single-segment coverage and exact constant cadence.
  Rotated, anamorphic, VFR, retimed/multiple-segment and single-frame sources
  remain importable without offering automatic matching.
- Before adding timeline clips, the Sequence inspector offers an explicit match
  for each qualified selected-source video stream. Picture settings apply in one
  undoable edit; audio settings, media and start timecode remain intact. Existing
  timeline clips or an incompatible DF timecode reject the complete edit without
  changing undo/redo history. Subsequent imports never change sequence settings.
- The bounded scan permits at most 100,000 buffers and checks a five-second
  deadline between synchronous reads; a blocked AVFoundation call cannot be
  interrupted. This proves sample metadata, not decoded geometry/color or full
  format coverage. Broad matching and native gesture acceptance remain open.
- Verification passes 44 Python regressions (eight optional skips), 93 XCTest
  cases (two optional skips), 82 Swift Testing cases, workspace policy smokes and
  the expanded host app-file smoke. Real H.264/B-frame fixtures pass at 24,
  24000/1001 and 30000/1001; VFR/rotation/SAR/single-frame refusal and cancellation
  pass. Unsigned Debug/Release app builds pass. Bookmark services and Xcode package
  caches require host access; sandboxed Xcode package resolution remains blocked.

### Qualified sequence proxy monitoring checkpoint (2026-10-13)

- The representation button is available in Source and Sequence viewers. The
  opt-in native sequence controller verifies timeline-used proxy bytes off the
  main actor, pauses immediately on switching, closes the old decoder and rebuilds
  at the preserved playhead. Obsolete verification cancels across rapid toggles
  and hiding the viewer; late results cannot install an old representation.
  Native close waits for the decoder queue to drain before file-access grants can
  be released, including concurrent and cancelled close callers.
- Proxy picture maps its recorded source stream to proxy stream zero, with original
  geometry for fit/fill/no-scaling. Audio retains original stream selections and
  sample-timed processing. Transient proxy choices never modify saved edits or
  original-only rendered export commands. Invalid native selections reject before
  changing the active session epoch/cache.
- Missing, stale, modified, legacy unhashed or unqualified proxies visibly fall
  back to originals. Qualified imported picture metadata, identical source/proxy/
  sequence cadence, matching aspect ratio, complete trim coverage and bounded
  rasters are required. Missing originals do not enable silent sequence playback;
  older projects without picture metadata fall back to HiRes. Source preview's
  separate explicit offline-picture behavior is retained.
- Verification and reproduction are recorded in
  [sequence proxy evidence](docs/evidence/sequence-proxies-20261013/README.md).
  Default Xcode builds still lack the native runtime. Shipping packaging,
  hardware A/V timing, broader formats and signed sandbox acceptance remain open.


### Compact track controls checkpoint (2026-10-13)

- Timeline track headers now expose an icon settings popover for custom names,
  separate family names, retained empty lanes and static audio gain. Blank custom
  names restore automatic numbering; family changes preserve custom siblings.
  Disabling retention on an empty lane follows the project cleanup preference.
- Audio gain accepts −96 to +24 dB, converts to linear amplitude in the existing
  track template, and offers explicit silence/restore-unity actions. Existing
  siblings and family creation templates stay independent; collision-created
  siblings inherit the originating track's settings. Changes are atomic app
  history entries and use the persisted shared render/native playback plan.
- Playback identity excludes track/family naming and retention flags. These edits keep
  active playback running; gain edits pause and rebuild at the current playhead.
  The toolbar, timeline edit actions, inspector apply actions and bin footer use icons with tooltips and
  accessibility labels. Development timing qualifications remain in documentation.
- Verification: 44 Python tests (eight optional skips), 93 XCTest cases (two
  optional skips), 87 Swift Testing cases, workspace policy smokes, the expanded
  host app-file smoke and an unsigned Debug app build pass. New checks cover
  naming independence, gain propagation/inheritance, invalid gain rollback,
  retention cleanup, saved settings, app undo/redo and playback identity.
  Xcode caches and bookmark services require host access. Native interactive
  acceptance and signed/runtime packaging remain open.

### Source range assembly checkpoint (2026-10-13)

- Source monitor now offers compact In, Out and clear icons with accessible labels,
  tooltips and range/duration readouts. Out is exclusive. I/O and Option-X defaults
  are remappable, source-scoped and protected during text entry.
- Marks remain per-asset working selections during the editing session. Bin/viewer
  selection and representation changes retain them; opening another document clears
  them. They do not dirty the document or add undo steps. Appended clip ranges are
  persisted through the existing document model.
- Qualified CFR picture snaps to exact source cadence. Other media uses microsecond
  positions without inventing a frame rate. Invalid and empty ranges preserve the
  previous marks. Still images retain their existing full five-second default.
- Both core placement paths accept validated source ranges. Linked components use
  identical offsets/durations, append timing uses the chosen extent, and explicit
  audio drafts capture their range for both preview and commit. Append remains one
  undoable edit. Finder drops continue to place the full imported source.
- Validation covers fractional source offsets, linked A/V ranges, selected audio
  routing, still extents, exact sequence duration, saved round trips, invalid-range
  rollback, source-scoped shortcuts, marking without document mutation and app
  append undo/redo. Full repository verification passes (95 XCTest cases with two
  existing skips, 87 Swift Testing cases, workspace policy smokes, Python checks
  and an unsigned Debug app build); the host app-file smoke also passes.
  Interactive source-player acceptance remains open.

### Signed helper integration checkpoint (2026-10-14)

- Prepared the user-supplied signed FFmpeg/FFprobe 9.0.2 arm64 pair for this
  checkout's persistent local Debug selection, retaining supplied build,
  qualification and notarization reports. Binary hashes match the report and
  both signatures validate with macOS host services.
- Existing packaging verifies capabilities, matching configurations, system-only
  dependencies and prepared hashes. An unsigned Debug build embeds both helpers
  without changing their signatures. Binaries and local configuration stay ignored.
- Production-bundle lookup and ProRes Proxy/H.264 generation pass exact fractional
  frame-count/raster/hash checks while preserving originals. The export-service
  smoke passes verified MOV, timing/geometry qualification, resampling, failure
  handling, destination protection and cancellation cleanup. Native runtime bridge
  packaging, signed sandbox app acceptance and complete release review remain open.

### Reproducible Xcode helper bootstrap checkpoint (2026-10-14)

- Fresh Debug and Release builds now fetch the pinned signed Apple Silicon
  FFmpeg/FFprobe 9.0.2 archive from a repository dependency release. Checked-in
  configuration records the URL, archive hash and both executable hashes; no
  machine-specific path or ignored local selection is required.
- Bootstrap validates archive/executable hashes and code signatures, then runs
  existing capability/dependency preparation and atomically publishes a cache.
  Cached builds validate all prepared files without network access. A file lock
  serializes concurrent bootstrap builds and failed preparation stays unpublished.
- Existing explicit prepared-directory overrides remain available. Set
  `AFC_BUNDLE_MEDIA_HELPERS=NO` to intentionally build without tools; removing the
  local Debug override returns to automatic bundling. Offline cache seeding accepts
  only the exact pinned archive. Download/integrity failures fail the build visibly.
- New tests cover archive rejection before execution, safe known-member extraction,
  binary hash checking, cache reuse without network, modified/missing/unexpected
  files and symlink rejection. Full Python checks pass with existing fixture skips.
- A disposable checkout without `.local` or `LocalMediaHelpers.xcconfig` passes
  unsigned Debug and Release builds. The Debug build downloads the actual pinned
  GitHub asset; its production-bundle proxy smoke passes both codecs. The real
  prepared cache is reusable with network calls blocked. GitHub CI now runs the
  Python tooling regression suite on PRs and main updates.

### NLE timeline shortcuts checkpoint (2026-10-14)

- Added remappable Shift+Z timeline fit with previous-zoom restoration and a
  toolbar button. Fit uses available viewport width and supports long sequences.
- Added Q/W ripple start/end trims at the playhead. Aligned linked components
  trim together; downstream clips on every track shift by the removed interval.
  Source edits, track timing, fade bounding and crossfade reconciliation commit
  as one undoable transaction. Earlier content and downstream gaps are preserved.
- The scoped first implementation refuses overlapping unrelated content,
  mismatched linked extents and linked groups straddling the ripple boundary.
  Implicit splitting of connected/overlapping clips remains future work.
- Existing source I/O and J/K/L commands were exercised again. New commands use
  the same text-entry protection, Settings remapping and conflict checks. Migration
  preserves existing custom bindings when a new default conflicts.
- Verification: shortcut model smoke, app-file smoke including dispatch,
  scope/playhead/undo/remapping/migration, five ripple core regressions and full
  EditorCore suite (100 tests, two opt-in tests skipped), normal unsigned Xcode build.

### System codec/cadence and exact timing checkpoint (2026-10-14)

- Carried exact rational source ranges, timeline placement and video instruction
  boundaries into system compositions. Timing outside CMTime's supported scale
  now fails visibly instead of rounding. Approximate audio envelope ramps remain.
- Replaced floating-point last-frame ceiling with integer rational arithmetic;
  the nine-frame 24000/1001 end-clamp regression requires frame eight.
- Added a retained decoded-barcode matrix: 12 passing ProRes/PCM, H.264/AAC and
  closed-GOP HEVC/AAC cases at integer and three fractional rates, 1,344 decoded
  seeks, black gaps, trim/layer boundaries, end clamps and live transport.
- Four open-GOP HEVC cases returned black at a trimmed boundary without player
  error. These remain unqualified; the optional negative matrix records failures
  and returns nonzero. Broader GOP/media, waveform parity, signed sandbox and
  physical A/V timing acceptance remain open.
- See [retained system preview evidence](docs/evidence/system-sequence-20261014/README.md).

### Empty timeline and localized Finder drop targets checkpoint (2026-10-14)

- Empty projects show the timeline ruler, playhead and display-only video/audio
  lanes before the first insertion. These guides do not create project tracks;
  the first Finder drop still starts at zero.
- Media-bin and timeline Finder drops now highlight only their own panel, using
  a subtle tint, outline and destination caption. Bin drops import into the
  selected bin; timeline drops import and place clips. Monitor and inspector
  drops are no longer treated as bin imports.
- Sequence matching, frame-rate presets, relinking, save-reminder actions and
  timecode submission use compact icons with tooltips and accessible names.
- Verification: unsigned macOS Debug build, timeline visibility smoke, expanded
  app-file smoke (including captured Finder placement, bin import destination,
  bookmarks and undo/redo), and diff checks passed. Native UI automation was
  unavailable (computer-use native pipe closed); visual layout and Finder hover
  transitions still need an on-screen check.


### System audio waveform and open-GOP diagnosis checkpoint (2026-10-14)

- Shared the production composition/audio-mix construction path with an offline
  decoded proof. Explicit initial volume fixes delayed clips briefly starting at
  unity before their gain or fade is applied.
- Retained 40 generated PCM/AAC mono/stereo cases at matching 44.1/48 kHz, totaling
  3,024,372 channel samples. Irregular sample-aligned cuts, gain, linear/equal-power
  fades, overlapping fade edges, source-handle crossfades and silence gaps pass
  explicit amplitude bounds. Nonlinear fades remain approximate. Separate AAC
  source decoding exposes codec differences; encoded boundaries remain unqualified.
- Open-GOP diagnosis distinguishes composition image-generator failures from
  source/player random-access failures near GOP boundaries at all four prior
  matrix rates. Sequential/24-frame preroll recovers selected synthetic frames,
  but no safe arbitrary-GOP bound or production seek fix was established.
- Verification: repository suite (47 Python tests, eight skipped; 100 core tests,
  two skipped), unsigned Debug build, existing decoded sequence/live transport smoke,
  new waveform proof and read-only subagent review passed.
- See [audio mix evidence](docs/evidence/system-audio-20261014/README.md) and
  [open-GOP diagnosis](docs/evidence/system-open-gop-20261014/README.md).
  Physical synchronization, signed sandbox grants and native runtime packaging remain open.


### System audio boundary admission and native packaging checkpoint (2026-10-14)

- Extended decoded audio evidence to 104 cases. All 52 matching-rate PCM/AAC
  cases pass unchanged amplitude bounds, including 12 AAC starts one sample
  before/at/after an interior 1,024-sample packet boundary. All 52 cross-rate
  mixes fail the same fidelity requirements; retained phase diagnostics show
  interior disagreement as well as cut-edge transients.
- System preview checks actual audio format descriptions and refuses differing
  or unknown source sample rates with an instruction to match the sequence rate
  or normalize media. The final proof decodes all 52 same-rate cases and verifies
  all 52 expected cross-rate refusals. Faithful resampling remains open.
- Added explicit native development app packaging: recursive dylib discovery,
  alias deduplication, collision/ambiguity rejection, thin-architecture checks,
  local-rpath removal, load-command relocation, hashes/deployment metadata,
  staged publication, ad-hoc signing and complete bundle signature verification.
- The packaged production controller passes original/proxy frame parity,
  nonzero switching, exact seeks, sample-clock play/pause, edit/replay and close
  with developer loader paths cleared. Actual dyld observations confirm the
  bundled runtime and no Homebrew/build dependencies. The local 17-library closure
  needs macOS 27 and unreviewed source/notices, so shipping Xcode integration,
  macOS 14 compatibility and release certification remain open.
- Verification: Python suite, 100 core tests (two skipped), workspace smokes,
  unsigned Debug app build, expanded host audio proof, relocated host controller
  smoke and six packaging regressions pass. Read-only subagent review led to
  staging-overlap and universal-binary refusal regressions.
- See [audio boundary/resampling evidence](docs/evidence/system-audio-resampling-20261014/README.md)
  and [native packaging evidence](docs/evidence/native-runtime-packaging-20261014/README.md).


### Compressed-audio source-boundary checkpoint (2026-10-14)

- Extended the generated decoded system mix matrix to ALAC and gapless MP3,
  source sample zero/one, final-sample boundaries and whole-source clips. PCM
  and ALAC pass all 40 cases each with unchanged float/sample budgets.
- AAC interior/packet cuts remain qualified; 16 of 20 new source-edge cases fail.
  Further 1,023/1,024/1,025-sample inset checks also fail in nine cases, so a
  one-packet margin is not a valid acceptance rule. Source-edge AAC remains open.
- MP3 fails 32/40 decoded cases, with amplitude errors reaching 0.218371749.
  System preview now refuses actual MP3 format descriptions with PCM/ALAC
  normalization guidance. Silent reader padding is retained separately from
  exact composition duration; no audible duration extension is claimed.
- Final source-edge checks pass 80 PCM/ALAC decoded cases and 40 MP3 refusals.
  Combined checks pass 72 decoded PCM/ALAC/AAC interior mixes, 72 cross-rate
  refusals and 40 MP3 refusals. Matrix completeness/uniqueness now has explicit
  validation and three regression tests.
- Verification: 61 Python tests (eight optional skips), 100 core tests (two skips),
  workspace smokes and unsigned Debug app build pass. Host media services are
  required for decoded audio evidence. Read-only subagent review rejected a
  proposed AAC margin based on retained decoder diagnostics.
- See [compressed-audio boundary evidence](docs/evidence/system-compressed-audio-20261014/README.md).

### Native runtime deployment compatibility checkpoint (2026-10-14)

- Native packaging parses both modern and legacy macOS deployment load commands;
  missing, malformed and other-platform metadata is refused. The packaged plist
  preserves stricter app requirements and declares at least the closure's real
  minimum OS, with semantic version comparison.
- Added an explicit deployment-target ceiling, also forwarded by the native
  workspace runner. Incompatible inputs fail before staging/output creation.
  The existing local runtime requires macOS 27; a 14.0 target is correctly refused.
- Re-packaged the actual controller with consistent macOS 27 plist/manifest
  metadata and verified its complete bundle signature. The controller still
  passes original/proxy frame parity, exact seeks, sample-clock playback, edit/
  replay and deactivation with developer loader paths cleared.
- Eleven packaging regressions pass, including full staged publication and
  pre-staging target refusal. Dependency notices/provenance remain unreviewed;
  macOS 14 libraries, release distribution and Xcode runtime integration stay open.
- See [native packaging evidence](docs/evidence/native-runtime-packaging-20261014/README.md).


### macOS 27 native Xcode integration and AAC status checkpoint (2026-10-14)

- Updated the app and both Swift packages to the user-approved macOS 27 baseline.
  The existing 17-library native closure now fits the deployment requirement.
- Added explicit ignored local native Debug selection and Xcode build/embed phases.
  SwiftPM builds the selected runtime with a macOS 27 arm64 target; module discovery
  handles both flat and Modules-directory product layouts. The actual workspace
  binary contains the native adapter, verified independently of linker flags.
- Runtime-only packaging checks architecture, deployment versions and output/input
  isolation, relocates every non-system dependency, signs nested libraries, and
  retains hashes, notices, supplied provenance and exact build/source selection.
  Failed preparation preserves previous outputs. Unrelated frameworks are refused.
- Turning selection off and rebuilding the same derived directory removes native
  symbols, link dependencies and owned embedded output. Release/archive native
  selection stays refused pending dependency/distribution review.
- Production controller qualification passes exact decoded seeks, proxy switching,
  play/sample-clock/pause, edited-plan replay and deactivation against the actual
  Xcode-embedded library closure, with developer loader paths cleared. Library
  hashes match the corrected native workspace; no Homebrew/build loads occur.
- System AAC playback remains available with visible source-edge approximation
  status from actual codec descriptions. Seek/play retain the notice without
  duplication; replacement with unaffected media clears it. The 184-case admission
  proof passes, while 25 known AAC boundary/inset failures retain unchanged bounds.
- Verification: 72 Python tests (eight optional skips), 100 core tests (two skips),
  workspace smokes, default Debug/Release builds, selected native Debug and disabled
  rebuilds, relocated controller smoke and decoded audio proof pass. Host Xcode and
  media/audio services are needed under the restricted tool sandbox.
- Native selection remains development-only. Complete notices/corresponding source,
  release signing/notarization, signed sandbox grants, compressed native audio,
  open-GOP system random access and measured A/V synchronization remain open.
- See [native Xcode evidence](docs/evidence/native-xcode-20261014/README.md) and
  [AAC status evidence](docs/evidence/system-compressed-audio-20261014/AAC-preview-notice.md).


### System fade-ramp fidelity checkpoint (2026-10-15)

- Replaced fixed 5 ms sampling with bounded curve-based ramp interpolation,
  splitting at envelope edges and accounting for overlapping fade products.
  Constant and separate linear regions now need only endpoint knots. A pure
  core plan records the mathematical volume error independently of engine output.
- Ramp timing uses a nanosecond timebase and shared rounded endpoints; invalid
  or collapsed intervals fail visibly. Initial delayed-clip volume is retained.
- The monitor composes nonlinear/overlapping fade and very-short-fade notices
  with AAC status, without duplicates, and clears them on unaffected media.
- All 40 existing generated PCM/AAC mix cases pass unchanged decoded budgets.
  All 16 new sub-5-ms equal-power/overlap cases fail despite finer interpolation,
  with maximum sample error 0.148034200. The optional negative matrix deliberately
  exits nonzero and retains these limits; short-fade playback is visibly approximate.
- Verification: 73 Python tests (eight optional skips), 103 core XCTest tests
  (two optional skips), 87 Swift Testing tests, workspace smokes, host live system
  playback/notice checks and unsigned Debug Xcode app build pass.
- See [retained fade-ramp evidence](docs/evidence/system-fade-ramps-20261015/README.md).
  Faithful short fades, wider codecs/resampling, hardware sync, signed media
  grants and native distribution qualification remain open.


### System still-image preview checkpoint (2026-10-15)

- Ordinary AVFoundation sequence preview now accepts single-frame PNG/JPEG images
  up to 4096 pixels per dimension. A cancellable background worker prepares one
  system-encoded ProRes 4444 frame; the composition stretches it to the exact
  timeline hold. Synthetic source In/Out points do not trim into that short movie.
- Fit/fill/no scaling, EXIF orientation and PNG transparency retain lower picture
  layers. No-scaling pad/crop centers at integer pixels for odd raster differences.
  There are no new viewer controls or document changes.
- Prepared images are reused within the backend session and removed on close;
  failed or cancelled preparations remove partial files. A 15-second encoder deadline, 512-image ceiling and 256 MiB temporary
  file budget bound preparation. Originals and rendered export remain unchanged.
- Generated host checks cover decoded seeks, fractional rates, transparent layered
  cuts, odd dimensions, live playback, malformed-image rejection, cancellation
  and temporary-file reuse/cleanup. Existing video/audio sequence smoke also passes.
- Repository verification passes: 73 Python tests (eight optional skips), 103 core
  XCTest tests (two optional skips), 87 Swift Testing tests, workspace smokes and
  an unsigned Debug Xcode app build. macOS 27 reports deprecations for legacy
  AVFoundation writer/composition APIs; they still compile and pass.
- Wide-gamut/HDR and ICC-aware preview/export color agreement, animated images,
  larger rasters, measured hardware sync and signed sandbox encoder access remain
  unqualified. See [retained still-preview evidence](docs/evidence/system-stills-20261015/README.md).


### System composition scheduling and native ALAC checkpoint (2026-10-15)

- System sequence preview now reuses picture tracks by interval concurrency,
  with separate still/movie pools to retain measured compositor color behavior.
  Exact boundary-event scheduling preserves upper-video precedence, transparent
  still stacks and gaps; hidden cuts with unchanged picture share instructions.
- Independent boundary-oracle tests cover randomized fractional edits, 1,000
  adjacent stills and 2,000 hidden layers. Host playback passes 128 adjacent cuts
  through one video track and 81 still seeks, including staggered alpha/video
  boundaries, orientation changes and holds followed by motion video.
- Optimized pure scheduling takes a median 10.24 ms for 5,000 pictures in a
  10,000-clip mixed project and 26.59 ms for 10,000 adjacent pictures. This excludes
  media I/O, composition insertion and UI; full project playback remains open.
- Native audio now admits zero-origin contiguous 16/24-bit mono/stereo ALAC at
  matching 44.1/48 kHz, with existing delay/padding/layout/shape guards. Eight
  independently patterned variants pass 313 ASan/UBSan checks including 68
  rejections. Native 48 kHz sequence/actor/offline audio output passes both depths,
  including backward/repeated seeks and decoder reset. Lossy native audio and
  resampling remain unsupported.
- Verification passes: 73 Python tests (eight optional skips), 106 core XCTest
  tests (two optional skips), 87 core Swift Testing tests, 46 native runtime tests,
  workspace smokes and the unsigned Debug Xcode app build. Broad color/hardware
  sync, release runtime attribution/signing and signed sandbox access remain open.
- The MPVKit reassessment records Converter's newer CoreAudio-fixed fork revision
  for future source fallback. Importer/transport integration and coexistence with
  the native FFmpeg runtime are still required; it is not added to this build.

See [composition evidence](docs/evidence/system-composition-20261015/README.md),
[ALAC evidence](docs/evidence/native-alac-20261015/qualification.md) and the
[MPVKit reassessment](docs/media-engine-audit.md#mpvkit-source-viewer-reassessment-2026-10-15).


### Source transport backend checkpoint (2026-10-15)

- Source J/K/L, exact seeks, source marks and representation-switch snapshots
  now use a main-actor backend interface. The AVFoundation adapter retains the
  current native presentation surface; transport commands no longer read or
  control AVPlayer directly.
- Backend replacement cancels outstanding transport work, pauses playback,
  cancels pending AVFoundation seeks and detaches the player item before media
  grants are released. Unpublished proxy backends close after obsolete seeks.
  Clearing source selection also clears pending play intent.
- Deterministic delayed-seek checks verify pause rejects a deferred restart,
  replacement stops reverse continuation, marks use backend coordinates and
  cleanup closes each released backend once. Existing real-source J/K/L and
  decoded proxy workspace checks pass, including original audio offsets, rapid
  switching, missing originals and preserved audio-tail positions.
- Verification: app-file smoke, proxy-workspace smoke, 73 Python tests (eight
  optional skips), unsigned Debug Xcode build and diff checks pass. Media/bookmark
  smoke checks require host services outside the restricted tool sandbox.
- This completes the transport isolation prerequisite for the MPV source viewer.
  Proxy composition preparation and import still use AVFoundation. MPV loading,
  broader-container metadata, track identity, native-runtime coexistence and
  distribution qualification remain open; no new formats are admitted here.


### MPVKit source-runtime and seek-failure checkpoint (2026-10-16)

- Added an offline isolated source proof against the clean cached CoreAudio-fixed
  MPVKit revision `400202b687841fb394cbf0ef59ad8c6fcfc1275b`. It selects the
  native macOS slices from explicit artifact roots, links the static closure,
  and retains archive/executable/source hashes and exact build/run commands.
- The grayscale timing matrix passes 24 load/play/pause/destroy cycles, 120 exact
  forward/backward/repeated seek coordinates and 100 decoded frame comparisons.
  Fixtures cover ProRes/PCM MOV, audio-first Matroska, H.264 B-frames/AAC and
  open-GOP HEVC/AAC. Video-only/audio-only selections and 12 missing/wrong-kind
  identity rejections pass. Loaded `ff-index`/kind resolves actual MPV track IDs.
- This cached runtime's attempted PNG capture fails. Encoder-free raw screenshots
  supply bounded packed RGB frames instead. Maximum grayscale mean RGB error is
  1.8199132 and peak 3 under mean/peak limits of 3/32.
- The unchanged colored diagnostic fails all 100 pixel comparisons (maximum mean
  5.2922454, peak 255); its reports and nonzero result are retained. Grayscale
  timing does not qualify color agreement, decoded audio, CoreAudio, GPU display,
  asynchronous callbacks, proxy composition, signed sandbox access or app linking.
- The static MPV FFmpeg 8.1.2 closure still needs symbol isolation/coexistence
  proof with the native timeline runtime's dynamic FFmpeg 9.0.2 before integration.
  Ordinary app source playback remains AVFoundation. Broader import metadata
  and distribution qualification remain open.
- Source backends now report failed seeks. The app pauses and clears pending
  play intent on a current failure, reports useful status and ignores obsolete
  failures; a failed restart cannot play from the previous source coordinate.
  Deterministic failure/cleanup checks extend the existing source transport smoke.

See [MPV source evidence](docs/evidence/mpv-source-20261016/README.md).

The seek-failure follow-up also gives explicit transport commands ownership of an
installed source backend: delayed restoration is cancelled, pending AVFoundation
seeks are interrupted on pause, and requested restoration coordinates are retained
when starting forward/reverse. This prevents a superseded same-player restore
from restarting playback or reporting failure over the new command.

Verification: 79 Python tests (eight optional skips), EditorCore XCTest/Swift
Testing suites, final host app-file and proxy-workspace smokes, and the unsigned
Debug Xcode app build pass. The full color diagnostic intentionally exits nonzero
with the failures above. Source/proxy smokes and Xcode require host bookmark/media
services and package caches outside the restricted tool sandbox.

### Private MPV dependency coexistence and rapid source commands (2026-10-16)

- Added an offline private-library proof for the pinned cached MPVKit closure
  alongside a freshly built `NativePlaybackRuntime`. The private MPV dylib
  exports exactly two proof functions; MPV/FFmpeg APIs remain hidden. Actual
  function addresses for five FFmpeg libraries stay inside the private 8.1.2
  image or the selected dynamic 9.0.2 libraries in both load orders.
- Native decoder output matches a standalone-process baseline byte-for-byte
  for 120 repeated picture/audio requests in each concurrent run. Further
  requests also match retained first-pass bytes, and PCM samples match external
  FFmpeg exactly. Timestamped native completions occur during MPV execution:
  747 for MPV-first and 752 for native-first in the retained run. All eight MPV
  lifecycle cycles and 40 decoded grayscale seek captures pass the unchanged
  coordinate and 3/32 RGB bounds.
- The proof builds/loads the real native Swift dylib but invokes its C decoder
  exports; Swift playback coordination, callbacks, GPU/CoreAudio, app integration,
  proxy composition, signing and sandbox grants remain open. A future app bridge
  must preserve the private export boundary. Ordinary source playback stays
  AVFoundation. See [coexistence evidence](docs/evidence/mpv-coexistence-20261016/README.md).
- Source proof reports now retain runtime versions, source color metadata,
  per-seek input/output color parameters, channel errors and exact peak pixels.
  Fresh grayscale captures pass 100/100; colored captures still fail 100/100
  at the original bounds. Chroma-boundary conversion disagreement is localized,
  not corrected or qualified. Representative scaler logs and both reports are
  retained in [source evidence](docs/evidence/mpv-source-20261016/README.md).
- Rapid forward/reverse source commands preserve an unfinished seek's requested
  coordinate across supersession. Cancelled forward/restoration tasks now check
  ownership before issuing a seek. Deterministic tests exercise pending seeks,
  a synchronous restore→L→L→J→L burst and L→K before task execution; only the final
  command can seek/play, and obsolete failures cannot change its state.

Verification: 88 Python tests (eight optional skips), EditorCore XCTest/Swift
Testing suites, host app-file and proxy-workspace smokes, unsigned Debug Xcode
build and diff checks pass. The colored matrix intentionally retains its nonzero
result. App/proxy smoke services and Xcode package caches require host access
outside the restricted tool sandbox.

### Private asynchronous MPV source bridge checkpoint (2026-10-16)

- Added an opaque private C source bridge with asynchronous load/track selection,
  exact seeks, pause/play, correlated command replies and bounded copied events.
  Explicit `ff-index`/kind resolution and selected-property verification precede
  OPENED. The dylib exports only nine bridge functions; no media-library API or
  borrowed MPV allocation crosses the ABI.
- A Swift 6 main-actor client passes 12 lifecycle cycles, 60 decoded seek captures,
  36 rapid commands, duplicate-ID rejection, the 64-request admission ceiling,
  EOF/recovery, disabled media types, corrupt-file/missing/wrong-kind rejection
  and 12 closes during loads/seeks. EOF caching and coalesced unchanged-position
  regressions are fixed. All captures meet unchanged grayscale RGB limits of 3/32.
- AddressSanitizer instruments the bridge and Swift client; cached archives remain
  uninstrumented. No foreign callbacks are installed: bounded polling avoids that
  lifetime boundary. Closing joins MPV workers before releasing the handle.
- Verification: 91 Python tests (eight optional skips), 106 core XCTest tests
  (two optional skips), 87 Swift Testing tests, workspace smokes and unsigned
  Debug Xcode build pass. Xcode requires host package-cache access.
- This is a development bridge proof, not an app backend change. Color, decoded
  MPV audio, CoreAudio/GPU presentation, hardware sync, proxy composition,
  Swift sequence coexistence, signed sandbox and distribution remain open.

See [asynchronous source evidence](docs/evidence/mpv-async-source-20261016/README.md).

### Asynchronous MPV and Swift sequence coordination checkpoint (2026-10-16)

- Added an offline combined proof using the private asynchronous source bridge
  and public `NativePlaybackSession` actor, including its serial decode worker.
  A separate native-only process provides byte-for-byte coexistence comparison;
  independent FFmpeg references check all picture/audio output.
- Each process decodes 120 native picture/audio pairs with caching disabled.
  Twelve plan replacements alternate source trims by six frames, and all 11 old
  epochs are rejected. MPV is loaded during concurrent plan replacement.
- Twelve source lifecycle/transport cycles and 60 MPV grayscale seek captures
  pass unchanged RGB bounds. Timestamp windows end before waiting for native
  completion and require real decode overlap in every source-command cycle.
- Swift source ownership now destroys the bridge on error/cancellation paths
  that bypass explicit close. Native task failures cancel/join work before the
  session's decoder-drain close; repeated close and closed admission pass.
- Verification: the full combined AddressSanitizer runtime proof and 94 Python
  tests (eight optional skips) pass; independent review found no remaining
  actionable harness issues. No application source/backend selection changed.
- This completes a finite Swift session coexistence prerequisite. In-flight
  edit/cancellation, MPV color/audio, CoreAudio/GPU presentation, proxy composition,
  hardware sync, signed sandbox access and distribution remain unqualified.

See [Swift coexistence evidence](docs/evidence/mpv-swift-coexistence-20261016/README.md).

### Native in-flight payload rejection and MPV transport checkpoint (2026-10-16)

- Extended the Swift coexistence proof with deterministic replace/cancel/close
  interleavings for both native video and audio. A proof-only wrapper holds a
  real decoded payload before the serial worker's cancellation checks, with a
  second request queued. Concurrent MPV transport completes while it is held.
- Both native-only and concurrent processes reject all 12 obsolete requests,
  skip queued decoding and retain no rejected payloads. Close waits for worker
  drain; construction/destruction counts verify every decoder is released,
  including replacement recovery decoders.
- Four recovery picture/audio pairs per process match independent FFmpeg exactly
  and match the native-only process byte for byte. The earlier 120 native pairs,
  60 MPV captures and per-cycle overlap checks also pass unchanged.
- Verification: final full AddressSanitizer proof, 95 Python tests (eight optional
  skips), independent review and diff checks pass. Snapshotted source hashes
  match the tested workspace. No production API or application backend changed.
- This qualifies the post-decode payload-return boundary, not interruption inside
  an active libavcodec call or unbounded edit stress. MPV color/audio, hardware
  presentation/sync, proxy composition, signed sandbox and distribution remain open.

See [in-flight evidence](docs/evidence/mpv-swift-inflight-20261016/README.md).

### MPV decoded source-audio boundary checkpoint (2026-10-16)

- Added an offline source-audio proof against the same pinned cached MPVKit
  candidate, with pre-decoder container stream selection, raw float PCM output
  and independent FFmpeg references. Two distinct audio streams in audio-first
  containers exercise actual `ff-index`/MPV audio-ID mapping.
- All eight natural PCM/ALAC selections match reference samples exactly at
  44.1 kHz mono and 48 kHz stereo. The broader matrix passes only 30/96 cases:
  PCM 12/24, ALAC 18/24 and AAC/MP3 0/24. Explicit ranges expose sample-count
  and content failures; no alignment, padding or tolerance relaxation is applied.
- All 16 wrong-kind/missing-stream selections are explicitly rejected before
  audio output. Five comparison regression tests cover sample loss, shifts,
  channel swaps, wrong content, amplitude bounds and nonfinite/malformed data.
- Verification: the final AddressSanitizer client completes the full diagnostic
  matrix with its expected nonzero qualification result; 100 Python tests pass
  with eight optional skips. Independent review found no blocking harness issues.
- This is a completed diagnostic checkpoint, not broad decoded-audio or live
  source qualification. MPV range accuracy and compressed-audio boundaries need
  resolution before a faithful source backend can be claimed. CoreAudio/GPU,
  hardware synchronization, proxy composition, signed sandbox access and runtime
  distribution remain open. No production app code or backend selection changed.

See [decoded-audio evidence](docs/evidence/mpv-audio-20261016/README.md).


### MPV audio range and demuxer control checkpoint (2026-10-16)

- Added independent timestamp/integer-filter range and automatic/lavf demuxer
  controls to the existing offline source-audio proof. Defaults retain the
  original options, fixtures, stream identities and exact comparison policy.
- Four complete AddressSanitizer matrices retain 384 comparisons and 64 explicit
  wrong-kind/missing-stream rejections. Timestamp/automatic repeats 30/96;
  timestamp/lavf passes 34/96; integer-filter/automatic passes 48/96; combining
  integer filtering with lavf passes 72/96. Every rejection passes.
- Integer filtering passes all PCM/ALAC ranges exactly. Forced lavf passes all
  four natural MP3 selections; with integer filtering all 24 MP3 ranges match
  reference samples exactly. Captured output is never aligned, padded or repaired.
- AAC remains 0/24 in every control. Retained external packet-edge metadata
  records priming/padding information without claiming its embedded-runtime
  handling or the cause of AAC content failures is resolved.
- Verification: 102 Python tests (eight optional skips), four full diagnostic
  runtime matrices, independent implementation review and diff checks pass.
  Each broad audio qualification result intentionally remains nonzero for AAC.
- The integer control decodes from source zero, so it does not qualify efficient
  random access or asynchronous seeks. No production backend or format admission
  changes. Faithful AAC, interactive source seeking, CoreAudio/GPU, hardware sync,
  proxy composition, signed sandbox access and distribution remain open.

See [audio control evidence](docs/evidence/mpv-audio-controls-20261016/README.md).

### MPV AAC decoder and initial-seek isolation checkpoint (2026-10-16)

- Added explicit AAC decoder controls with fallback disabled and observed
  selection verification. Three complete AddressSanitizer matrices retain
  288 comparisons and 48 successful stream-identity rejections. Software `aac`
  and `aac_fixed` retain AAC failures; `aac_at` fails initialization with
  AudioToolbox error -9405. PCM/ALAC/MP3 remain 24/24 each in every matrix.
- Added a standalone direct embedded-library AAC reference using the same cached
  closure. Without seeking, all 20 bounded reference ranges match independent
  FFmpeg within the unchanged 1e-6/1e-5 amplitude limits. Natural output retains
  extra 820/384 tail samples, so all four natural exact-count checks fail.
- A selected-stream backward seek to zero before direct decoding reproduces all
  24 MPV AAC captures byte for byte. The unseeked decoder reports 1024 skipped
  priming samples; the seek control reports none. This isolates a seek/preroll
  failure independently of MPV's decoder/filter/output path; prediction/noise
  state details and a reliable correction remain unproven. Tail discard-padding
  handling remains a separate unresolved boundary.
- Verification: final full AddressSanitizer matrix with both direct reference
  modes, 103 Python tests (eight optional skips), independent implementation
  review and diff checks pass. The broader audio qualification intentionally
  remains nonzero, with AAC 0/24 and PCM/ALAC/MP3 24/24 each. No production app
  code, backend or format admission changed.
- Faithful AAC, efficient interactive source seeks, CoreAudio/GPU presentation,
  hardware sync, proxy composition, signed sandbox and distribution remain open.

See [AAC seek evidence](docs/evidence/mpv-aac-seek-20261016/README.md).

### Embedded AAC priming and explicit frame-duration checkpoint (2026-10-16)

- Extended the direct embedded-library AAC diagnostic with an observed-first-packet
  backward seek, independently of the existing zero-seek and unseeked controls.
  All four selected streams return PTS -1024 and restore the 1024-sample priming
  skip; complete output hashes match unseeked decoding exactly.
- Retained first/last packet and final decoded-frame boundary metadata. The last
  1024-sample frames report durations of 204 samples at 44.1 kHz and 640 at 48 kHz,
  accounting for all prior 820/384 excess samples without discard-side metadata.
- Added a separate explicit-frame-duration diagnostic, requiring exact sample
  conversion and refusing incompatible durations. No nominal source duration,
  comparator alignment, padding or capture repair is used.
- Combined first-packet/duration direct decoding passes all 24 AAC reference
  comparisons, including four natural outputs, under unchanged sample-count and
  amplitude bounds. The actual MPV matrix remains PCM/ALAC/MP3 24/24 each and
  AAC 0/24, with all 16 selection rejections passing and overall exit 1 retained.
- AddressSanitizer matrix, 36 MPV Python regression tests and independent review
  pass for this proof scope. App source playback remains AVFoundation. Efficient
  interactive AAC seeks, applying the controls inside MPV, broader streams,
  CoreAudio/GPU presentation, hardware sync and distribution remain open.

See [AAC priming/frame-duration evidence](docs/evidence/mpv-aac-preroll-20261016/README.md).

### MPV basic MOV edit-list and bounded AAC checkpoint (2026-10-16)

- Added an explicit `--mov-edit-list default|basic` control to the offline MPV
  audio proof. Basic mode sets lavf `advanced_editlist=0`, retaining basic edits;
  forced lavf is required and the runtime-reported control is verified.
- Two complete AddressSanitizer matrices retain 192 unchanged comparisons and
  32 successful invalid-stream rejections. Default repeats 72/96; basic passes
  92/96, including all 20 bounded AAC ranges and PCM/ALAC/MP3 24/24 each.
- Actual basic-mode AAC captures equal independent unseeked embedded-decoder
  outputs byte for byte across all 24 cases. Bounded AAC samples match external
  FFmpeg under unchanged 1e-6/1e-5 amplitude bounds. MOV fixture hashes match
  across modes; each run retains its own MP3 Matroska fixture hashes.
- All four natural AAC outputs retain exact-count failures: 820 extra samples
  at 44.1 kHz and 384 at 48 kHz. No capture alignment, padding or repair is used;
  both broad qualification runs intentionally exit 1.
- Verification: 105 Python tests (eight optional skips), both runtime matrices,
  independent implementation review and diff checks pass for this proof scope.
  App source playback remains AVFoundation. Natural AAC tail handling, complex
  edit lists, efficient interactive seeks, hardware presentation/sync, proxy
  composition, signed sandbox access and distribution remain open.

See [MOV edit-list evidence](docs/evidence/mpv-mov-edit-list-20261016/README.md).

### MPV timestamp seek-preroll boundary checkpoint (2026-10-16)

- Added an explicit timestamp-only `--seek-offset` control to the offline audio
  proof, setting high-resolution seek and demuxer preroll before initialization.
  Runtime offset readback must match MPV's float storage exactly; nonfinite,
  negative, overflowing and integer-filter combinations are rejected.
- Three complete AddressSanitizer matrices retain 288 decoded comparisons and
  48 successful missing/wrong-kind stream rejections. With forced lavf/basic MOV
  handling, zero preroll passes 38/96; 100 ms and 500 ms each pass 40/96.
  PCM remains 12/24, ALAC 18/24 and MP3 4/24. AAC improves from 4/24 to 6/24.
- Preroll fixes the two 44.1 kHz ranges starting at sample 1024, with unchanged
  amplitude bounds. Later AAC tail ranges still fail content parity, and several
  timestamp cuts retain sample-count differences. No capture alignment, padding,
  trimming or reference adjustment is applied.
- All four natural AAC outputs are byte-identical across the three controls and
  retain 820/384 extra tail samples. MOV fixture hashes match across runs. The
  earlier 92/96 integer-filter result still applies only to decoding from zero;
  efficient sample-exact seeking and natural AAC EOF remain unresolved.
- Verification: 107 Python tests (eight optional skips), all three runtime
  matrices, source-hash checks, independent review and diff checks pass for this
  diagnostic scope. Broad qualification intentionally exits 1. Application source
  playback remains AVFoundation; no backend or format admission changes.

See [timestamp seek-preroll evidence](docs/evidence/mpv-seek-preroll-20261016/README.md).


### MPV absolute-PTS loading-seek checkpoint (2026-10-16)

- Added a separate `pts-filter` audio control: playback starts before the requested
  cut and absolute integer `atrim` timestamps preserve MPV's existing audio input
  timebase with `fix-pts=no`. The separate `--filter-preroll` is finite, bounded,
  mandatory in this mode and refused elsewhere. Existing controls retain defaults.
- Two complete AddressSanitizer matrices retain 192 exact comparisons and 32
  successful invalid-stream rejections. Zero preroll passes 60/96; 500 ms passes
  68/96. PCM and ALAC each pass 24/24 byte-exactly in both controls, including
  nonzero tail seeks. AAC improves from 8/24 to 16/24; MP3 remains 4/24.
- Bounded AAC counts are exact, but nonzero tail content still fails. Natural
  AAC remains byte-identical across controls with 820/384 excess samples. MOV
  fixture hashes match across runs; no comparator alignment or capture repair.
- A bounded nonblocking successful-EOF drain preserves MPV decoder logs that can
  otherwise be overtaken by the EOF event. Missing/ambiguous decoder identity
  still rejects the proof; invalid-stream/error paths retain immediate teardown.
- Verification: all 108 Python tests pass (eight optional skips), both final
  runtime matrices complete without client failures, source hashes match,
  legacy timestamp/integer AAC spot checks retain byte parity, and independent
  review/diff checks pass. Broad qualification intentionally exits 1.
- This qualifies only the measured generated loading ranges. Early preroll cuts
  clamp to zero; later tail ranges exercise nonzero seeks. No decoder-work bound,
  arbitrary timestamp, asynchronous in-place seek, hardware presentation/sync,
  proxy composition, signed sandbox or distribution qualification is claimed.
  Application source playback remains AVFoundation.

See [absolute-PTS seek evidence](docs/evidence/mpv-pts-seek-20261016/README.md).

### AAC encoder PNS and nonzero loading-seek checkpoint (2026-10-17)

- Added an explicit fixture-only `--aac-pns default|on|off` control to the offline
  MPV audio proof. Defaults preserve the original encoder command; other codecs,
  runtime decoding, requested cuts and comparison bounds remain unchanged.
- Three complete AddressSanitizer matrices retain 288 comparisons and 48 passing
  invalid-stream rejections. Default/on each pass 68/96, with identical AAC fixture
  and capture hashes. PNS-off passes 72/96; AAC improves from 16/24 to 20/24.
- All 20 bounded PNS-off AAC ranges match independent FFmpeg bytes exactly,
  including four nonzero tail seeks. This isolates PNS-enabled fixture seek
  divergence and supports decode-history dependence; it does not repair existing
  AAC, qualify arbitrary streams or prove a sufficient fixed preroll.
- Four natural AAC outputs in every mode retain 820/384 excess samples. MP3 stays
  4/24; all broad qualification runs intentionally exit 1. Small MP3 sample shifts
  and millisecond packet timestamps motivate a separate same-packet container
  timebase control, with no cause or correction yet qualified.
- Verification: 109 Python tests (eight optional skips), all runtime matrices,
  source/fixture/capture hash checks, independent implementation review and diff
  checks pass for the diagnostic scope. App source playback stays AVFoundation.
  Existing PNS-enabled AAC seeks, natural EOF, hardware presentation/sync, proxy
  composition, signed sandbox access and distribution remain open.

See [AAC PNS evidence](docs/evidence/mpv-aac-pns-20261017/README.md).

### MP3 same-packet container and loading-range checkpoint (2026-10-17)

- Added an explicit MP3-only `--mp3-container matroska|mov-remux` fixture control.
  MOV mode requires external FFprobe and verifies stream identities, formats and
  identical ordered packet payloads for every stream before decoding. Defaults
  preserve previous commands; fresh references are decoded per container.
- Three complete AddressSanitizer matrices retain 288 comparisons and 48 passing
  invalid-stream rejections. Absolute-PTS/500 ms preroll repeats 68/96 in Matroska
  and passes 82/96 in MOV. MP3 improves from 4/24 to 18/24 byte-exact comparisons;
  natural EOF and both 44.1 kHz nonzero tail seeks remain failures. Other codecs
  retain PCM/ALAC 24/24 and AAC 16/24.
- MOV integer filtering from zero passes 68/96: PCM/ALAC 24/24, AAC 20/24 and
  MP3 0/24. All bounded MP3 counts are exact but content fails. Every broad audio
  qualification run intentionally exits 1; no alignment or capture repair is used.
- Packet timebases change from 1/1000 to reciprocal sample rate, but skip/padding
  metadata also changes. Independent MOV reference counts differ from Matroska
  by 1 sample at 44.1 kHz and 48 samples at 48 kHz. Full packet manifests and
  failed original-reference comparisons preserve that confound: this is not a
  pure timebase isolation or a correction for existing sources.
- Verification: 111 Python tests (eight optional skips), all runtime matrices,
  source/capture hash checks, independent implementation review and diff checks
  pass for this diagnostic scope. Production app playback remains AVFoundation.
  Further work must preserve gapless metadata while varying timing and resolve
  natural EOF and nonzero tail content before claiming faithful MP3 seeks.
  AAC PNS-enabled seeks, hardware presentation/sync, proxy composition, signed
  sandbox access and runtime distribution also remain open.

See [MP3 container evidence](docs/evidence/mpv-mp3-container-20261017/README.md).

### Native runtime on MPVKit FFmpeg checkpoint (2026-10-30)

- `NativePlaybackRuntime` now links FFmpeg n9.0.2 statically from the pinned
  `aagedal/MPVKit` `MPVKit-GPL` product (7f5d3f5, `aagedal-1.1.0-n9.0.2-editor.1`),
  replacing the pkg-config system library. The Debug opt-in is
  `scripts/configure-native-playback.py --enable`; the build writes MPVKit notices
  and provenance itself, and the embedded closure is the runtime dylib alone.
- The previous playback-only release lacked the PNG/JPEG pipe demuxers (FFmpeg 9
  renamed them), NUT, and the DV, v210, CineForm, QuickTime RLE, TIFF and JPEG
  2000 decoders. `editor.1` adds them plus PNG/MJPEG encoders for MPV screenshots.
  Stills opened through `image2` are still accepted only with a matching
  signature and one parsed image.
- Verification: 46 runtime tests, 111 Python tests (eight optional skips), the
  native app-controller smoke and a native-enabled Debug app build pass. The
  barcode sequence parity proof fails explicitly because its QuickTime RLE
  fixture has no decoder; rerun it once the fork adds the editorial decoders.

### FFmpeg import probing checkpoint (2026-10-31)

- With the native runtime selected, movies AVFoundation cannot open (NUT, MXF,
  Matroska, …) are probed by libavformat (`NativeMediaProbe`) and import unconverted
  when the native decoder can play every stream: proven constant video cadence,
  sample-exact contiguous PCM/ALAC, zero-origin streams, and a successful decoder open.
  Everything else, and every non-native build, converts as before. MPEG program/
  transport streams and animated images keep converting.
- The probe yields `inspect`'s model from packet timing: FFmpeg stream indices, exact
  durations and start offsets, cadence-proven `VideoSourceFormat`, FFmpeg-order channel
  layouts and tmcd/MXF/tag timecode. Timeline thumbnails and waveforms fall back to
  FFmpeg (`NativeMediaPreview`). The Source viewer shows one native frame and points to
  the Sequence monitor. Analysis stabilisation refuses with a pointer to the deshaken
  copy. Export, proxies and relink were already FFmpeg-based or reuse import. See
  [unconverted imports](docs/sequence-monitor.md#unconverted-ffmpeg-imports-native-runtime).
- Parity: 11 files both readers open match `inspect` exactly (durations, rates, layouts,
  offsets, NDF/DF/23.976 timecode), with two pinned reader differences. AVFoundation
  puts an empty-edit MOV audio offset at 0, while FFmpeg's value is the one export
  aligns by. Audio-only AAC/Opus priming durations also differ. Of 7 native-only
  fixtures, NUT FFV1/UT Video and MXF DNxHR import unconverted and play and export
  natively. Matroska (ms clock), Opus and offset audio convert.
- Verification: 50 runtime tests, 111 Python tests (eight optional skips), the import
  probe smoke, the 29/29 native sequence parity proof, and Debug app builds with the
  native runtime enabled and disabled all pass.
- Not covered: image sequences (TIFF/DPX/EXR) need an import UI with a frame rate.
  Matroska at NTSC rates and compressed audio (Opus/Vorbis/FLAC/AAC) need native
  decoder changes before they can skip conversion. The 5-second probe budget sends
  very long native-only files to conversion.


### MPV Source viewer checkpoint (2026-10-31)

- With the native runtime, the Source viewer plays originals AVFoundation cannot
  (`isPlayable` false) through libmpv: unconverted FFmpeg imports and MOVs AVFoundation reads
  but cannot decode. A new `MPVSourceBackend` sits behind `SourcePlaybackBackend`; AVPlayer
  keeps everything AVFoundation plays and normal builds are unchanged. With a verified proxy,
  Proxy mode shows proxy picture plus the original's sound (an external audio file in MPV);
  before, that was proxy picture without sound. If libmpv cannot open the media, the previous
  single-frame / silent-proxy fallbacks remain.
- `NativeSourcePlayer` (runtime) grows the `mpv-source-bridge.c` proof into the app: explicit
  `ff-index`/kind track resolution, software render API on its own queue, raw container time.
  Picture seeks land on the asset's first video stream's FFmpeg frame grid, including its start
  offset, and report the shown frame's time, so marks equal export's trim frames. Asset zero is
  the earliest stream start, as in the import probe. Sound is the first audio stream by FFmpeg
  index; further streams are not mixed in.
- Rechecked on n9.0.2: tagged colour now matches FFmpeg's conversion in flat areas (mean ≤ 0.005,
  peak 3), with chroma-edge differences from the upsampling filter. The unchanged audio proof's
  timestamp mode, which the viewer uses, repeats 30/96 (AAC and MP3 0/24); the best filter control
  improves from 68/96 to 72/96 (86/96 with MP3 in MOV) as natural AAC EOF becomes exact. Nonzero
  AAC tail seeks still fail. See [MPV Source viewer evidence](docs/evidence/mpv-source-viewer-20261031/README.md).
- Verification: 59 runtime tests (9 new `SourcePlayerTests`: NUT/MXF frame indices against FFmpeg
  decodes, offsets/origins, stream identity, proxy with external audio, superseded seeks, teardown,
  colour), the new `scripts/source-viewer-native-smoke.py` through `EditorStore`, 111 Python tests
  (eight optional skips), the import probe smoke, the 29/29 native sequence parity proof on a fresh
  render-plan fixture, the proxy-workspace smoke, and Debug app builds with the native runtime
  enabled and disabled. The app-file smoke passes only without its OTIO block (lines 105–119),
  which predates this work: since `2b40f45` OTIO export warns with a modal alert instead of
  refusing, so the unmodified smoke waits on that alert.
- Not covered: GPU presentation and VideoToolbox decoding (software rendering, fitted within
  1920×1080), mixing several audio streams, sample-exact source audio after seeks, untagged colour
  (MPV's matrix guess), and the two FFmpeg copies the app ships (helpers and runtime dylib).

### Single FFmpeg copy audit checkpoint (2026-10-31)

- Audit: the bundled helpers and the runtime's MPVKit FFmpeg are the same release (9.0.2 /
  `n9.0.2`) and licence (GPL v3, no nonfree), but configured very differently. The helpers are a
  "full" build (199 encoders, 484 filters, 183 muxers, x264/x265/VPX/AOM/whisper, …). The
  runtime keeps MPVKit's playback allow-lists (45 encoders, 67 filters, 13 muxers) and lacks
  `prores_ks`, `libx264`, 20 export filters, `deshake`, `afftdn`/`amerge` and the WAV/f32le
  muxers. In the other direction, the runtime decodes only AVS3 (`libuavs3d`) that the helpers
  cannot. See [two FFmpeg copies](docs/media-helper-packaging.md#two-ffmpeg-copies-2026-10-31).
- Consolidation was not possible in this step. In-process export through libavfilter would
  rebuild `fftools` (the command lines are the export parity contract), lose process isolation
  and terminate-to-cancel, and still leave Release on the helpers, since the runtime is
  Debug-only. Linking the helpers against the runtime dylib would load libmpv/MoltenVK in every
  helper, still lack the components, and require shipping the runtime in Release. The sound
  path is one MPVKit fork build whose allow-lists cover `Configuration/FFmpegRequirements.json`
  (plus x264) and that also publishes its already-built `ffmpeg`/`ffprobe` as the pinned helper
  asset. That changes what Release ships, so it waits for a product decision. Only shared
  `libav*` dylibs, a further fork change, would also save the ~120 MB of static helpers.
- Implemented: `Configuration/FFmpegRequirements.json` declares, per feature, what the app's
  helper command lines use (export, proxies, conversion, stabilise, noise reduction).
  `prepare-media-helpers.py` now requires all of it, up from a filter subset plus ProRes/PCM;
  the pinned pair passes. `scripts/ffmpeg-copies-audit.py` compares both copies. The native
  Debug embed phase runs it against the bundled listings, fails on version or licence drift or
  missing helper components, and writes `NativeRuntime/ffmpeg-copies.json`. Unconverted
  native import now also requires every stream's codec in the helpers' `Helpers/decoders.txt`,
  so media the runtime admits stays exportable (AVS3 falls back to conversion).
- The app-file smoke's stale OTIO expectation is fixed: it checks the exporter's still-omission
  warning instead of waiting on the "Export Anyway" alert, and passes unmodified.
- Verification: 119 Python tests (eight optional skips), 59 runtime and 95 EditorCore tests, the
  import probe smoke (now including the helper decodability guard), the source viewer smoke,
  the 29/29 native sequence parity proof on a fresh render-plan fixture, the proxy-service,
  export-service, proxy-workspace and app-file smokes, the real-media check (H.264 and ProRes
  422 HQ from MOV/MP4/DNxHR sources), and Debug app builds with the native runtime enabled
  (audit embedded) and disabled.
