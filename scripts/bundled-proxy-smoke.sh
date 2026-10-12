#!/bin/bash
# Exercise helpers copied into an actual Xcode-built app without changing that app.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# == 1 ]] || { echo 'Usage: bundled-proxy-smoke.sh /absolute/built.app' >&2; exit 1; }
helper_source="$1/Contents/Resources/Helpers"
[[ -x "$helper_source/ffmpeg" && -x "$helper_source/ffprobe" ]] || { echo 'App has no bundled helpers' >&2; exit 1; }
smoke_root="$(mktemp -d "${TMPDIR:-/private/tmp}/afc-bundled-proxy.XXXXXX")"
trap 'rm -rf "$smoke_root"' EXIT
app="$smoke_root/ProxySmoke.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$smoke_root/module-cache"
/usr/bin/ditto "$helper_source" "$app/Contents/Resources/Helpers"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.aagedal.bundled-proxy-smoke</string>
<key>CFBundleExecutable</key><string>ProxySmoke</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
swiftc -module-cache-path "$smoke_root/module-cache" -emit-library -emit-module -module-name EditorCore \
  "$repo_root"/Packages/EditorCore/Sources/EditorCore/*.swift \
  -emit-module-path "$smoke_root/EditorCore.swiftmodule" -o "$app/Contents/MacOS/libEditorCore.dylib" \
  -Xlinker -install_name -Xlinker @rpath/libEditorCore.dylib
swiftc -swift-version 6 -default-isolation MainActor -module-cache-path "$smoke_root/module-cache" -parse-as-library \
  -I "$smoke_root" -L "$app/Contents/MacOS" -lEditorCore -Xlinker -rpath -Xlinker @executable_path \
  "$repo_root/Aagedal Film Constructor/SequenceExportService.swift" \
  "$repo_root/Aagedal Film Constructor/ProxyGenerationService.swift" \
  "$repo_root/scripts/bundled-proxy-smoke.swift" -o "$app/Contents/MacOS/ProxySmoke"
helpers="$app/Contents/Resources/Helpers"
# Clear developer loader paths: copied helpers must resolve their own dependencies.
env -u DYLD_LIBRARY_PATH -u DYLD_FALLBACK_LIBRARY_PATH "$helpers/ffmpeg" -hide_banner -loglevel error \
  -f lavfi -i 'testsrc2=s=160x96:r=24000/1001:d=1' -c:v prores_ks -profile:v 3 \
  -timecode '01:00:00:00' "$smoke_root/source.mov"
env -u DYLD_LIBRARY_PATH -u DYLD_FALLBACK_LIBRARY_PATH "$app/Contents/MacOS/ProxySmoke" "$smoke_root"
