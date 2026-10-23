#!/bin/bash
# End-to-end acceptance in the real application window.
# Usage: scripts/app-acceptance.sh "/path/to/Aagedal Film Constructor.app" media...
# The app comes to the front for about a minute: it imports the media onto the
# timeline (converting formats AVFoundation cannot open), switches to the Sequence
# viewer with Tab, plays and pauses with Space, opens Render Sequence with ⇧⌘E and
# renders H.264 through the sheet's folder panel and ProRes 422 HQ, saves the
# project with ⌘S through the save panel, then closes and reopens it. Snapshots, renders and acceptance.json are kept
# in the printed folder, including the saved project. Restored windows are ignored.
# The system folder/save panels are skipped by default (an unsigned build can be
# refused by the panel service, leaving an alert nothing can dismiss); export and
# save then use the same service and NSDocument save-as calls. Set
# AFC_ACCEPTANCE_PANELS=1 to drive the real panels in a session that allows them.
set -euo pipefail
app="$1"; shift
[[ $# -gt 0 ]] || { echo "Supply at least one media file." >&2; exit 2; }
out="$(mktemp -d "${TMPDIR:-/private/tmp}/afc-acceptance.XXXXXX")"
media="$(IFS='|'; echo "$*")"
echo "Output: $out"
open -n -W --env AFC_ACCEPTANCE_PANELS="${AFC_ACCEPTANCE_PANELS:-0}" --env AFC_ACCEPTANCE_DIR="$out" --env "AFC_ACCEPTANCE_MEDIA=$media" "$app" --args -ApplePersistenceIgnoreState YES
python3 - "$out/acceptance.json" <<'PY'
import json, sys
steps = {}
for entry in json.load(open(sys.argv[1])):
    steps.setdefault(entry['step'], []).append(entry)
def one(name): return steps.get(name, [{}])[0]
imp, seq, space, sheet = one('import'), one('sequence_viewer'), one('space_transport'), one('export_sheet')
ui, save, reopen = one('export_via_sheet'), one('save'), one('reopen')
checks = [
    ('media imported without errors', imp.get('finished') and not imp.get('error') and imp.get('clips', 0) > 0),
    ('Tab switched to a prepared Sequence viewer', seq.get('tabSwitchedToSequence') and seq.get('prepared')),
    ('Space started playback and the playhead advanced', space.get('startedPlaying') and space.get('playheadWhilePlaying', 0) > 0.5),
    ('Space paused and the playhead held', space.get('paused') and space.get('playheadStable')),
    ('⇧⌘E opened Render Sequence', sheet.get('openedByShortcut')),
    ('Render Sequence H.264 export verified', ui.get('buttonPressed') and ui.get('completed') and ui.get('bytes', 0) > 0),
    ('project saved with every clip (⌘S panel, or NSDocument save-as when panels are skipped)', save.get('saved') and save.get('clipsInFile') == save.get('clipsInWorkspace') and save.get('clipsInFile', 0) > 0),
    ('saved project reopened in a workspace window', reopen.get('reopened') and reopen.get('windowShown')),
] + [(f"{e['format']} export verified ({e.get('frames')} frames)", 'error' not in e and e.get('frames', 0) > 0) for e in steps.get('export', [])]
if not steps.get('export'): checks.append(('exports ran', False))
for label, ok in checks: print(('PASS ' if ok else 'FAIL ') + label)
# The system file-panel service refuses unsigned builds in some sessions; the run then
# completes the same export/save calls without the panel and says so here.
print(f"     folder panel: {ui.get('folderPanel', 'not reached')}; save panel: {save.get('savePanel', 'not reached')}")
for warning in (steps.get('export') or [{}])[0].get('warnings', []): print('     warning: ' + warning)
sys.exit(0 if all(ok for _, ok in checks) else 1)
PY
