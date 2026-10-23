#!/bin/bash
# End-to-end acceptance in the real application window.
# Usage: scripts/app-acceptance.sh "/path/to/Aagedal Film Constructor.app" media...
# Pass the single argument "generate" to have the bundled FFmpeg create H.264/MKV and
# ProRes fixtures inside the run (works in sandboxed, signed builds).
# The app comes to the front for about a minute: it imports the media onto the
# timeline (converting formats AVFoundation cannot open), overlaps a second placement,
# applies fades and a crossfade, relinks one original, generates proxies and prefers
# them, remaps Play / Pause and presses it, switches to the Sequence
# viewer with Tab, plays and pauses with Space, opens Render Sequence with ⇧⌘E and
# renders H.264 through the sheet's folder panel and ProRes 422 HQ, saves the
# project with ⌘S through the save panel, then closes and reopens it. Snapshots, renders and acceptance.json are kept
# in the printed folder, including the saved project. Restored windows are ignored.
# The system panels are hosted by a separate service whose modal loop doesn't run
# the driver's timers, and configuring one while it connects makes it fail. So the
# main run completes export and save through the same export-service and NSDocument
# save-as calls, and two short extra launches check that ⌘I opens the real Import
# panel and that Return in Render Sequence opens the real export folder panel.
# AFC_ACCEPTANCE_PANELS=1 attempts to complete the panels in the main run instead.
set -euo pipefail
app="$1"; shift
[[ $# -gt 0 ]] || { echo "Supply at least one media file." >&2; exit 2; }
out="$(mktemp -d "${TMPDIR:-/private/tmp}/afc-acceptance.XXXXXX")"
media="$(IFS='|'; echo "$*")"
echo "Output: $out"
# Sandboxed (signed) builds can't write the output folder; AFC_ACCEPTANCE_CONTAINER=1 keeps
# files in the app container and rebuilds acceptance.json from the streamed log.
target_dir="$out"; [[ "${AFC_ACCEPTANCE_CONTAINER:-0}" == 1 ]] && target_dir=container
open -n -W --stderr "$out/app-stderr.log" --env AFC_ACCEPTANCE_PANELS="${AFC_ACCEPTANCE_PANELS:-0}" --env AFC_ACCEPTANCE_DIR="$target_dir" --env "AFC_ACCEPTANCE_MEDIA=$media" "$app" --args -ApplePersistenceIgnoreState YES
if [[ "$target_dir" == container ]]; then
  python3 - "$out" <<'PY'
import json, sys, os
entries = [json.loads(line.split('AFC_ACCEPTANCE ', 1)[1]) for line in open(os.path.join(sys.argv[1], 'app-stderr.log'))
           if line.startswith('AFC_ACCEPTANCE ')]
json.dump(entries, open(os.path.join(sys.argv[1], 'acceptance.json'), 'w'), indent=2)
PY
fi
# Real system panels open (no service-failure alert) from the app's own commands.
probe() {
  AFC_PANEL_PROBE="$1" AFC_ACCEPTANCE_MEDIA="$first_media" "$app/Contents/MacOS/Aagedal Film Constructor" \
    -ApplePersistenceIgnoreState YES 2>&1 | grep 'AFC_PANEL_PROBE modal' > "$out/panel-$1.log" || true
}
first_media="$1"
probe launch
# The export probe places the first media file; generated fixtures exist only inside the run.
[[ "$first_media" == generate ]] || probe export
python3 - "$out/acceptance.json" <<'PY'
import json, sys
steps = {}
for entry in json.load(open(sys.argv[1])):
    steps.setdefault(entry['step'], []).append(entry)
def one(name): return steps.get(name, [{}])[0]
imp, seq, space, sheet = one('import'), one('sequence_viewer'), one('space_transport'), one('export_sheet')
ui, save, reopen = one('export_via_sheet'), one('save'), one('reopen')
edit, shortcut, done = one('editing'), one('custom_shortcut'), one('done')
checks = [
    ('media imported without errors', imp.get('finished') and not imp.get('error') and imp.get('clips', 0) > 0),
    ('overlapping placement created sibling tracks', edit.get('overlappingTracks')),
    ('audio fades and a linked crossfade applied', edit.get('fades') and edit.get('crossfade')),
    ('source audio changed to other streams of a multitrack original', edit.get('sourceAudioChanged') or (not edit.get('multitrackAvailable') and 'skip')),
    ('media relinked to a moved copy', edit.get('relinked')),
    ('proxies generated and Prefer Proxy active', edit.get('proxiesReady', 0) > 0 and edit.get('representation') == 'proxy'),
    ('remapped Play / Pause shortcut works and was restored', shortcut.get('remapped') and shortcut.get('plays') and shortcut.get('pauses') and shortcut.get('restored')),
    ('Tab switched to a prepared Sequence viewer', seq.get('tabSwitchedToSequence') and seq.get('prepared')),
    ('Space started playback and the playhead advanced', space.get('startedPlaying') and space.get('playheadWhilePlaying', 0) > 0.5),
    ('Space paused and the playhead held', space.get('paused') and space.get('playheadStable')),
    ('⇧⌘E opened Render Sequence', sheet.get('openedByShortcut')),
    ('Render Sequence H.264 export verified', ui.get('buttonPressed') and ui.get('completed') and ui.get('bytes', 0) > 0),
    ('project saved with every clip (⌘S panel, or NSDocument save-as when panels are skipped)', save.get('saved') and save.get('clipsInFile') == save.get('clipsInWorkspace') and save.get('clipsInFile', 0) > 0),
    ('saved project reopened in a workspace window', reopen.get('reopened') and reopen.get('windowShown')),
] + [(f"{e['format']} export verified ({e.get('frames')} frames)", 'error' not in e and e.get('frames', 0) > 0) for e in steps.get('export', [])]
if not steps.get('export'): checks.append(('exports ran', False))
import os
for name, label in [('launch', 'Import panel opens as a real system panel'), ('export', 'Return in Render Sequence opens the real folder panel')]:
    path = os.path.join(os.path.dirname(sys.argv[1]), f'panel-{name}.log')
    text = open(path).read() if os.path.exists(path) else ''
    if name == 'export' and not os.path.exists(path):
        checks.append((label, 'skip')); continue
    checks.append((label, 'modal=NSOpenPanel' in text and 'alert=false' in text))
for label, ok in checks: print(('SKIP ' if ok == 'skip' else 'PASS ' if ok else 'FAIL ') + label)
# The system file-panel service refuses unsigned builds in some sessions; the run then
# completes the same export/save calls without the panel and says so here.
gen = one('generate')
if gen: print(f"     generated fixtures: {gen.get('files')} · sandboxed: {gen.get('sandboxed')}")
print("     key dispatch: " + ", ".join(sorted(set(p.split(' ')[0] for p in done.get('dispatch', [])))))
print(f"     folder panel: {ui.get('folderPanel', 'not reached')}; save panel: {save.get('savePanel', 'not reached')}")
for warning in (steps.get('export') or [{}])[0].get('warnings', []): print('     warning: ' + warning)
sys.exit(0 if all(ok for _, ok in checks) else 1)
PY
