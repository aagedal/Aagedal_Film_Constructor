#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
smoke_root="$(mktemp -d "${TMPDIR:-/private/tmp}/afc-proxy-workspace-smoke.XXXXXX")"
trap 'rm -rf "$smoke_root"' EXIT
mkdir -p "$smoke_root/module-cache"
ffmpeg="${AFC_SMOKE_FFMPEG:-${FFMPEG:-$(command -v ffmpeg)}}"
ffprobe="${AFC_SMOKE_FFPROBE:-${FFPROBE:-$(command -v ffprobe)}}"
"$ffmpeg" -hide_banner -loglevel error -f lavfi \
  -i "nullsrc=s=320x192:r=24:d=2,geq=lum='32+mod(X+2*Y+N*7,180)':cb='64+X/4':cr='64+Y/2'" \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=3' \
  -itsoffset 0.25 -f lavfi -i 'aevalsrc=sin(2*PI*880*t)|sin(2*PI*1320*t):s=48000:d=3' \
  -map 0:v -map 1:a -map 2:a -c:v prores_ks -profile:v 0 -pix_fmt yuv422p10le -c:a pcm_s16le "$smoke_root/source.mov"
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
  "$repo_root/Aagedal Film Constructor/NoiseReductionService.swift" \
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
  "$repo_root/scripts/proxy-workspace-smoke.swift" -o "$smoke_root/proxy-workspace-smoke"
DYLD_LIBRARY_PATH="$smoke_root${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" "$smoke_root/proxy-workspace-smoke" "$smoke_root" "$ffmpeg" "$ffprobe"
