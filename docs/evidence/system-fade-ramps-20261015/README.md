# System preview fade ramps — 2026-10-15

The production system backend now samples volume ramps from the canonical fade
curves using a second-derivative interpolation bound. It splits at each fade
edge, accounts for multiplied overlapping envelopes, and uses only endpoint
knots for constant gain and separate linear fades. Normal preview gain has a
maximum mathematical volume interpolation error of 0.0001. This is a bound on
the interpolated envelope, not a guarantee about AVFoundation's decoded output.
Work is capped at 4,096 subdivisions per smooth interval; the core plan records
the actual bound if the cap prevents the requested tolerance.

Ramp timestamps use a nanosecond timebase, with adjacent durations computed from
the rounded endpoints. Collapsed or invalid timestamps fail visibly. Delayed
clips still establish their initial volume before playback begins.

The monitor discloses curved/overlapping fade approximation and adds a stronger
notice for non-muted fades of 5 ms or less. Notices compose with the existing AAC
warning, do not duplicate across clips/seeks, and clear when unaffected media
replaces the sequence. The 5 ms notice threshold is a conservative UI policy,
not a measured cutoff above which all fade durations are qualified.

## Decoded results

[results.json](results.json) retains all 56 generated matching-rate PCM/AAC cases
and their reference/system PCM hashes. [decoded-matrix.log](decoded-matrix.log)
retains the command's pass/fail output.

- All 40 existing mono/stereo, 44.1/48 kHz cases pass their unchanged bounds:
  constant gain, linear fades, equal-power fades, overlapping fades and crossfades.
  The largest passing sample error is 0.000089499 against a 0.0001 fade budget.
- All 16 new short-fade cases fail those unchanged budgets. They cover 47-sample
  equal-power edges and a 97-sample clip with overlapping 73-sample edges, for
  PCM/AAC, mono/stereo and both rates. The largest sample error is 0.148034200.
- The negative matrix deliberately returns nonzero. These cases remain
  unqualified; finer envelope ramps do not repair the system renderer's behavior.
  Playback remains available with a specific visible notice. Sample-exact short
  fades require further engine work and qualification.

Reproduce on a macOS host with Xcode and media services, using a new output path:

```sh
python3 scripts/system-audio-mix-proof.py /absolute/path/to/ffmpeg \
  /private/tmp/afc-system-fade-diagnostic --include-aac --include-short-fades
```

Omit `--include-short-fades` for the 40-case passing PCM/AAC matrix. Raw media and
PCM outputs stay in the generated output directory rather than the repository.

## Other verification

- 73 Python tests pass (eight optional skips), including short-matrix completeness.
- 103 XCTest core tests pass (two optional skips), plus 87 Swift Testing tests.
  Dense interpolation checks cover both curves, disabled/single/overlapping
  fades, second/microsecond/nanosecond scales, long clips, invalid inputs and caps.
- Workspace lifecycle, shortcut, launch, timeline visibility and save-protection
  smokes pass. Host system playback smoke passes decoded seeks, live play/pause,
  notice persistence, short-fade notice and clearing on unaffected PCM media.
- Unsigned normal Debug Xcode app build passes. Xcode package resolution and
  AVFoundation decoding require host access under the restricted tool sandbox.

Broader codec boundaries, resampling, hardware synchronization, signed sandbox
media grants and native distribution qualification remain open.
