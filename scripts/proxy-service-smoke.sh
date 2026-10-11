#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
smoke_root="$(mktemp -d "${TMPDIR:-/private/tmp}/afc-proxy-smoke.XXXXXX")"
trap 'rm -rf "$smoke_root"' EXIT
ffmpeg_helper="${AFC_SMOKE_FFMPEG:-/opt/homebrew/bin/ffmpeg}"
ffprobe_helper="${AFC_SMOKE_FFPROBE:-/opt/homebrew/bin/ffprobe}"
[[ -x "$ffmpeg_helper" && -x "$ffprobe_helper" ]] || { echo 'Set AFC_SMOKE_FFMPEG and AFC_SMOKE_FFPROBE to executable development helpers.' >&2; exit 1; }
mkdir -p "$smoke_root/module-cache"
swiftc -module-cache-path "$smoke_root/module-cache" -emit-library -emit-module -module-name EditorCore \
 "$repo_root"/Packages/EditorCore/Sources/EditorCore/*.swift -emit-module-path "$smoke_root/EditorCore.swiftmodule" -o "$smoke_root/libEditorCore.dylib"
"$ffmpeg_helper" -hide_banner -loglevel error -f lavfi -i "nullsrc=s=160x96:r=24000/1001:d=1,geq=lum='40+mod(N*73,180)':cb='40+mod(N*47,180)':cr='40+mod(N*89,180)'" -f lavfi -i 'sine=duration=1' -c:v prores_ks -profile:v 3 -color_primaries bt709 -color_trc bt709 -colorspace bt709 -c:a pcm_s16le -timecode '01:00:00:00' "$smoke_root/source.mov"
"$ffmpeg_helper" -hide_banner -loglevel error -f lavfi -i 'testsrc2=s=160x96:r=24:d=1' -vf 'select=not(eq(n\,5))' -fps_mode vfr -c:v mpeg4 "$smoke_root/vfr.mov"
"$ffmpeg_helper" -hide_banner -loglevel error -f lavfi -i 'testsrc2=s=160x96:r=24:d=1' -vf setsar=2 -c:v mpeg4 "$smoke_root/sar.mov"
swiftc -swift-version 6 -default-isolation MainActor -module-cache-path "$smoke_root/module-cache" -parse-as-library \
 -I "$smoke_root" -L "$smoke_root" -lEditorCore "$repo_root/Aagedal Film Constructor/SequenceExportService.swift" \
 "$repo_root/Aagedal Film Constructor/ProxyGenerationService.swift" "$repo_root/scripts/proxy-service-smoke.swift" -o "$smoke_root/proxy-smoke"
DYLD_LIBRARY_PATH="$smoke_root${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" "$smoke_root/proxy-smoke" "$smoke_root" "$ffmpeg_helper" "$ffprobe_helper"
# Compare each decoded frame with the same scaled source frame. Distinct colors
# for every frame make a shifted, dropped, or repeated frame fail clearly.
for rendition in prores h264; do
 if [[ "$rendition" == prores ]]; then raster='80:48'; pixel='yuv422p10le'; else raster='40:24'; pixel='yuv420p'; fi
 "$ffmpeg_helper" -hide_banner -loglevel error -i "$smoke_root/source.mov" -i "$smoke_root/$rendition.mov" \
  -filter_complex "[0:v]scale=$raster:flags=lanczos,format=$pixel[a];[1:v]format=$pixel[b];[a][b]psnr=stats_file=$smoke_root/$rendition-psnr.log" -f null -
 python3 - "$smoke_root/$rendition-psnr.log" "$rendition" <<'PY_CHECK'
import re, sys
rows = open(sys.argv[1]).readlines()
assert len(rows) == 24, f'Decoded correspondence frame count: {len(rows)}'
for row in rows:
    score = float(re.search(r'psnr_avg:([\w.]+)', row).group(1))
    assert score > 35, f'Decoded frame correspondence failed: {row}'
print(f'Decoded frame correspondence passed for all 24 {sys.argv[2]} frames')
PY_CHECK
done
