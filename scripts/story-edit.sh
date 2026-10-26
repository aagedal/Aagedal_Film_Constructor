#!/bin/bash
# Cuts a short film from real shots in the real application window and exports it.
# Usage: scripts/story-edit.sh "/path/to/Aagedal Film Constructor.app" "shot.mov@in-out" ...
# (in/out in source seconds). The third shot plays at 50%. Output, snapshots, the movie
# and the project stay in the printed folder.
set -euo pipefail
app="$1"; shift
out="$(mktemp -d "${TMPDIR:-/private/tmp}/afc-story.XXXXXX")"
echo "Output: $out"
media="$(IFS='|'; echo "$*")"
open -n -W --stderr "$out/app-stderr.log" --env AFC_STORY=1 --env AFC_ACCEPTANCE_DIR="$out" --env "AFC_ACCEPTANCE_MEDIA=$media" "$app" \
  --args -ApplePersistenceIgnoreState YES
grep '^AFC_STORY ' "$out/app-stderr.log" | sed 's/^AFC_STORY //'
