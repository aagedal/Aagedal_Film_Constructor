#!/usr/bin/env python3
"""Bounded development qualification of one exact ProRes/PCM MOV range.

No app integration or generalized codec support. Output remains in a new private
scratch directory; source originals are opened read-only. All timing uses Fractions.
"""
import argparse
from fractions import Fraction
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import time


class Ineligible(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise Ineligible(message)


class Tools:
    def __init__(self, ffmpeg, ffprobe):
        self.ffmpeg, self.ffprobe = map(Path, (ffmpeg, ffprobe))
        for path in (self.ffmpeg, self.ffprobe):
            require(path.is_absolute() and os.access(path, os.X_OK),
                    'Supply absolute executable FFmpeg and FFprobe paths')

    def run(self, command):
        command = list(map(str, command))
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        buffers = {'stdout': bytearray(), 'stderr': bytearray()}
        deadline = time.monotonic() + 60
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ, 'stdout')
        selector.register(process.stderr, selectors.EVENT_READ, 'stderr')
        try:
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(command, 60)
                for key, _ in selector.select(min(remaining, 1)):
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    limit = 32 * 1024 * 1024 if key.data == 'stdout' else 1024 * 1024
                    require(len(buffers[key.data]) + len(chunk) <= limit,
                            'Probe/decode output exceeds bounded capture limit')
                    buffers[key.data].extend(chunk)
            status = process.wait(timeout=max(0.001, deadline - time.monotonic()))
            if status:
                raise subprocess.CalledProcessError(status, command,
                                                    stderr=bytes(buffers['stderr']))
            return bytes(buffers['stdout'])
        finally:
            selector.close()
            if process.poll() is None:
                process.kill()
            process.wait()
            process.stdout.close()
            process.stderr.close()

    def probe(self, path):
        require(path.is_file() and path.stat().st_size <= 128 * 1024 * 1024,
                'Source must be a regular file no larger than 128 MiB')
        return json.loads(self.run([self.ffprobe, '-v', 'error', '-show_streams',
                                   '-show_format', '-show_packets', '-show_data_hash',
                                   'sha256', '-of', 'json', path]))

    def ff(self, arguments):
        require(arguments[-1] == '-' or not Path(arguments[-1]).exists(),
                'Refusing to overwrite existing output')
        return self.run([self.ffmpeg, '-v', 'error', '-nostdin', '-n', *arguments])

    def video_hashes(self, path, image=False):
        arguments = ['-f', 'image2', '-c:v', 'prores'] if image else []
        result = self.ff([*arguments, '-i', path, '-map', '0:v:0', '-fps_mode',
                          'passthrough', '-pix_fmt', 'yuv422p10le', '-f', 'framemd5', '-'])
        return [line.split(',')[-1].strip() for line in result.decode().splitlines()
                if line and not line.startswith('#')]

    def audio(self, path, codec):
        # PCM widths are preserved, with no float conversion or dithering.
        return self.ff(['-i', path, '-map', '0:a:0', '-c:a', codec,
                        '-f', {'pcm_s16le': 's16le', 'pcm_s24le': 's24le'}[codec], '-'])


def stamp(packet, stream, field='pts'):
    return int(packet[field]) * Fraction(stream['time_base'])


def packets_for(probe, stream):
    return [p for p in probe['packets'] if p['stream_index'] == stream['index']]


def select_range(packets, stream, start, end):
    require(bool(packets), 'Missing media packets')
    cursor = Fraction(0)
    for packet in packets:
        require(all(k in packet for k in ('pts', 'dts', 'duration', 'data_hash', 'pos')),
                'Missing packet timing/payload evidence')
        require(stamp(packet, stream) == stamp(packet, stream, 'dts') == cursor,
                'Nonzero offset, reordered timestamps, overlap or packet gap')
        duration = stamp(packet, stream, 'duration')
        require(duration > 0, 'Zero or negative packet duration')
        require(not packet.get('side_data_list'), 'Packet delay/padding/side data is unsupported')
        cursor += duration
    require(cursor == int(stream['duration_ts']) * Fraction(stream['time_base']),
            'Stream duration differs from packet extent')
    selected = [p for p in packets if start <= stamp(p, stream) < end]
    require(bool(selected) and stamp(selected[0], stream) == start and
            stamp(selected[-1], stream) + stamp(selected[-1], stream, 'duration') == end,
            'Range is not aligned to exact packet boundaries')
    return selected


