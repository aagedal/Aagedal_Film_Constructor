#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
smoke_root="$(mktemp -d "${TMPDIR:-/private/tmp}/afc-save-protection.XXXXXX")"
trap 'rm -rf "$smoke_root"' EXIT
mkdir -p "$smoke_root/module-cache"
swiftc -module-cache-path "$smoke_root/module-cache" -emit-library -emit-module \
  -module-name EditorCore "$repo_root"/Packages/EditorCore/Sources/EditorCore/*.swift \
  -emit-module-path "$smoke_root/EditorCore.swiftmodule" -o "$smoke_root/libEditorCore.dylib"
swiftc -swift-version 6 -default-isolation MainActor -module-cache-path "$smoke_root/module-cache" -parse-as-library \
  -I "$smoke_root" -L "$smoke_root" -lEditorCore \
  "$repo_root/Aagedal Film Constructor/ProjectDocument.swift" \
  "$repo_root/Aagedal Film Constructor/ProjectSaveProtection.swift" \
  "$repo_root/scripts/project-save-protection-smoke.swift" -o "$smoke_root/save-protection-smoke"
DYLD_LIBRARY_PATH="$smoke_root${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" "$smoke_root/save-protection-smoke" "$smoke_root"
