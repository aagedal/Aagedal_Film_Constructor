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
"$ffmpeg_helper" -hide_banner -loglevel error -f lavfi -i "nullsrc=s=160x96:r=24000/1001:d=1,geq=lum='40+mod(N*73,180)':cb='40+mod(N*47,180)':cr='40+mod(N*89,180)'" -f lavfi -i 'sine=duration=1' -vf 'setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709' -c:v prores_ks -profile:v 3 -color_primaries bt709 -color_trc bt709 -colorspace bt709 -c:a pcm_s16le -timecode '01:00:00:00' "$smoke_root/source.mov"
"$ffmpeg_helper" -hide_banner -loglevel error -f lavfi -i 'testsrc2=s=160x96:r=24:d=1' -vf 'select=not(eq(n\,5))' -fps_mode vfr -c:v mpeg4 "$smoke_root/vfr.mov"
"$ffmpeg_helper" -hide_banner -loglevel error -f lavfi -i 'testsrc2=s=160x96:r=24:d=1' -vf setsar=2 -c:v mpeg4 "$smoke_root/sar.mov"
# A spatially asymmetric moving ramp catches flips, crops and wrong stream maps.
# Put audio before both pictures so the selected video is absolute stream index 2.
"$ffmpeg_helper" -hide_banner -loglevel error -f lavfi -i 'sine=duration=1' \
 -f lavfi -i 'sine=frequency=880:duration=1' \
 -f lavfi -i "nullsrc=s=320x192:r=24000/1001:d=1,geq=lum='32+mod(X+2*Y+N*7,180)':cb='64+X/4':cr='64+Y/2'" \
 -f lavfi -i 'color=c=red:s=128x72:r=24:d=1' \
 -map 0:a -map 1:a -map 2:v -map 3:v -c:a pcm_s16le -filter:v 'setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709' -c:v prores_ks -profile:v 3 \
 -color_primaries bt709 -color_trc bt709 -colorspace bt709 -timecode '01:00:00:00' "$smoke_root/multistream.mov"
"$ffmpeg_helper" -hide_banner -loglevel error -display_rotation:v:0 90 -i "$smoke_root/source.mov" -map 0:v -c copy "$smoke_root/rotated.mov"
"$ffmpeg_helper" -hide_banner -loglevel error -f lavfi -i 'testsrc2=s=160x96:r=24:d=1' -vf 'setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc' -c:v libx264 -color_primaries bt2020 -color_trc smpte2084 "$smoke_root/hdr.mov"
"$ffmpeg_helper" -hide_banner -loglevel error -f lavfi -i 'testsrc2=s=160x96:r=24:d=1' -vf 'setparams=range=full' -c:v libx264 -pix_fmt yuvj420p -color_range pc "$smoke_root/full-range.mov"
"$ffmpeg_helper" -hide_banner -loglevel error -f lavfi -i 'testsrc2=s=162x98:r=24:d=1' -c:v prores_ks "$smoke_root/scale.mov"
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
# Inspect actual encoded metadata independently of the service's verification.
"$ffprobe_helper" -v error -show_streams -of json "$smoke_root/prores.mov" > "$smoke_root/prores.json"
"$ffprobe_helper" -v error -show_streams -of json "$smoke_root/h264.mov" > "$smoke_root/h264.json"
python3 - "$smoke_root" <<'PY_METADATA'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
for name in ('prores', 'h264'):
    streams = json.loads((root / f'{name}.json').read_text())['streams']
    videos = [s for s in streams if s['codec_type'] == 'video']
    assert len(videos) == 1 and not any(s['codec_type'] == 'audio' for s in streams)
    video = videos[0]
    assert video['tags']['timecode'] == '01:00:00:00'
    assert video['color_primaries'] == video['color_transfer'] == video['color_space'] == 'bt709'
    assert video['r_frame_rate'] == video['avg_frame_rate'] == '24000/1001'
print('Independent metadata checks passed: SDR tags, fractional rate, MOV timecode, video only')
PY_METADATA
for rendition in geometry-prores geometry-h264; do
 if [[ "$rendition" == geometry-prores ]]; then raster='160:96'; pixel='yuv422p10le'; else raster='80:48'; pixel='yuv420p'; fi
 "$ffmpeg_helper" -hide_banner -loglevel error -i "$smoke_root/multistream.mov" -i "$smoke_root/$rendition.mov" \
  -filter_complex "[0:2]scale=$raster:flags=lanczos,format=$pixel[a];[1:v]format=$pixel[b];[a][b]psnr=stats_file=$smoke_root/$rendition-psnr.log" -f null -
 python3 - "$smoke_root/$rendition-psnr.log" "$rendition" <<'PY_GEOMETRY'
import re, sys
rows = open(sys.argv[1]).readlines()
assert len(rows) == 24, f'Spatial correspondence frame count: {len(rows)}'
for row in rows:
    score = float(re.search(r'psnr_avg:([\w.]+)', row).group(1))
    assert score > 30, f'Spatial/frame correspondence failed: {row}'
print(f'Spatial and frame correspondence passed for all 24 {sys.argv[2]} frames')
PY_GEOMETRY
done
