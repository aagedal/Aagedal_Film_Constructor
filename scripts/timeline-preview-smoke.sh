#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
smoke_root="$(mktemp -d "${TMPDIR:-/private/tmp}/afc-preview-smoke.XXXXXX")"
trap 'rm -rf "$smoke_root"' EXIT
mkdir -p "$smoke_root/module-cache"
swiftc -module-cache-path "$smoke_root/module-cache" -emit-library -emit-module \
  -module-name EditorCore "$repo_root"/Packages/EditorCore/Sources/EditorCore/*.swift \
  -emit-module-path "$smoke_root/EditorCore.swiftmodule" -o "$smoke_root/libEditorCore.dylib"
if command -v ffmpeg >/dev/null 2>&1; then
  ffmpeg -hide_banner -loglevel error -f lavfi -i 'color=c=red:s=160x90:r=10:d=1' \
    -f lavfi -i 'color=c=blue:s=160x90:r=10:d=1' -filter_complex '[0:v][1:v]concat=n=2:v=1:a=0' \
    -c:v libx264 -pix_fmt yuv420p "$smoke_root/colors.mp4"
fi
swiftc -module-cache-path "$smoke_root/module-cache" -parse-as-library \
  -I "$smoke_root" -L "$smoke_root" -lEditorCore \
  "$repo_root/Aagedal Film Constructor/TimelinePreviewService.swift" \
  "$repo_root/scripts/timeline-preview-smoke.swift" -o "$smoke_root/preview-smoke"
DYLD_LIBRARY_PATH="$smoke_root${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" "$smoke_root/preview-smoke" "$smoke_root"
