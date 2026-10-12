#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
smoke_root="$(mktemp -d "${TMPDIR:-/private/tmp}/afc-timeline-visibility.XXXXXX")"
trap 'rm -rf "$smoke_root"' EXIT
swiftc -module-cache-path "$smoke_root/module-cache" -parse-as-library \
  "$repo_root/Aagedal Film Constructor/TimelineClipVisibility.swift" \
  "$repo_root/scripts/timeline-visibility-smoke.swift" -o "$smoke_root/visibility-smoke"
"$smoke_root/visibility-smoke"