def timecode_count(label, rate):
    # Deliberately restrict this proof to non-drop labels and the tested CFR rates.
    match = re.fullmatch(r'(\d\d):(\d\d):(\d\d):(\d\d)', label or '')
    require(match is not None, 'Only explicit non-drop MOV timecode is qualified')
    hour, minute, second, frame = map(int, match.groups())
    nominal = round(rate)
    require(hour < 24 and minute < 60 and second < 60 and frame < nominal,
            'Invalid timecode label')
    return ((hour * 60 + minute) * 60 + second) * nominal + frame


def timecode_label(count, rate):
    nominal = round(rate)
    require(0 <= count < 86400 * nominal, 'Timecode day wrap is unsupported')
    seconds, frame = divmod(count, nominal)
    minutes, second = divmod(seconds, 60)
    hour, minute = divmod(minutes, 60)
    return f'{hour:02}:{minute:02}:{second:02}:{frame:02}'


def packet_bytes(path, packet):
    with path.open('rb') as source:
        source.seek(int(packet['pos']))
        data = source.read(int(packet['size']))
    require(len(data) == int(packet['size']), 'Truncated packet payload')
    require('SHA256:' + hashlib.sha256(data).hexdigest() == packet['data_hash'],
            'Packet payload changed during qualification')
    return data


def require_zero_mov_edits(path):
    """Inspect MOV edit lists; FFprobe can conceal media offsets by rebasing them."""
    boxes = 0
    with path.open('rb') as source:
        def walk(start, end, depth=0):
            nonlocal boxes
            require(depth <= 8, 'MOV nesting exceeds proof bound')
            position = start
            while position < end:
                boxes += 1
                require(boxes <= 10000 and end - position >= 8, 'Invalid/bounded MOV box layout')
                source.seek(position)
                header = source.read(8)
                size, kind = int.from_bytes(header[:4], 'big'), header[4:]
                header_size = 8
                if size == 1:
                    extended = source.read(8)
                    require(len(extended) == 8, 'Truncated MOV box')
                    size, header_size = int.from_bytes(extended, 'big'), 16
                elif size == 0:
                    size = end - position
                require(size >= header_size and position + size <= end, 'Invalid MOV box extent')
                payload = position + header_size
                if kind in (b'moov', b'trak', b'edts'):
                    walk(payload, position + size, depth + 1)
                elif kind == b'elst':
                    require(size - header_size <= 128, 'Multiple/oversize MOV edits are unsupported')
                    source.seek(payload)
                    data = source.read(size - header_size)
                    require(len(data) >= 8 and data[0] in (0, 1) and data[1:4] == b'\0\0\0' and
                            int.from_bytes(data[4:8], 'big') == 1, 'Only a single zero-offset MOV edit is qualified')
                    width = 4 if data[0] == 0 else 8
                    require(len(data) == 8 + 2 * width + 4 and
                            int.from_bytes(data[8 + width:8 + 2 * width], 'big', signed=True) == 0 and
                            data[-4:] == b'\0\1\0\0',
                            'Nonzero MOV media offset, preroll, delay or rate edit is unsupported')
                position += size
        walk(0, path.stat().st_size)


