import importlib.util
from pathlib import Path
import struct
import unittest

spec = importlib.util.spec_from_file_location('audio_proof', Path(__file__).with_name('mpv-audio-proof.py'))
proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proof)


def audio(values):
    return struct.pack('<' + 'f' * len(values), *values)


class AudioComparisonTests(unittest.TestCase):
    def test_range_strategies_keep_exact_requested_endpoints(self):
        self.assertEqual(proof.range_arguments('tail', 128203, 4097, 44100, 'sample-filter'),
                         ['128203', '132300'])
        self.assertEqual(proof.range_arguments('cut', 1023, 4097, 48000, 'timestamp'),
                         [format(1023 / 48000, '.17g'), format(5120 / 48000, '.17g')])
        for mode in ('timestamp', 'sample-filter'):
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
