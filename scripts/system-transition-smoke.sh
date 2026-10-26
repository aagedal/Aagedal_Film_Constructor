#!/bin/bash
# Compares system preview frames of picture fades and a cross dissolve with the
# FFmpeg export of the same sequence.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
ffmpeg_path="${1:?Supply an absolute FFmpeg executable for fixtures and the reference render}"
smoke_root="$(mktemp -d "${TMPDIR:-/private/tmp}/afc-system-transition.XXXXXX")"
trap 'rm -rf "$smoke_root"' EXIT
mkdir -p "$smoke_root/module-cache"
"$ffmpeg_path" -v error -f lavfi -i 'color=c=red:s=80x48:r=24:d=2' -f lavfi -i 'color=c=blue:s=80x48:r=24:d=2' \
  -filter_complex '[0:v][1:v]concat=n=2:v=1:a=0,scale=out_color_matrix=bt709:out_range=tv,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709[v]' -map '[v]' \
  -c:v prores_ks -profile:v 0 -pix_fmt yuv422p10le -color_primaries bt709 -color_trc bt709 -colorspace bt709 "$smoke_root/fixture.mov"
swiftc -swift-version 6 -default-isolation MainActor -module-cache-path "$smoke_root/module-cache" \
  -emit-library -emit-module -module-name EditorCore "$repo_root"/Packages/EditorCore/Sources/EditorCore/*.swift \
  -emit-module-path "$smoke_root/EditorCore.swiftmodule" -o "$smoke_root/libEditorCore.dylib"
swiftc -swift-version 6 -default-isolation MainActor -module-cache-path "$smoke_root/module-cache" \
  -parse-as-library -I "$smoke_root" -L "$smoke_root" -lEditorCore \
  "$repo_root/Aagedal Film Constructor/AVFoundationSequenceBackend.swift" \
  "$repo_root/Aagedal Film Constructor/CoreImageCompositor.swift" \
  "$repo_root/Aagedal Film Constructor/AudioMeters.swift" \
  "$repo_root/Aagedal Film Constructor/SystemStillPreview.swift" \
  "$repo_root/Aagedal Film Constructor/SequencePlaybackController.swift" \
  "$repo_root/scripts/system-transition-smoke.swift" -o "$smoke_root/smoke"
NSUnbufferedIO=YES DYLD_LIBRARY_PATH="$smoke_root" "$smoke_root/smoke" "$smoke_root/fixture.mov" "$ffmpeg_path" "$smoke_root"
