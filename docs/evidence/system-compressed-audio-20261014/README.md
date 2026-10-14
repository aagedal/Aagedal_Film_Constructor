# System compressed-audio boundaries — 2026-10-14

The production AVFoundation composition/audio mix is decoded with
`AVAssetReaderAudioMixOutput` and compared sample by sample with canonical FFmpeg
renders. This extends the existing generated mono/stereo 44.1/48 kHz fixtures to
ALAC/M4A, gapless MP3, source-head and source-tail cuts, and whole-source ranges.
The sources remain two-second distinct-channel tones, not real-world recordings.

## Decoded findings

`before-mp3-guard-results.json` retains 172 cases: PCM 40/40, ALAC 40/40,
AAC 36/52 and MP3 8/40 pass. The existing bounds remain unchanged: 0.000002
for PCM/ALAC constant gain, one s16 code value (1/32768) for AAC/MP3 constant
gain, and 0.0001 for approximate fade ramps. Every planned sample participates in
pass/fail; no lag correction or exclusion of edit edges is applied. ALAC lossless
constant cases have the same tight bound as PCM.

The new edge cases begin at source sample zero or one, end at the source's final
sample or one sample before it, or use the entire two-second source. Each has
constant gain 0.65, a 6,001-sample timeline delay, trailing silence and a muted
2,001-sample tail. Regular clips retain the earlier 35,003-sample length;
whole-source clips use 88,200/96,000 samples. Existing constant/fade/crossfade and
AAC packet-boundary cases remain included. Exact composition duration is now
checked in addition to decoded PCM length.

AAC fails 16 source-edge cases, with maximum amplitude disagreement 0.001224943.
Previously qualified interior and packet cuts still pass. `aac-insets-results.json`
also tests cuts 1,023/1,024/1,025 samples away from each source edge: only 15/24
pass. A one-access-unit exclusion cannot establish a faithful AAC subset. These
failures are retained, and AAC source-edge fidelity remains unqualified; the app
continues its existing AAC preview behavior. Use normalized PCM/ALAC when faithful
source-edge audio is required. No error budget was raised to accept these cases.

MP3 fails 32/40 cases, including mono interior trims. Maximum amplitude
disagreement reaches 0.218371749. Sixteen cases emit 529 reader frames beyond the
planned end; all those extra samples are silent, and every composition duration
remains exact. This diagnoses reader padding, not demonstrated audible duration
extension. The proof records the overflow, compares the planned samples, and
fails the strict extent check rather than aborting before later cases.

## Production admission and verification

System preview now checks the actual source audio format description and refuses
MP3 with guidance to normalize it to PCM or ALAC. File extensions are not used
for codec admission. Import and rendered export continue using their existing
paths. PCM, ALAC and existing AAC preview behavior remain available; cross-rate
system audio is still refused.

`after-mp3-guard-edges-results.json` passes all 120 cases: 80 decoded PCM/ALAC
cases and 40 explicit MP3 refusals. Reproduce with a new output directory:

```sh
python3 scripts/system-audio-mix-proof.py /absolute/path/ffmpeg \
  /private/tmp/new-system-codec-edges \
  --include-lossless-and-mp3 --include-edge-cuts --expect-mp3-rejection
```

`after-mp3-guard-combined-results.json` passes all 184 cases: 72 decoded PCM/ALAC/
AAC mixes, 72 cross-rate refusals and 40 MP3 refusals. It retains AAC interior
packet checks and extends cross-rate refusal checks to ALAC:

```sh
python3 scripts/system-audio-mix-proof.py /absolute/path/ffmpeg \
  /private/tmp/new-system-codec-admission --include-aac \
  --include-lossless-and-mp3 --include-packet-cuts --include-resampling \
  --expect-resampling-rejection --expect-mp3-rejection
```

The runner refuses missing, duplicate or unexpected case names. Three integrity
regressions cover empty/partial matrices, duplicates and omitted optional cases.
The diagnostic edge/inset runs deliberately exit nonzero; adding `--include-aac`
and `--include-edge-cuts` to a new run reproduces the unresolved AAC failures.
The pre-guard MP3 diagnosis requires the backend before its new refusal.

Results retain commands (in the matching `*-mixes.json`), hashes, sample counts,
amplitude bounds, exact duration and reader overflow diagnostics. Full media and
logs remain under `/private/tmp/afc-system-codec-edges-complete-20261014`,
`/private/tmp/afc-system-aac-inset-20261014`,
`/private/tmp/afc-system-codec-admission-20261014` and
`/private/tmp/afc-system-audio-admission-combined-20261014`.
The restricted reader failed with AVFoundation -11800/-1; host media services
were required. This proof does not qualify live audio seeks, physical output,
A/V synchronization, arbitrary AAC profiles/containers or signed sandbox grants.
