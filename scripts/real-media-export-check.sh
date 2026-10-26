#!/bin/bash
# Usage: scripts/real-media-export-check.sh /path/to/Helpers [h264|hevc|proRes422|proRes422HQ] [seconds] media...
# Set AFC_CHECK_LAYOUT=5.1 to check a 5.1 sequence instead of stereo.
# Helpers is a directory containing ffmpeg and ffprobe, for example a built app's
# Contents/Resources/Helpers. Rendered files are kept in a printed temporary folder.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
helpers="$1"; format="${2:-h264}"; seconds="${3:-4}"; shift 3
work="$(mktemp -d "${TMPDIR:-/private/tmp}/afc-real-media.XXXXXX")"
mkdir -p "$work/module-cache" "$work/output"
xcrun swiftc -module-cache-path "$work/module-cache" -emit-library -emit-module \
  -module-name EditorCore "$repo_root"/Packages/EditorCore/Sources/EditorCore/*.swift \
  -emit-module-path "$work/EditorCore.swiftmodule" -o "$work/libEditorCore.dylib"
xcrun swiftc -swift-version 6 -default-isolation MainActor -module-cache-path "$work/module-cache" -parse-as-library \
  -I "$work" -L "$work" -lEditorCore \
  "$repo_root/Aagedal Film Constructor/SequenceExportService.swift" \
  "$repo_root/Aagedal Film Constructor/MediaImporter.swift" \
  "$repo_root/Aagedal Film Constructor/MediaConversionService.swift" \
  "$repo_root/Aagedal Film Constructor/AVFoundationSequenceBackend.swift" \
  "$repo_root/Aagedal Film Constructor/CoreImageCompositor.swift" \
  "$repo_root/Aagedal Film Constructor/SystemStillPreview.swift" \
  "$repo_root/Aagedal Film Constructor/SequencePlaybackController.swift" \
  "$repo_root/scripts/real-media-export-check.swift" -o "$work/check"
echo "Output: $work/output"
DYLD_LIBRARY_PATH="$work" "$work/check" "$work/output" "$helpers" "$format" "$seconds" "$@"
