#!/usr/bin/env python3
"""Pure regressions plus opt-in actual FFmpeg/FFprobe qualification matrix.

STREAM_COPY_FFMPEG=/absolute/ffmpeg STREAM_COPY_FFPROBE=/absolute/ffprobe \
python3 -m unittest discover -s scripts -p test_stream_copy_proof.py -v
Optional STREAM_COPY_EVIDENCE=/new/path.json retains only the small summary.
"""
from fractions import Fraction
import importlib.util
import json
import math
import os
from pathlib import Path
import tempfile
import sys
import unittest

spec = importlib.util.spec_from_file_location('stream_copy_proof',
                                               Path(__file__).with_name('stream-copy-proof.py'))
proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proof)


class PacketTests(unittest.TestCase):
    def setUp(self):
        self.stream = {'time_base': '1/48000', 'duration_ts': 3072}
        self.packets = [{'pts': n * 1024, 'dts': n * 1024, 'duration': 1024,
                         'data_hash': 'SHA256:dummy', 'pos': n, 'size': '3072'}
                        for n in range(3)]

    def test_exact_boundaries(self):
        selected = proof.select_range(self.packets, self.stream, Fraction(1024, 48000),
                                      Fraction(3072, 48000))
        self.assertEqual(selected, self.packets[1:])

    def test_reject_split_packet(self):
        for start, end in [(Fraction(1, 48000), Fraction(3072, 48000)),
                           (Fraction(0), Fraction(2049, 48000))]:
            with self.assertRaisesRegex(proof.Ineligible, 'packet boundaries'):
                proof.select_range(self.packets, self.stream, start, end)

    def test_reject_gap_offset_reordering_and_padding(self):
        for field, value in [('pts', 1), ('dts', -1), ('duration', 0),
                             ('side_data_list', [{'side_data_type': 'Skip Samples',
                                                  'skip_samples': 1}])]:
            with self.subTest(field=field):
                packets = [dict(p) for p in self.packets]
                packets[0][field] = value
                with self.assertRaises(proof.Ineligible):
                    proof.select_range(packets, self.stream, Fraction(0), Fraction(3072, 48000))

    def test_microsecond_seek_never_advances(self):
        for rate in (Fraction(24000, 1001), Fraction(30000, 1001), Fraction(60000, 1001)):
            boundary = 17 / rate
            parsed = Fraction(proof.seconds_argument(boundary))
            self.assertLessEqual(parsed, boundary)
            self.assertLess(boundary - parsed, Fraction(1, 1000000))

    def test_timecode_exact_frame_labels(self):
        for rate in (Fraction(24), Fraction(24000, 1001), Fraction(30000, 1001)):
            count = proof.timecode_count('01:00:00:00', rate)
            self.assertEqual(proof.timecode_label(count + 512, rate),
                             '01:00:21:08' if round(rate) == 24 else '01:00:17:02')

    def test_drop_frame_minute_and_tenth_minute_boundaries(self):
        for rate, before, after, tenth_before in [
                (Fraction(30000, 1001), '00:00:59;29', '00:01:00;02', '00:09:59;29'),
                (Fraction(60000, 1001), '00:00:59;59', '00:01:00;04', '00:09:59;59')]:
            with self.subTest(rate=rate):
                self.assertEqual(proof.timecode_label(proof.timecode_count(before, rate) + 1,
                                                     rate, True), after)
                self.assertEqual(proof.timecode_label(proof.timecode_count(tenth_before, rate) + 1,
                                                     rate, True), '00:10:00;00')
                # Exercise all minute boundaries through an entire day, including
                # the frames immediately before/after every skipped-label span.
                nominal, dropped = round(rate), round(rate) // 15
                for minute in range(24 * 60):
                    first = minute * 60 * nominal - dropped * (minute - minute // 10)
                    for count in range(max(0, first - 6), first + 7):
                        label = proof.timecode_label(count, rate, True)
                        self.assertEqual(proof.timecode_count(label, rate), count)
                day = (nominal * 600 - dropped * 9) * 144
                self.assertEqual(proof.timecode_label(day - 1, rate, True),
                                 f'23:59:59;{nominal - 1:02}')
                with self.assertRaisesRegex(proof.Ineligible, 'day wrap'):
                    proof.timecode_label(day, rate, True)

    def test_invalid_drop_frame_labels_and_rates(self):
        for rate in (Fraction(30000, 1001), Fraction(60000, 1001)):
            for minute in ('01', '09', '11', '59'):
                for frame in range(round(rate) // 15):
                    with self.assertRaisesRegex(proof.Ineligible, 'skipped'):
                        proof.timecode_count(f'00:{minute}:00;{frame:02}', rate)
        for rate in (Fraction(24), Fraction(25), Fraction(24000, 1001), Fraction(30), Fraction(60)):
            with self.assertRaisesRegex(proof.Ineligible, 'requires'):
                proof.timecode_count('00:00:00;00', rate)
            with self.assertRaisesRegex(proof.Ineligible, 'requires'):
                proof.timecode_label(0, rate, True)
        for label in ('24:00:00;00', '00:60:00;00', '00:00:60;00', '00:00:00;30', '0:00:00;00'):
            with self.assertRaises(proof.Ineligible):
                proof.timecode_count(label, Fraction(30000, 1001))


class MOVEditTests(unittest.TestCase):
    def test_actual_timecode_description_must_match_video_and_label(self):
        def box(kind, payload):
            return (len(payload) + 8).to_bytes(4, 'big') + kind + payload
        for flags, scale, duration, nominal, valid in [
                (1, 30000, 1001, 30, True), (0, 30000, 1001, 30, False),
                (1, 30000, 1000, 30, False), (1, 30000, 1001, 24, False),
                (9, 30000, 1001, 30, False), (1, 30000, 0, 30, False)]:
            entry = box(b'tmcd', b'\0' * 6 + b'\0\1' + b'\0' * 4 +
                        flags.to_bytes(4, 'big') + scale.to_bytes(4, 'big') +
                        duration.to_bytes(4, 'big') + bytes([nominal, 0]))
            movie = box(b'stsd', b'\0' * 4 + (1).to_bytes(4, 'big') + entry)
            for kind in (b'stbl', b'minf', b'mdia', b'trak', b'moov'):
                movie = box(kind, movie)
            with self.subTest(flags=flags, scale=scale, duration=duration, nominal=nominal):
                with tempfile.TemporaryDirectory() as temp:
                    path = Path(temp) / 'description.mov'
                    path.write_bytes(movie)
                    if valid:
                        proof.require_zero_mov_edits(path, Fraction(30000, 1001), True)
                    else:
                        with self.assertRaises(proof.Ineligible):
                            proof.require_zero_mov_edits(path, Fraction(30000, 1001), True)

    def test_hidden_media_offset_and_empty_edit_rejected(self):
        def box(kind, payload):
            return (len(payload) + 8).to_bytes(4, 'big') + kind + payload
        for offset in (0, -1, 1024):
            edit = (b'\0' * 4 + (1).to_bytes(4, 'big') + (1000).to_bytes(4, 'big') +
                    offset.to_bytes(4, 'big', signed=True) + b'\0\1\0\0')
            movie = box(b'moov', box(b'trak', box(b'edts', box(b'elst', edit))))
            with tempfile.TemporaryDirectory() as temp:
                path = Path(temp) / 'edit.mov'
                path.write_bytes(movie)
                if offset == 0:
                    proof.require_zero_mov_edits(path)
                else:
                    with self.assertRaisesRegex(proof.Ineligible, 'media offset'):
                        proof.require_zero_mov_edits(path)


class BoundedCaptureTests(unittest.TestCase):
    def test_stdout_and_stderr_limits_terminate_child(self):
        tools = proof.Tools(Path(sys.executable), Path(sys.executable))
        for stream, size in [('stdout', 33 * 1024 * 1024), ('stderr', 2 * 1024 * 1024)]:
            with self.subTest(stream=stream):
                with self.assertRaisesRegex(proof.Ineligible, 'bounded capture limit'):
                    tools.run([sys.executable, '-c',
                               f"import sys; sys.{stream}.buffer.write(b'x' * {size})"])


@unittest.skipUnless(os.environ.get('STREAM_COPY_FFMPEG') and os.environ.get('STREAM_COPY_FFPROBE'),
                     'Set explicit FFmpeg/FFprobe paths for real media regressions')
class MediaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='stream-copy-proof-')
        cls.root = Path(cls.temp.name)
        cls.tools = proof.Tools(os.environ['STREAM_COPY_FFMPEG'], os.environ['STREAM_COPY_FFPROBE'])
        cls.results = []
        cls.rejections = []

    @classmethod
    def tearDownClass(cls):
        target = os.environ.get('STREAM_COPY_EVIDENCE')
        if target:
            evidence = {'developmentProofOnly': True, 'appStreamCopyQualified': False,
                        'tools': {name: {'version': cls.tools.run([path, '-version']).decode().splitlines()[0],
                                         'sha256': proof.file_hash(path)}
                                  for name, path in [('ffmpeg', cls.tools.ffmpeg), ('ffprobe', cls.tools.ffprobe)]},
                        'positiveCases': cls.results, 'rejectedCases': cls.rejections}
            with Path(target).open('x') as out:
                json.dump(evidence, out, indent=2)
                out.write('\n')
        cls.temp.cleanup()

    def source(self, name, rate, frames, video='prores_ks', audio='pcm_s24le', open_gop=False,
               timecode='01:00:00:00', picture_offset=0):
        path = self.root / f'{name}.mov'
        if path.exists():
            return path
        duration = frames / rate
        samples = duration * 48000
        self.assertEqual(samples.denominator, 1)
        # A unique 12-bit luma barcode distinguishes every source frame. Unequal
        # stereo time-varying tones make audio offset/channel errors observable.
        image = (f'testsrc2=size=64x32:rate={rate}:duration={proof.seconds_argument(duration)},'
                 f"geq=lum='32+192*mod(floor((N+{picture_offset})/pow(2,floor(X/4))),2)':cb=128:cr=128")
        sound = ("aevalsrc=0.1*sin(2*PI*(440*t+20*t*t))|0.1*sin(2*PI*(880*t+31*t*t))"
                 f':s=48000,atrim=end_sample={int(samples)}')
        options = ['-c:v', video]
        if video == 'prores_ks':
            options += ['-profile:v', '3', '-pix_fmt', 'yuv422p10le']
        else:
            options += ['-pix_fmt', 'yuv420p', '-g', '48', '-bf', '2']
            if open_gop:
                options += ['-x264-params', 'open-gop=1']
        self.tools.ff(['-f', 'lavfi', '-i', image, '-f', 'lavfi', '-i', sound,
                       '-map', '0:v:0', '-map', '1:a:0', *options, '-c:a', audio,
                       '-timecode', timecode, path])
        return path

    def test_real_exact_remux_matrix(self):
        for name, rate in [('24', Fraction(24)), ('25', Fraction(25)),
                           ('23976', Fraction(24000, 1001)),
                           ('2997', Fraction(30000, 1001)),
                           ('5994', Fraction(60000, 1001))]:
            with self.subTest(rate=rate):
                # Shared packet boundaries: frame time and 1024 PCM samples.
                samples_per_frame = 48000 / rate
                unit = (1024 * samples_per_frame.denominator //
                        math.gcd(samples_per_frame.numerator, 1024))
                source = self.source(name, rate, unit * 2 + 5)
                scratch = self.root / f'{name}-verified'
                scratch.mkdir(mode=0o700)
                result = proof.verify(self.tools, source, unit / rate, 2 * unit / rate, scratch)
                self.results.append({'case': name, **result})
                self.assertTrue(result['sourceUnchanged'])

    def test_real_unsupported_and_unaligned_sources(self):
        rate = Fraction(24)
        source = self.source('negative-pcm', rate, 133)
        for name, path, start, end, reason in [
                ('non-frame-cut', source, Fraction(1, 48000), Fraction(128, 24), 'video-frame'),
                ('non-packet-audio-cut', source, Fraction(1, 24), Fraction(128, 24), 'packet boundaries'),
                ('interframe-h264', self.source('negative-h264', rate, 133, video='libx264'),
                 Fraction(64, 24), Fraction(128, 24), 'Only ProRes'),
                ('open-gop-h264', self.source('negative-open-h264', rate, 133,
                                             video='libx264', open_gop=True),
                 Fraction(64, 24), Fraction(128, 24), 'Only ProRes'),
                ('compressed-aac', self.source('negative-aac', rate, 133, audio='aac'),
                 Fraction(64, 24), Fraction(128, 24), 'Only signed')]:
            with self.subTest(case=name):
                with self.assertRaisesRegex(proof.Ineligible, reason) as raised:
                    proof.qualify(self.tools, path, start, end)
                self.rejections.append({'case': name, 'reason': str(raised.exception)})

    def test_real_drop_frame_remux_boundaries(self):
        for rate in (Fraction(30000, 1001), Fraction(60000, 1001)):
            for minute in ('00', '09'):
                name = f'df-{round(rate)}-minute-{minute}'
                # Exactly shared video/1024-sample PCM boundaries; these trims
                # advance from second 50 across a skipped or tenth-minute boundary.
                samples_per_frame = 48000 / rate
                unit = 1024 * samples_per_frame.denominator // math.gcd(samples_per_frame.numerator, 1024)
                source = self.source(name, rate, unit * 2 + 5, timecode=f'00:{minute}:50;00')
                scratch = self.root / f'{name}-verified'
                scratch.mkdir(mode=0o700)
                result = proof.verify(self.tools, source, unit / rate, 2 * unit / rate, scratch)
                self.results.append({'case': name, **result})
                self.assertTrue(result['dropFrameTimecode'])
                expected_count = proof.timecode_count(f'00:{minute}:50;00', rate) + unit
                self.assertEqual(proof.timecode_count(result['timecode'], rate), expected_count)

    def test_real_drop_frame_day_wrap_refused_before_remux(self):
        rate = Fraction(30000, 1001)
        source = self.source('df-day-wrap', rate, 1285, timecode='23:59:50;00')
        scratch = self.root / 'df-day-wrap-rejected'
        scratch.mkdir(mode=0o700)
        with self.assertRaisesRegex(proof.Ineligible, 'day wrap') as raised:
            proof.verify(self.tools, source, Fraction(0), Fraction(640, 1) / rate, scratch)
        self.assertFalse((scratch / 'copy.mov').exists())
        self.rejections.append({'case': 'df-day-wrap', 'reason': str(raised.exception)})

    def test_real_exact_cuts_only_concatenation(self):
        for name, rate, label in [('24', Fraction(24), '00:00:50:00'),
                                  ('23976', Fraction(24000, 1001), '00:00:50:00'),
                                  ('2997df', Fraction(30000, 1001), '00:00:50;00'),
                                  ('5994df', Fraction(60000, 1001), '00:09:50;00')]:
            with self.subTest(rate=rate):
                samples_per_frame = 48000 / rate
                unit = 1024 * samples_per_frame.denominator // math.gcd(samples_per_frame.numerator, 1024)
                first = self.source(f'concat-{name}-a', rate, unit * 2 + 5, timecode=label)
                second = self.source(f'concat-{name}-b', rate, unit * 2 + 5,
                                     timecode=label, picture_offset=2048)
                scratch = self.root / f'concat-{name}-verified'
                scratch.mkdir(mode=0o700)
                # Different original files and different nonzero trims; unique
                # picture barcodes expose cut order and stale range mistakes.
                result = proof.verify_concat(self.tools, [(first, unit / rate, 2 * unit / rate),
                                                          (second, Fraction(0), unit / rate)], scratch)
                self.results.append({'case': f'concat-{name}', **result})
                self.assertEqual(result['videoPacketsAndDecodedFrames'], unit * 2)
                self.assertTrue(result['allCutBoundaryFramesDecodeIndependently'])

    def test_real_concatenation_rejects_format_mismatch(self):
        rate = Fraction(24)
        first = self.source('concat-mismatch-24bit', rate, 133)
        second = self.source('concat-mismatch-16bit', rate, 133, audio='pcm_s16le')
        scratch = self.root / 'concat-mismatch-rejected'
        scratch.mkdir(mode=0o700)
        with self.assertRaisesRegex(proof.Ineligible, 'formats differ') as raised:
            proof.verify_concat(self.tools, [(first, Fraction(64, 24), Fraction(128, 24)),
                                             (second, Fraction(64, 24), Fraction(128, 24))], scratch)
        self.assertFalse((scratch / 'copy.mov').exists())
        self.rejections.append({'case': 'concat-audio-format-mismatch', 'reason': str(raised.exception)})

    def test_output_cannot_overwrite_existing_file(self):
        output = self.root / 'existing.mov'
        output.write_bytes(b'keep original')
        with self.assertRaisesRegex(proof.Ineligible, 'overwrite'):
            self.tools.ff(['-f', 'lavfi', '-i', 'testsrc2=duration=0.1', output])
        self.assertEqual(output.read_bytes(), b'keep original')


if __name__ == '__main__':
    unittest.main()
