import struct
import unittest

from native_parity import compare_float_audio, compare_rgb


class NativeParityTests(unittest.TestCase):
    def test_binary_frame_mismatch_is_detected(self):
        # The fixture barcode's one-bit difference must exceed tolerance.
        actual = bytes([32] * 100)
        wrong = bytes([224] * 10 + [32] * 90)
        with self.assertRaises(ValueError):
            compare_rgb(actual, wrong, 100)

    def test_truncated_captures_cannot_pass(self):
        for actual, expected in ((b'', b''), (b'123', b'1234'), (b'123', b'123')):
            with self.assertRaises(ValueError):
                compare_rgb(actual, expected, 4)
        with self.assertRaises(ValueError):
            compare_float_audio(struct.pack('<f', 0), struct.pack('<h', 0), 2)

    def test_nan_and_sample_shift_cannot_pass(self):
        reference = struct.pack('<hhhh', 0, 2048, -2048, 1024)
        for values in ((float('nan'), .0625, -.0625, .03125), (.03125, 0, .0625, -.0625)):
            with self.assertRaises(ValueError):
                compare_float_audio(struct.pack('<ffff', *values), reference, 2)

    def test_half_unit_quantization_passes(self):
        result = compare_float_audio(struct.pack('<ff', .5 / 32768, -.5 / 32768),
                                     struct.pack('<hh', 0, 0), 2)
        self.assertEqual(result['samplesPerChannel'], 1)
        self.assertEqual(result['maxErrorInS16Units'], .5)


if __name__ == '__main__':
    unittest.main()
