#!/bin/bash
# Draws a title over a movie and checks the export and system preview composite it.
# Pass a folder as the second argument to keep the rendered frames for inspection.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
ffmpeg_path="${1:?Supply an absolute FFmpeg executable for fixtures and the reference render}"
keep="${2:-}"
smoke_root="$(mktemp -d "${TMPDIR:-/private/tmp}/afc-title.XXXXXX")"
trap 'rm -rf "$smoke_root"' EXIT
mkdir -p "$smoke_root/module-cache"
"$ffmpeg_path" -v error -f lavfi -i 'color=c=0x204080:s=640x360:r=25:d=4' -c:v prores_ks -profile:v 0 "$smoke_root/fixture.mov"
swiftc -swift-version 6 -default-isolation MainActor -module-cache-path "$smoke_root/module-cache" \
  -emit-library -emit-module -module-name EditorCore "$repo_root"/Packages/EditorCore/Sources/EditorCore/*.swift \
  -emit-module-path "$smoke_root/EditorCore.swiftmodule" -o "$smoke_root/libEditorCore.dylib"
swiftc -swift-version 6 -default-isolation MainActor -module-cache-path "$smoke_root/module-cache" \
  -parse-as-library -I "$smoke_root" -L "$smoke_root" -lEditorCore \
  "$repo_root/Aagedal Film Constructor/TitleRenderer.swift" \
  "$repo_root/Aagedal Film Constructor/AVFoundationSequenceBackend.swift" \
  "$repo_root/Aagedal Film Constructor/CoreImageCompositor.swift" \
  "$repo_root/Aagedal Film Constructor/SystemStillPreview.swift" \
  "$repo_root/Aagedal Film Constructor/SequencePlaybackController.swift" \
  "$repo_root/scripts/title-smoke.swift" -o "$smoke_root/smoke"
NSUnbufferedIO=YES DYLD_LIBRARY_PATH="$smoke_root" "$smoke_root/smoke" "$smoke_root/fixture.mov" "$ffmpeg_path" "$smoke_root" "$keep"
