#!/bin/bash
# End-to-end acceptance in the real application window.
# Usage: scripts/app-acceptance.sh "/path/to/Aagedal Film Constructor.app" media...
# The app comes to the front for about a minute: it imports the media onto the
# timeline (converting formats AVFoundation cannot open), switches to the Sequence
# viewer with Tab, plays and pauses with Space, opens Render Sequence with ⇧⌘E and
# renders H.264 and ProRes 422 HQ. Snapshots, renders and acceptance.json are kept
# in the printed folder. Restored windows are ignored; no project is saved.
set -euo pipefail
app="$1"; shift
[[ $# -gt 0 ]] || { echo "Supply at least one media file." >&2; exit 2; }
out="$(mktemp -d "${TMPDIR:-/private/tmp}/afc-acceptance.XXXXXX")"
media="$(IFS='|'; echo "$*")"
echo "Output: $out"
open -n -W --env AFC_ACCEPTANCE_DIR="$out" --env "AFC_ACCEPTANCE_MEDIA=$media" "$app" --args -ApplePersistenceIgnoreState YES
python3 - "$out/acceptance.json" <<'PY'
import json, sys
steps = {}
for entry in json.load(open(sys.argv[1])):
    steps.setdefault(entry['step'], []).append(entry)
def one(name): return steps.get(name, [{}])[0]
imp, seq, space, sheet = one('import'), one('sequence_viewer'), one('space_transport'), one('export_sheet')
checks = [
    ('media imported without errors', imp.get('finished') and not imp.get('error') and imp.get('clips', 0) > 0),
    ('Tab switched to a prepared Sequence viewer', seq.get('tabSwitchedToSequence') and seq.get('prepared')),
    ('Space started playback and the playhead advanced', space.get('startedPlaying') and space.get('playheadWhilePlaying', 0) > 0.5),
    ('Space paused and the playhead held', space.get('paused') and space.get('playheadStable')),
    ('⇧⌘E opened Render Sequence', sheet.get('openedByShortcut')),
] + [(f"{e['format']} export verified ({e.get('frames')} frames)", 'error' not in e and e.get('frames', 0) > 0) for e in steps.get('export', [])]
if not steps.get('export'): checks.append(('exports ran', False))
for label, ok in checks: print(('PASS ' if ok else 'FAIL ') + label)
for warning in (steps.get('export') or [{}])[0].get('warnings', []): print('     warning: ' + warning)
sys.exit(0 if all(ok for _, ok in checks) else 1)
PY
