# Synthetic large-project performance

An optimized local benchmark exercises mixed picture/stereo tracks with one
source per clip, reversed clip storage and crossfades at every fourth audio cut.
Each operation has an untimed warmup and three measured samples. Timings are
host-specific observations, not release performance guarantees.

| Operation, median milliseconds | 5,000 clips before | 5,000 clips after | 10,000 clips after |
| --- | ---: | ---: | ---: |
| Validate | 359.4 | 5.4 | 10.1 |
| Encode project JSON | 495.5 | 102.0 | 190.3 |
| Decode and validate JSON | 430.8 | 95.2 | 173.1 |
| Build render plan | 1513 | 15.2 | 19.2 |
| Move, undo and redo | 1384 | 29.2 | 37.2 |

The baseline uses the pre-optimization core with the same profiling workload.
The optimized core indexes assets/families and crossfade endpoints, reuses
crossfade geometry, and checks sorted neighboring intervals instead of every
pair. Exact rational comparisons preserve adjacency, reject overlaps and retain
overflow failures. Regression cases include unordered, nested, identical-start
and fractional intervals, duplicate/missing identities and large time values.

Process peak resident memory increased from approximately 138 to 151 MB for
5,000 clips; 10,000 clips reached approximately 247 MB. This is cumulative
process high-water memory including fixture generation, JSON, warmups and all
operations. It is not an isolated cache footprint or per-operation allocation.
The indexes trade some memory for faster operations.

Run `scripts/project-profile.sh --clips 5000 --tracks 8 --iterations 3` for JSON
on stdout, or use the SwiftPM `ProjectProfile` executable in Release mode.
The retained [baseline](5000-before.json), [optimized 5,000-clip run](5000-after.json)
and [10,000-clip run](10000-after.json) include every timing sample and scope.
No media is read. This measures EditorCore's Codable project, not the app's
document envelope, bookmarks, SwiftUI rendering, decoder memory or cold launch.
Those remain separate acceptance work.
