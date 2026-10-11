#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/afc-shortcut-smoke.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT
swiftc -module-cache-path "$task_dir/module-cache" \
    "$root/Aagedal Film Constructor/ShortcutBinding.swift" \
    "$root/scripts/shortcut-smoke.swift" -o "$task_dir/shortcut-smoke"
"$task_dir/shortcut-smoke"
