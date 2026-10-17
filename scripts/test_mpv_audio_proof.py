import importlib.util
from pathlib import Path
import struct
import subprocess
import sys
import unittest

spec = importlib.util.spec_from_file_location('audio_proof', Path(__file__).with_name('mpv-audio-proof.py'))
proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proof)


def audio(values):
    return struct.pack('<' + 'f' * len(values), *values)


class AudioComparisonTests(unittest.TestCase):
    def test_pns_control_changes_only_explicit_aac_fixture_encoding(self):
        for codec in ('pcm_s16le', 'alac', 'libmp3lame'):
            for mode in ('default', 'on', 'off'):
                self.assertEqual(proof.audio_encoder_arguments(codec, mode), ['-c:a', codec])
        self.assertEqual(proof.audio_encoder_arguments('aac', 'default'), ['-c:a', 'aac'])
        self.assertEqual(proof.audio_encoder_arguments('aac', 'on'), ['-c:a', 'aac', '-aac_pns', '1'])
        self.assertEqual(proof.audio_encoder_arguments('aac', 'off'), ['-c:a', 'aac', '-aac_pns', '0'])
        with self.assertRaises(ValueError):
            proof.audio_encoder_arguments('aac', 'repair')

    def test_basic_mov_control_requires_forced_lavf_before_running(self):
        completed = subprocess.run(
            [sys.executable, str(Path(proof.__file__)), '--mov-edit-list', 'basic',
             '/missing/checkout', '/missing/artifacts', '/missing/ffmpeg', '/missing/output'],
            capture_output=True, text=True)
        self.assertEqual(completed.returncode, 2)
        self.assertIn('--mov-edit-list basic requires --demuxer lavf', completed.stderr)

    def test_pts_filter_requires_its_own_finite_preroll(self):
        invalid = (['--range-mode', 'pts-filter'],
                   ['--filter-preroll', '0.5'],
                   ['--range-mode', 'sample-filter', '--filter-preroll', '0'],
                   *(['--range-mode', 'pts-filter', '--filter-preroll', value]
                     for value in ('nan', 'inf', '-0.1', '3600.1')))
        for options in invalid:
            with self.subTest(options=options):
                completed = subprocess.run(
                    [sys.executable, str(Path(proof.__file__)), *options,
                     '/missing/checkout', '/missing/artifacts', '/missing/ffmpeg', '/missing/output'],
                    capture_output=True, text=True)
                self.assertEqual(completed.returncode, 2)
                self.assertIn('--range-mode pts-filter requires --filter-preroll', completed.stderr)

    def test_seek_offset_rejects_nonfinite_negative_and_filter_modes(self):
        for options in (['--seek-offset', 'nan'], ['--seek-offset', 'inf'],
                        ['--seek-offset', '-0.1'], ['--seek-offset', '1e300'],
                        ['--seek-offset', '0.1', '--range-mode', 'sample-filter']):
            with self.subTest(options=options):
                completed = subprocess.run(
                    [sys.executable, str(Path(proof.__file__)), *options,
                     '/missing/checkout', '/missing/artifacts', '/missing/ffmpeg', '/missing/output'],
                    capture_output=True, text=True)
                self.assertEqual(completed.returncode, 2)
                self.assertIn('--seek-offset requires finite nonnegative seconds', completed.stderr)

    def test_seek_offset_readback_matches_mpv_float_storage_exactly(self):
        proof.validate_seek_offset(0.10000000149011612, 0.1)
        proof.validate_seek_offset(0, 0)
        for observed in (None, True, float('nan'), float('inf'), 0.1, 0.2):
            with self.subTest(observed=observed), self.assertRaises(ValueError):
                proof.validate_seek_offset(observed, 0.1)

    def test_embedded_control_checks_identity_output_and_seek_target(self):
        base = {'passed': True, 'decoder': 'aac', 'seekZero': False,
                'seekFirstPacket': True, 'useFrameDuration': False,
                'ffIndex': 2, 'sampleRate': 48000, 'channels': 2,
                'samplesPerChannel': 2, 'seekTarget': -1024, 'firstPacketPTS': -1024}
        data = audio([0] * 4)
        proof.validate_embedded_metadata(base, data, 2, 48000, 2, 'seek-first-packet')
        with self.assertRaises(ValueError):
            proof.validate_embedded_metadata(base, data, 2, 48000, 2, 'unknown')
        duration = dict(base, useFrameDuration=True)
        proof.validate_embedded_metadata(duration, data, 2, 48000, 2, 'seek-first-packet-duration')
        for key, value in (('seekZero', True), ('seekFirstPacket', False),
                           ('useFrameDuration', True), ('ffIndex', 0), ('decoder', 'aac_fixed'),
                           ('sampleRate', 44100), ('channels', 1), ('samplesPerChannel', 3),
                           ('samplesPerChannel', None), ('samplesPerChannel', True),
                           ('seekTarget', 0), ('firstPacketPTS', 0)):
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                proof.validate_embedded_metadata(dict(base, **{key: value}), data,
                                                 2, 48000, 2, 'seek-first-packet')

    def test_decoder_control_requires_one_observed_selection(self):
        log = '[ad/v] Opening decoder aac\n[ad/v] Selected decoder: aac - AAC (Advanced Audio Coding)\n'
        self.assertEqual(proof.selected_decoder(log), 'aac')
        self.assertEqual(proof.selected_decoder(log, 'aac'), 'aac')
        for text, requested in ((log, 'aac_fixed'), ('', 'auto'), (log + log, 'aac')):
            with self.subTest(text=text, requested=requested), self.assertRaises(ValueError):
                proof.selected_decoder(text, requested)

    def test_range_strategies_keep_exact_requested_endpoints(self):
        self.assertEqual(proof.range_arguments('tail', 128203, 4097, 44100, 'sample-filter'),
                         ['128203', '132300'])
        self.assertEqual(proof.range_arguments('tail', 128203, 4097, 44100, 'pts-filter'),
                         ['128203', '132300'])
        self.assertEqual(proof.range_arguments('cut', 1023, 4097, 48000, 'timestamp'),
                         [format(1023 / 48000, '.17g'), format(5120 / 48000, '.17g')])
        for mode in ('timestamp', 'sample-filter', 'pts-filter'):
            self.assertEqual(proof.range_arguments('natural', 0, 132300, 44100, mode), ['natural', '3'])

    def test_invalid_range_strategy_or_coordinates_rejected(self):
        for start, count, rate, mode in ((-1, 5, 48000, 'timestamp'), (0, 0, 48000, 'sample-filter'),
                                         (0, 5, 0, 'timestamp'), (0, 5, 48000, 'align')):
            with self.subTest(start=start, count=count, rate=rate, mode=mode), self.assertRaises(ValueError):
                proof.range_arguments('cut', start, count, rate, mode)

    def test_exact_samples_pass(self):
        values = audio([0.0, 0.125, -0.25, 0.5])
        result = proof.compare_audio(values, values, 2)
        self.assertTrue(result['passed'])
        self.assertEqual(result['actualSamplesPerChannel'], 2)
        self.assertEqual(result['maximumError'], 0)

    def test_count_mismatch_does_not_fit_offset_or_pad(self):
        for values in ([0.125, 0.25], [0.125, 0.25, 0.5, 0.0]):
            with self.subTest(values=values):
                result = proof.compare_audio(audio(values), audio([0.125, 0.25, 0.5]), 1)
                self.assertFalse(result['passed'])
                self.assertEqual(result['error'], 'Exact sample count differs')

    def test_shift_wrong_stream_and_channel_swap_fail(self):
        expected = audio([0.125, -0.25, 0.5, -0.75])
        for values in ([0.5, -0.75, 0.125, -0.25], [-0.25, 0.125, -0.75, 0.5], [0, 0, 0, 0]):
            with self.subTest(values=values):
                self.assertFalse(proof.compare_audio(audio(values), expected, 2)['passed'])

    def test_peak_limit_and_per_channel_mean_each_apply(self):
        expected = audio([0] * 1000)
        peak = [0] * 1000
        peak[20] = proof.PEAK_LIMIT * 2
        self.assertFalse(proof.compare_audio(audio(peak), expected, 2)['passed'])
        # Only one channel exceeds the mean; averaging channels would conceal it.
        means = [proof.MEAN_LIMIT * 1.5, 0] * 500
        self.assertFalse(proof.compare_audio(audio(means), expected, 2)['passed'])

    def test_malformed_or_nonfinite_audio_is_rejected(self):
        for actual, expected, channels in ((b'', audio([0]), 1), (b'abc', audio([0]), 1),
                                            (audio([0]), b'', 1), (audio([0]), audio([0]), 3),
                                            (audio([float('nan')]), audio([0]), 1),
                                            (audio([0]), audio([float('inf')]), 1),
                                            (audio([0]), audio([0]), 2)):
            with self.subTest(actual=actual, expected=expected, channels=channels), self.assertRaises(ValueError):
                proof.compare_audio(actual, expected, channels)


if __name__ == '__main__':
    unittest.main()
