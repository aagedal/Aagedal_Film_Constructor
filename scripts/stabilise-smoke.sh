#!/bin/bash
# Stabilises shaky synthetic footage with the app's service and checks it moves less.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
ffmpeg_path="${1:?Supply an absolute FFmpeg executable}"
smoke_root="$(mktemp -d "${TMPDIR:-/private/tmp}/afc-stabilise.XXXXXX")"
trap 'rm -rf "$smoke_root"' EXIT
mkdir -p "$smoke_root/module-cache"
swiftc -module-cache-path "$smoke_root/module-cache" \
  -emit-library -emit-module -module-name EditorCore "$repo_root"/Packages/EditorCore/Sources/EditorCore/*.swift \
  -emit-module-path "$smoke_root/EditorCore.swiftmodule" -o "$smoke_root/libEditorCore.dylib"
swiftc -swift-version 6 -default-isolation MainActor -module-cache-path "$smoke_root/module-cache" \
  -parse-as-library -I "$smoke_root" -L "$smoke_root" -lEditorCore \
  "$repo_root/Aagedal Film Constructor/SequenceExportService.swift" \
  "$repo_root/Aagedal Film Constructor/StabilisationService.swift" \
  "$repo_root/Aagedal Film Constructor/NoiseReductionService.swift" \
  "$repo_root/scripts/stabilise-smoke.swift" -o "$smoke_root/smoke"
NSUnbufferedIO=YES DYLD_LIBRARY_PATH="$smoke_root" "$smoke_root/smoke" "$ffmpeg_path" "$smoke_root"
