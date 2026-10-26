#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
ffmpeg_path="${1:?Supply an absolute FFmpeg executable for fixture generation}"
smoke_root="$(mktemp -d "${TMPDIR:-/private/tmp}/afc-system-sequence.XXXXXX")"
trap 'rm -rf "$smoke_root"' EXIT
mkdir -p "$smoke_root/module-cache"
"$ffmpeg_path" -v error -f lavfi -i 'color=c=red:s=80x48:r=24:d=1' \
  -f lavfi -i 'color=c=blue:s=80x48:r=24:d=1' -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=2' \
  -filter_complex '[0:v][1:v]concat=n=2:v=1:a=0[v]' -map '[v]' -map 2:a \
  -c:v prores_ks -profile:v 0 -pix_fmt yuv422p10le -c:a pcm_s16le -ac 2 "$smoke_root/fixture.mov"
"$ffmpeg_path" -v error -f lavfi -i 'color=c=white:s=60x48:r=24:d=1' -vf setsar=4/3 \
  -c:v prores_ks -profile:v 0 -pix_fmt yuv422p10le "$smoke_root/anamorphic.mov"
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
  "$repo_root/scripts/system-sequence-smoke.swift" -o "$smoke_root/smoke"
NSUnbufferedIO=YES DYLD_LIBRARY_PATH="$smoke_root" "$smoke_root/smoke" "$smoke_root/fixture.mov" "$smoke_root/anamorphic.mov"
