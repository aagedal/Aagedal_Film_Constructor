#!/bin/bash
# Release-mode synthetic EditorCore profiling; JSON goes to stdout.
# Usage: scripts/project-profile.sh --clips 5000 --tracks 8 --iterations 3 > report.json
# No media files are read. Peak RSS is cumulative process high-water memory,
# including fixture creation, JSON data, warmups and all operations, not a delta.
# Use --tracks 1 to stress a dense track; default mixes video/audio and crossfades.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
profile_root="$(mktemp -d "${TMPDIR:-/private/tmp}/afc-project-profile.XXXXXX")"
trap 'rm -rf "$profile_root"' EXIT
mkdir -p "$profile_root/module-cache"
# Compile optimized directly, keeping build caches writable and avoiding Xcode
# release dSYM generation. The SwiftPM ProjectProfile product is also available.
swiftc -O -module-cache-path "$profile_root/module-cache" -emit-library -emit-module \
  -module-name EditorCore "$repo_root"/Packages/EditorCore/Sources/EditorCore/*.swift \
  -emit-module-path "$profile_root/EditorCore.swiftmodule" -o "$profile_root/libEditorCore.dylib"
swiftc -O -module-cache-path "$profile_root/module-cache" \
  -I "$profile_root" -L "$profile_root" -lEditorCore \
  "$repo_root/Packages/EditorCore/Sources/ProjectProfile/main.swift" -o "$profile_root/project-profile"
DYLD_LIBRARY_PATH="$profile_root${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" "$profile_root/project-profile" "$@"
