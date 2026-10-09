#!/bin/bash
# Development-only proof. Never discovers or packages a user's FFmpeg installation.
set -euo pipefail

if [[ $# -ne 2 || ! -x "$1" ]]; then
    echo "Usage: $0 /absolute/path/to/ffmpeg /new/output/directory" >&2
    exit 2
fi
FFMPEG_EXECUTABLE="$1"
PROOF_DIRECTORY="$2"
if [[ "$FFMPEG_EXECUTABLE" != /* || -e "$PROOF_DIRECTORY" ]]; then
    echo "FFmpeg must be an absolute executable path; output directory must be new." >&2
    exit 2
fi
mkdir -p "$PROOF_DIRECTORY"
"$FFMPEG_EXECUTABLE" -version > "$PROOF_DIRECTORY/ffmpeg-version.txt" 2>&1
shasum -a 256 "$FFMPEG_EXECUTABLE" > "$PROOF_DIRECTORY/ffmpeg.sha256"

# A: source [1, 7.006), timeline start 0. B: source [2, 6.006), start 2.
# B is the upper track and wins the overlap. Audio A/B use complementary qsin
# envelopes over sequence [2, 3); the third tone has quarter-second edge fades.
GRAPH='[0:v]trim=start=1:end=7.006,setpts=PTS-STARTPTS,format=yuv444p[a];[1:v]trim=start=2:end=6.006,setpts=PTS-STARTPTS+2/TB,format=yuv444p[b];[a][b]overlay=eof_action=pass:repeatlast=0:format=yuv444[v];[2:a]atrim=start=1:end=7.006,asetpts=PTS-STARTPTS,afade=t=out:st=2:d=1:curve=qsin,pan=stereo|c0=c0|c1=0*c0[a1];[3:a]atrim=start=2:end=6.006,asetpts=PTS-STARTPTS,afade=t=in:st=0:d=1:curve=qsin,pan=stereo|c0=0*c0|c1=c0,adelay=96000S:all=1[a2];[4:a]atrim=start=0.5:end=3.5,asetpts=PTS-STARTPTS,afade=t=in:st=0:d=0.25:curve=qsin,afade=t=out:st=2.75:d=0.25:curve=qsin,pan=stereo|c0=c0|c1=c0,adelay=72000S:all=1[a3];[a1][a2][a3]amix=inputs=3:normalize=0,apad,atrim=end_sample=288288[audio]'
printf '%s\n' "$GRAPH" > "$PROOF_DIRECTORY/filtergraph.txt"
"$FFMPEG_EXECUTABLE" -hide_banner -nostdin -y \
    -f lavfi -i 'color=red:size=320x180:rate=30000/1001:duration=9' \
    -f lavfi -i 'color=blue:size=320x180:rate=30000/1001:duration=10' \
    -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=9' \
    -f lavfi -i 'sine=frequency=880:sample_rate=48000:duration=10' \
    -f lavfi -i 'sine=frequency=1320:sample_rate=48000:duration=4' \
    -filter_complex "$GRAPH" -map '[v]' -map '[audio]' \
    -frames:v 180 -r 30000/1001 -fps_mode cfr \
    -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le \
    -c:a pcm_s24le -ar 48000 -ac 2 -video_track_timescale 30000 \
    -timecode '01:00:00;00' "$PROOF_DIRECTORY/render.mov" \
    > "$PROOF_DIRECTORY/render.log" 2>&1

# Decode the actual muxed file, rather than trusting the render progress counter.
"$FFMPEG_EXECUTABLE" -hide_banner -nostdin -i "$PROOF_DIRECTORY/render.mov" \
    -map 0:v:0 -fps_mode passthrough -f framemd5 "$PROOF_DIRECTORY/video.framemd5" \
    > "$PROOF_DIRECTORY/video-decode.log" 2>&1
"$FFMPEG_EXECUTABLE" -hide_banner -nostdin -i "$PROOF_DIRECTORY/render.mov" \
    -map 0:a:0 -c:a pcm_s16le -ar 48000 -ac 2 -f s16le "$PROOF_DIRECTORY/audio.s16le" \
    > "$PROOF_DIRECTORY/audio-decode.log" 2>&1
"$FFMPEG_EXECUTABLE" -hide_banner -nostdin -i "$PROOF_DIRECTORY/render.mov" \
    -map 0:v:0 -vf 'select=eq(n\,15)+eq(n\,75)+eq(n\,150),crop=2:2,scale=1:1' \
    -fps_mode passthrough -pix_fmt rgb24 -f rawvideo "$PROOF_DIRECTORY/colors.rgb" \
    > "$PROOF_DIRECTORY/colors-decode.log" 2>&1

python3 - "$PROOF_DIRECTORY" <<'PY'
from pathlib import Path
import json
import math
import struct
import sys

root = Path(sys.argv[1])
records = [line for line in (root / "video.framemd5").read_text().splitlines()
           if line and not line.startswith("#")]
assert len(records) == 180, f"Expected 180 decoded frames, got {len(records)}"
md5 = (root / "video.framemd5").read_text()
assert "#tb 0: 1001/30000" in md5, "Decoded frame time base differs"
colors = (root / "colors.rgb").read_bytes()
assert len(colors) == 9, f"Expected three RGB samples, got {len(colors)} bytes"
video_checks = []
for index, (frame, expected) in enumerate(((15, "red"), (75, "blue"), (150, "blue"))):
    rgb = list(colors[3 * index:3 * index + 3])
    selected = 0 if expected == "red" else 2
    assert rgb[selected] > 220 and all(rgb[c] < 30 for c in range(3) if c != selected), (
        f"Expected {expected} upper-track result at frame {frame}, got {rgb}"
    )
    video_checks.append({"frame": frame, "timeSeconds": frame * 1001 / 30000,
                         "expectedColor": expected, "decodedRGB": rgb})
samples = (root / "audio.s16le").stat().st_size // 4
assert samples == 288288, f"Expected 288288 stereo PCM samples, got {samples}"
pcm = (root / "audio.s16le").read_bytes()
def tone_amplitude(time, channel, frequency):
    start = round(time * 48000)
    count = 4800
    values = [struct.unpack_from("<h", pcm, 4 * (start + i) + 2 * channel)[0]
              for i in range(count)]
    real = sum(value * math.cos(2 * math.pi * frequency * i / 48000)
               for i, value in enumerate(values))
    imaginary = sum(value * math.sin(2 * math.pi * frequency * i / 48000)
                    for i, value in enumerate(values))
    return 2 * math.hypot(real, imaginary) / count

# Qualify routing and offsets at deterministic interior points, away from cuts.
audio_checks = []
for time, expected_left, expected_right in [
    (0.5, {440}, set()), (1.75, {440, 1320}, {1320}),
    (2.25, {440, 1320}, {880, 1320}), (5, set(), {880})
]:
    for channel, expected in enumerate((expected_left, expected_right)):
        for frequency in (440, 880, 1320):
            amplitude = tone_amplitude(time, channel, frequency)
            present = frequency in expected
            assert (amplitude > 1000 if present else amplitude < 20), (
                f"Unexpected {frequency} Hz at {time}s channel {channel}: {amplitude}"
            )
    audio_checks.append({"timeSeconds": time, "leftHz": sorted(expected_left),
                         "rightHz": sorted(expected_right)})
# Check the changing crossfade gain, not just that the two frequencies exist.
for time in (2.25, 2.75):
    # Average the smooth envelope across the same 100 ms analysis window.
    angle = (time - 2) * math.pi / 2
    width = 0.1 * math.pi / 2
    expected_out = 4095 * (math.sin(angle + width) - math.sin(angle)) / width
    expected_in = 4095 * (math.cos(angle) - math.cos(angle + width)) / width
    assert abs(tone_amplitude(time, 0, 440) - expected_out) < 50
    assert abs(tone_amplitude(time, 1, 880) - expected_in) < 50
decode_log = (root / "video-decode.log").read_text()
assert "01:00:00;00" in decode_log, "Expected drop-frame timecode was not read back"
result = {"decodedVideoFrames": len(records), "frameRate": "30000/1001",
          "audioSamplesPerChannel": samples, "sampleRate": 48000,
          "durationSeconds": samples / 48000, "timecode": "01:00:00;00",
          "audioRoutingChecks": audio_checks,
          "videoTrackOrderChecks": video_checks, "audioCrossfadeCurve": "qsin",
          "mpvParityTested": False}
(root / "result.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2))
PY
