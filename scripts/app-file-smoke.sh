#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
smoke_root="$(mktemp -d "${TMPDIR:-/private/tmp}/afc-file-smoke.XXXXXX")"
trap 'rm -rf "$smoke_root"' EXIT
mkdir -p "$smoke_root/module-cache"
swiftc -module-cache-path "$smoke_root/module-cache" -emit-library -emit-module \
  -module-name EditorCore "$repo_root"/Packages/EditorCore/Sources/EditorCore/*.swift \
  -emit-module-path "$smoke_root/EditorCore.swiftmodule" -o "$smoke_root/libEditorCore.dylib"
swiftc -module-cache-path "$smoke_root/module-cache" -parse-as-library \
  -I "$smoke_root" -L "$smoke_root" -lEditorCore \
  "$repo_root/Aagedal Film Constructor/ProjectDocument.swift" \
  "$repo_root/Aagedal Film Constructor/MediaImporter.swift" \
  "$repo_root/Aagedal Film Constructor/MediaConversionService.swift" \
  "$repo_root/Aagedal Film Constructor/SourcePlaybackBackend.swift" \
  "$repo_root/Aagedal Film Constructor/EditorStore.swift" \
  "$repo_root/Aagedal Film Constructor/TitleRenderer.swift" \
  "$repo_root/Aagedal Film Constructor/StabilisationService.swift" \
  "$repo_root/Aagedal Film Constructor/AVFoundationSequenceBackend.swift" \
  "$repo_root/Aagedal Film Constructor/CoreImageCompositor.swift" \
  "$repo_root/Aagedal Film Constructor/AudioMeters.swift" \
  "$repo_root/Aagedal Film Constructor/SystemStillPreview.swift" \
  "$repo_root/Aagedal Film Constructor/SequencePlaybackController.swift" \
  "$repo_root/Aagedal Film Constructor/EditorExport.swift" \
  "$repo_root/Aagedal Film Constructor/EditorProxy.swift" \
  "$repo_root/Aagedal Film Constructor/EditorProxyQueue.swift" \
  "$repo_root/Aagedal Film Constructor/ProxyGenerationService.swift" \
  "$repo_root/Aagedal Film Constructor/SequenceExportService.swift" \
  "$repo_root/Aagedal Film Constructor/ShortcutBinding.swift" \
  "$repo_root/Aagedal Film Constructor/EditorCommandRegistry.swift" \
  "$repo_root/scripts/app-file-smoke.swift" -o "$smoke_root/file-smoke"
DYLD_LIBRARY_PATH="$smoke_root${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" "$smoke_root/file-smoke" "$smoke_root"
