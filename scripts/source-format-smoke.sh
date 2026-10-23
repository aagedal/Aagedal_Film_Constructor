#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
smoke_root="$(mktemp -d "${TMPDIR:-/private/tmp}/afc-source-format.XXXXXX")"
trap 'rm -rf "$smoke_root"' EXIT
# Development-only helper; application import uses AVFoundation directly.
ffmpeg_helper="${AFC_SMOKE_FFMPEG:-${FFMPEG:-$(command -v ffmpeg)}}"
[[ -x "$ffmpeg_helper" ]] || { echo 'Set AFC_SMOKE_FFMPEG to an executable development helper.' >&2; exit 1; }
mkdir -p "$smoke_root/module-cache"
"$ffmpeg_helper" -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=320x180:rate=30000/1001:duration=1' -c:v libx264 "$smoke_root/cfr.mp4"
"$ffmpeg_helper" -hide_banner -loglevel error -display_rotation 90 -i "$smoke_root/cfr.mp4" -c copy "$smoke_root/rotated.mp4"
"$ffmpeg_helper" -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=320x180:rate=24:duration=1' -c:v libx264 "$smoke_root/cfr24.mp4"
"$ffmpeg_helper" -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=320x180:rate=24000/1001:duration=1' -c:v libx264 "$smoke_root/cfr23976.mp4"
"$ffmpeg_helper" -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=320x180:rate=24' -frames:v 1 -c:v libx264 "$smoke_root/single.mp4"
"$ffmpeg_helper" -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=320x180:rate=30:duration=1' -vf "select='not(eq(mod(n,3),1))'" -fps_mode vfr -c:v libx264 "$smoke_root/vfr.mp4"
"$ffmpeg_helper" -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=320x180:rate=24:duration=1' -vf 'setsar=2/1' -c:v libx264 "$smoke_root/anamorphic.mp4"
swiftc -swift-version 6 -module-cache-path "$smoke_root/module-cache" \
  -emit-library -emit-module -module-name EditorCore "$repo_root"/Packages/EditorCore/Sources/EditorCore/*.swift \
  -emit-module-path "$smoke_root/EditorCore.swiftmodule" -o "$smoke_root/libEditorCore.dylib"
swiftc -swift-version 6 -default-isolation MainActor -module-cache-path "$smoke_root/module-cache" \
  -parse-as-library -I "$smoke_root" -L "$smoke_root" -lEditorCore \
  "$repo_root/Aagedal Film Constructor/MediaImporter.swift" \
  "$repo_root/Aagedal Film Constructor/MediaConversionService.swift" \
  "$repo_root/Aagedal Film Constructor/SequenceExportService.swift" \
  "$repo_root/scripts/source-format-smoke.swift" -o "$smoke_root/smoke"
DYLD_LIBRARY_PATH="$smoke_root" "$smoke_root/smoke" "$smoke_root"
