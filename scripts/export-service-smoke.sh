#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
smoke_root="$(mktemp -d "${TMPDIR:-/private/tmp}/afc-export-smoke.XXXXXX")"
trap 'rm -rf "$smoke_root"' EXIT
# Explicit development-only helpers; the application never discovers PATH tools.
ffmpeg_helper="${AFC_SMOKE_FFMPEG:-/opt/homebrew/bin/ffmpeg}"
ffprobe_helper="${AFC_SMOKE_FFPROBE:-/opt/homebrew/bin/ffprobe}"
if [[ ! -x "$ffmpeg_helper" || ! -x "$ffprobe_helper" ]]; then
  echo 'Set AFC_SMOKE_FFMPEG and AFC_SMOKE_FFPROBE to executable development helpers.' >&2
  exit 1
fi
mkdir -p "$smoke_root/module-cache"
swiftc -module-cache-path "$smoke_root/module-cache" -emit-library -emit-module \
  -module-name EditorCore "$repo_root"/Packages/EditorCore/Sources/EditorCore/*.swift \
  -emit-module-path "$smoke_root/EditorCore.swiftmodule" -o "$smoke_root/libEditorCore.dylib"
"$ffmpeg_helper" -hide_banner -loglevel error -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=30' -ac 2 "$smoke_root/source.wav"
"$ffmpeg_helper" -hide_banner -loglevel error -f lavfi -i 'color=c=red:s=160x90:r=24:d=1' -vf setsar=2 -c:v mpeg4 "$smoke_root/anamorphic.mov"
# One tick of irregularity is below FFprobe's nominal-rate heuristic: both
# avg_frame_rate and r_frame_rate remain 24/1, requiring actual decoded timestamps.
"$ffmpeg_helper" -hide_banner -loglevel error -f lavfi -i 'testsrc2=s=320x192:r=24:d=1' -c:v prores_ks "$smoke_root/cfr.mov"
"$ffmpeg_helper" -hide_banner -loglevel error -f lavfi -i 'testsrc2=s=160x90:r=30000/1001:d=1' -c:v prores_ks "$smoke_root/fractional-cfr.mov"
"$ffmpeg_helper" -hide_banner -loglevel error -f lavfi -i 'testsrc2=s=160x90:r=24:d=1' \
 -vf 'settb=1/12288,setpts=PTS+if(eq(N\,5)\,1\,0)' -fps_mode passthrough -enc_time_base 1/12288 \
 -c:v prores_ks -video_track_timescale 12288 "$smoke_root/equal-rate-vfr.mov"
"$ffmpeg_helper" -hide_banner -loglevel error -f lavfi -i 'testsrc2=s=160x90:r=24:d=1' \
 -vf 'setpts=PTS+1' -fps_mode passthrough -c:v prores_ks "$smoke_root/offset.mov"
"$ffmpeg_helper" -hide_banner -loglevel error -f lavfi -i 'sine=sample_rate=44100:duration=30' -ac 2 "$smoke_root/resample.wav"
swiftc -swift-version 6 -default-isolation MainActor -module-cache-path "$smoke_root/module-cache" -parse-as-library \
  -I "$smoke_root" -L "$smoke_root" -lEditorCore \
  "$repo_root/Aagedal Film Constructor/SequenceExportService.swift" \
  "$repo_root/scripts/export-service-smoke.swift" -o "$smoke_root/export-smoke"
DYLD_LIBRARY_PATH="$smoke_root${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" "$smoke_root/export-smoke" "$smoke_root" "$ffmpeg_helper" "$ffprobe_helper"