def qualify(tools, source, start, end):
    probe = tools.probe(source)
    require('mov' in probe['format']['format_name'].split(',') and
            probe['format'].get('tags', {}).get('major_brand') == 'qt  ',
            'Only QuickTime MOV input is qualified')
    require(Fraction(probe['format']['duration']) <= 60, 'Source exceeds 60-second proof bound')
    videos = [s for s in probe['streams'] if s['codec_type'] == 'video']
    audios = [s for s in probe['streams'] if s['codec_type'] == 'audio']
    timecodes = [s for s in probe['streams'] if s.get('codec_tag_string') == 'tmcd']
    require(len(videos) == len(audios) == len(timecodes) == 1 and len(probe['streams']) == 3,
            'Require exactly one video, one audio and one timecode stream')
    video, audio, tc = videos[0], audios[0], timecodes[0]
    require(video['codec_name'] == 'prores' and video.get('codec_tag_string') == 'apch' and
            video.get('profile') == 'HQ' and video.get('pix_fmt') == 'yuv422p10le',
            'Only ProRes HQ apch yuv422p10le intra video is qualified; keyframe flags are insufficient')
    require(audio['codec_name'] in ('pcm_s16le', 'pcm_s24le'),
            'Only signed little-endian integer PCM audio is qualified')
    require_zero_mov_edits(source)
    require(int(audio['sample_rate']) == 48000 and audio['channels'] in (1, 2),
            'Require 48 kHz mono/stereo whole-stream PCM')
    rate = Fraction(video['avg_frame_rate'])
    require(rate in (Fraction(24), Fraction(25), Fraction(24000, 1001),
                     Fraction(30000, 1001), Fraction(60000, 1001)), 'Untested frame rate')
    require(Fraction(video['r_frame_rate']) == rate and
            video.get('sample_aspect_ratio') == '1:1' and
            video['width'] <= 640 and video['height'] <= 360,
            'Require bounded square-pixel CFR geometry')
    require(0 <= start < end and (start * rate).denominator == (end * rate).denominator == 1,
            'Require exact video-frame range boundaries')
    for stream in (video, audio, tc):
        require(stream.get('start_pts') == 0 and not stream.get('side_data_list') and
                not any(int(stream.get(k, 0)) for k in ('initial_padding', 'trailing_padding', 'codec_delay')),
                'Nonzero stream offsets, rotation, delay/padding or side data are unsupported')
    vp = select_range(packets_for(probe, video), video, start, end)
    ap = select_range(packets_for(probe, audio), audio, start, end)
    require(len(packets_for(probe, video)) <= 5000, 'Too many video packets')
    require(all(stamp(p, video, 'duration') == 1 / rate for p in packets_for(probe, video)),
            'Video is not exact CFR')
    require(int(video['duration_ts']) * Fraction(video['time_base']) ==
            int(audio['duration_ts']) * Fraction(audio['time_base']), 'Source A/V extents differ')
    width = {'pcm_s16le': 2, 'pcm_s24le': 3}[audio['codec_name']] * audio['channels']
    for p in packets_for(probe, audio):
        require(int(p['size']) == stamp(p, audio, 'duration') * 48000 * width,
                'PCM payload size is not exact unpadded samples')
    # ProRes frame headers plus actual isolated boundary decoding establish more
    # than keyframe flags. Codec support is intentionally restricted to ProRes HQ.
    for p in packets_for(probe, video):
        data = packet_bytes(source, p)
        require(len(data) >= 8 and data[4:8] == b'icpf' and
                int.from_bytes(data[:4], 'big') == len(data), 'Invalid ProRes frame payload')
    tcp = packets_for(probe, tc)
    require(len(tcp) == 1 and stamp(tcp[0], tc) == 0 and int(tcp[0]['size']) == 4 and
            stamp(tcp[0], tc, 'duration') == int(video['duration_ts']) * Fraction(video['time_base']),
            'Unsupported MOV timecode packet extent')
    label = video.get('tags', {}).get('timecode')
    count = timecode_count(label, rate)
    require(tc.get('tags', {}).get('timecode') == label and
            int.from_bytes(packet_bytes(source, tcp[0]), 'big') == count,
            'Timecode label and underlying frame count differ')
    return probe, video, audio, vp, ap, rate, count


def seconds_argument(value):
    # FFmpeg seek options have microsecond precision. Truncate toward zero so a
    # fractional boundary cannot advance to the next packet. Verification below
    # requires exact rebased ticks in each output stream, irrespective of rounding.
    micros = value * 1000000
    ticks = micros.numerator // micros.denominator
    return f'{ticks // 1000000}.{ticks % 1000000:06}'


