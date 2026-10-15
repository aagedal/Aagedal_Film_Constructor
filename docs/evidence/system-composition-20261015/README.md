# System composition scheduling — 2026-10-15

Ordinary sequence preview now reuses composition tracks for clips whose time
ranges do not overlap. Prepared stills and motion video have separate reuse pools;
audio retains independent tracks and envelope parameters. Each pool requires only
its maximum simultaneous picture count. Editorial track IDs and project edits
remain independent of these temporary compositor lanes.

`VideoCompositionPlan` consumes the canonical render plan. Exact rational boundary
events and priority heaps replace the previous full-picture scan and layer sort
at every cut. The frontmost motion-video layer hides lower picture; transparent
stills retain lower layers. Consecutive intervals with unchanged visible clip
identities share one instruction, including hidden cuts. The sweep visits visible
stills rather than every hidden clip; a fully overlapping transparent stack can
still require quadratic output. It does not impose a new media-count limit.

## Verification

- Three core tests compare every boundary against an independent exhaustive
  visibility oracle over twelve randomized fractional-time fixtures, assert
  nonoverlapping same-kind lane reuse and per-pool maximum concurrency, and cover
  1,000 adjacent fractional stills, 2,000 hidden layers, leading gaps and audio tails.
- The system sequence smoke passes 128 adjacent one-frame cuts through one
  composition track, with alternating source trims, repeated/backward/end seeks
  and live playback across cuts. Existing overlap, gaps, fractional seeks,
  audio/routing and controller lifecycle checks also pass.
- The still smoke passes 81 decoded seeks, including sixteen adjacent PNG/JPEG
  holds on one still track followed by a movie on its separate track. It checks
  exact hold timing, orientation changes, still/movie transitions, alpha over
  lower video and black, fit padding, reverse seeks and all prior still checks.

Two measured regressions shaped the implementation. Creating tracks purely in
timeline order changed a red padding pixel to `[248, 36, 1]`; preserving editorial
creation priority fixed the prior fixture. Allowing a lane to begin with a movie
and later hold a still changed blue padding to `[26, 34, 255]`; separate still/movie
pools fixed that staggered fixture. The smoke retains the heterogeneous-source
case, with its original color bounds. Still insertion remains chronological within
each lane so stretching one prepared frame cannot shift later inserts.

Optimized synthetic `ProjectProfile` results on macOS 27.0.1 / Apple Silicon:

| Project | Picture clips | Picture lanes | Schedule median, 3 runs |
| --- | ---: | ---: | ---: |
| 10,000 clips across 8 mixed video/audio tracks | 5,000 | 4 | 10.24 ms |
| 10,000 adjacent clips on one video track | 10,000 | 1 | 26.59 ms |

These measure the pure schedule after canonical render planning. They exclude
project validation, asset loading, media preparation, AVComposition insertion,
decoding and the app UI; they do not establish a startup or playback deadline.
The complete reports retain all measurements and cumulative process RSS.

Reproduce with explicit local FFmpeg and host media-service access:

```sh
scripts/system-sequence-smoke.sh /absolute/path/ffmpeg
scripts/system-still-smoke.sh /absolute/path/ffmpeg /private/tmp/composition-stills-new
scripts/project-profile.sh --clips 10000 --tracks 8 --iterations 3
scripts/project-profile.sh --clips 10000 --tracks 1 --iterations 3
scripts/verify.sh
```

The still output directory must be new. FFmpeg only generates fixtures. Source
identities and passing messages are in [results.json](results.json). Existing
wide-gamut/HDR/ICC color agreement, device synchronization and signed sandbox
qualification remain open. These checks qualify generated SDR fixtures only.
