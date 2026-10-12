#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
smoke_root="$(mktemp -d "${TMPDIR:-/private/tmp}/afc-launch-smoke.XXXXXX")"
trap 'rm -rf "$smoke_root"' EXIT
swiftc -module-cache-path "$smoke_root/module-cache" -parse-as-library \
  "$repo_root/Aagedal Film Constructor/LaunchWorkspaceCoordinator.swift" \
  "$repo_root/scripts/launch-workspace-smoke.swift" -o "$smoke_root/launch-smoke"
"$smoke_root/launch-smoke"