def file_hash(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def verify(tools, source, start, end, scratch):
    require(scratch.is_dir() and scratch.stat().st_mode & 0o777 == 0o700,
            'Scratch must be a private directory with mode 0700')
    require(not (scratch / 'copy.mov').exists(), 'Refusing to overwrite existing output')
    require(source.is_file() and source.stat().st_size <= 128 * 1024 * 1024,
            'Source must be a regular file no larger than 128 MiB')
    initial_hash = file_hash(source)
    probe, video, audio, vp, ap, rate, count = qualify(tools, source, start, end)
    output = scratch / 'copy.mov'
    label = timecode_label(count + int(start * rate), rate)
    tools.ff(['-i', source, '-ss', seconds_argument(start), '-t', seconds_argument(end - start),
              '-map', f"0:{video['index']}", '-map', f"0:{audio['index']}", '-c', 'copy',
              '-timecode', label, output])
    result = tools.probe(output)
    require_zero_mov_edits(output)
    ov = next(s for s in result['streams'] if s['codec_type'] == 'video')
    oa = next(s for s in result['streams'] if s['codec_type'] == 'audio')
    duration = end - start
    for original, copied, packets in ((video, ov, vp), (audio, oa, ap)):
        fields = ('codec_name', 'codec_tag_string', 'profile', 'pix_fmt', 'width', 'height',
                  'sample_aspect_ratio', 'color_range', 'color_space', 'color_transfer',
                  'color_primaries', 'chroma_location', 'field_order', 'sample_rate',
                  'channels', 'channel_layout', 'bits_per_raw_sample', 'extradata_hash')
        require(all(original.get(k) == copied.get(k) for k in fields),
                'Codec/geometry/color/channel metadata changed')
        actual = select_range(packets_for(result, copied), copied, Fraction(0), duration)
        require(len(actual) == len(packets), 'Packet count changed')
        require(copied.get('start_pts') == 0 and
                int(copied['duration_ts']) * Fraction(copied['time_base']) == duration,
                'Output start/duration is not exact')
        for src, dst in zip(packets, actual):
            require(src['data_hash'] == dst['data_hash'] and src['size'] == dst['size'],
                    'Packet payload changed')
            require(stamp(src, original) - start == stamp(dst, copied) and
                    stamp(src, original, 'dts') - start == stamp(dst, copied, 'dts') and
                    stamp(src, original, 'duration') == stamp(dst, copied, 'duration'),
                    'Output timestamps changed beyond exact rebasing')
    require(Fraction(ov['avg_frame_rate']) == Fraction(ov['r_frame_rate']) == rate,
            'Output frame rate changed')
    otc = next(s for s in result['streams'] if s.get('codec_tag_string') == 'tmcd')
    otcp = packets_for(result, otc)
    require(len(otcp) == 1 and ov.get('tags', {}).get('timecode') == label and
            otc.get('tags', {}).get('timecode') == label and stamp(otcp[0], otc) == 0 and
            stamp(otcp[0], otc, 'duration') == duration and
            int.from_bytes(packet_bytes(output, otcp[0]), 'big') == count + int(start * rate),
            'Output timecode packet/label/extent differs from source range')
    original_frames = tools.video_hashes(source)
    offset, frames = int(start * rate), int(duration * rate)
    require(len(original_frames) == len(packets_for(probe, video)), 'Source decoded frame count differs')
    copied_frames = tools.video_hashes(output)
    require(copied_frames == original_frames[offset:offset + frames] and len(copied_frames) == frames,
            'Decoded range frames changed')
    # Decode first and last compressed packets in separate fresh decoder processes.
    for name, path, stream_packets, expected in (
            ('source', source, vp, copied_frames),
            ('output', output, packets_for(result, ov), copied_frames)):
        for index in (0, len(stream_packets) - 1):
            packet_path = scratch / f'{name}-{index}.prores'
            with packet_path.open('xb') as isolated:
                isolated.write(packet_bytes(path, stream_packets[index]))
            require(tools.video_hashes(packet_path, image=True) == [expected[index]],
                    'Boundary frame is not independently decodable')
    original_pcm = tools.audio(source, audio['codec_name'])
    copied_pcm = tools.audio(output, audio['codec_name'])
    sample_start, samples = start * 48000, duration * 48000
    require(sample_start.denominator == samples.denominator == 1, 'Nonintegral audio samples')
    width = {'pcm_s16le': 2, 'pcm_s24le': 3}[audio['codec_name']] * audio['channels']
    require(len(copied_pcm) == int(samples) * width and copied_pcm ==
            original_pcm[int(sample_start) * width:int(sample_start + samples) * width],
            'Decoded audio samples changed, were padded or lost')
    require(file_hash(source) == initial_hash, 'Source changed')
    return {'sourceSHA256': initial_hash, 'sourceRange': [str(start), str(end)],
            'duration': str(duration), 'frameRate': str(rate), 'timecode': label,
            'videoPacketsAndDecodedFrames': frames, 'audioPackets': len(ap),
            'audioSamplesPerChannel': int(samples), 'channels': audio['channels'],
            'allPacketPayloadsAndExactTimestampsMatch': True,
            'allDecodedFramesAndAudioSamplesMatch': True,
            'isolatedFirstLastFramesMatch': True, 'sourceUnchanged': True,
            'appStreamCopyQualified': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ffmpeg', type=Path)
    parser.add_argument('ffprobe', type=Path)
    parser.add_argument('source', type=Path)
    parser.add_argument('start', type=Fraction, help='Exact seconds, e.g. 64064/3000')
    parser.add_argument('end', type=Fraction)
    parser.add_argument('scratch', type=Path, help='New absolute private output directory')
    args = parser.parse_args()
    try:
        tools = Tools(args.ffmpeg, args.ffprobe)
        require(args.source.is_absolute(), 'Source path must be absolute')
        require(args.scratch.is_absolute() and not args.scratch.exists(),
                'Scratch must be a new absolute directory')
        args.scratch.mkdir(mode=0o700)
        result = verify(tools, args.source, args.start, args.end, args.scratch)
        (args.scratch / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2))
    except (Ineligible, subprocess.SubprocessError, OSError, KeyError, ValueError) as error:
        parser.exit(1, f'Not qualified: {error}\n')


if __name__ == '__main__':
    main()
