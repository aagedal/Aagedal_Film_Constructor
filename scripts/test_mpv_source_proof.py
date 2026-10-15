import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('mpv_source_proof', Path(__file__).with_name('mpv-source-proof.py'))
proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proof)


class SourceProofTests(unittest.TestCase):
    def test_pixel_comparison_rejects_wrong_frame(self):
        self.assertFalse(proof.compare_rgb(bytes([0, 10, 20]), bytes([255, 255, 255]))['passed'])
        self.assertTrue(proof.compare_rgb(bytes([0, 10, 20]), bytes([1, 11, 21]))['passed'])
        # A localized large corruption must not hide inside the mean budget.
        self.assertFalse(proof.compare_rgb(bytes(999), bytes([100]) + bytes(998))['passed'])

    def test_color_diagnostics_locate_peak_without_changing_verdict(self):
        actual = bytes([10, 20, 30, 40, 50, 60, 70, 80, 255, 100, 110, 120])
        expected = bytes([10, 20, 30, 40, 50, 60, 70, 80, 0, 100, 110, 120])
        comparison = proof.compare_rgb(actual, expected, width=2)
        self.assertFalse(comparison['passed'])
        self.assertEqual(comparison['componentsOverMaximumTolerance'], 1)
        self.assertEqual(comparison['channelMeanErrors'], {'red': 0, 'green': 0, 'blue': 63.75})
        self.assertEqual(comparison['peakError'], {'pixelIndex': 2, 'channel': 'blue',
            'actualRGB': [70, 80, 255], 'referenceRGB': [70, 80, 0], 'x': 0, 'y': 1})

    def test_partial_pixels_and_rows_are_rejected(self):
        for actual, width in ((b'ab', None), (bytes(9), 2), (bytes(6), 0)):
            with self.assertRaises(ValueError):
                proof.compare_rgb(actual, actual, width=width)

    def test_empty_or_incomplete_capture_is_rejected(self):
        for actual, expected in ((b'', b''), (b'abc', b'ab')):
            with self.assertRaises(ValueError):
                proof.compare_rgb(actual, expected)

    def artifact(self, root, libraries):
        bundle = root / 'Libmpv.xcframework'
        bundle.mkdir()
        (bundle / 'Info.plist').write_bytes(plistlib.dumps({'AvailableLibraries': libraries}))
        return bundle

    def entry(self, **changes):
        return dict({'LibraryIdentifier': 'macos-universal', 'LibraryPath': 'Libmpv.framework',
                     'SupportedPlatform': 'macos', 'SupportedArchitectures': ['arm64', 'x86_64']}, **changes)

    def test_selects_native_slice_over_simulator_and_uses_real_framework_name(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bundle = self.artifact(root, [self.entry(SupportedPlatform='ios', SupportedPlatformVariant='simulator'), self.entry()])
            framework = bundle / 'macos-universal' / 'Libmpv.framework'
            framework.mkdir(parents=True)
            (framework / 'Libmpv').write_bytes(b'archive')
            self.assertEqual(proof.framework_slice(root, 'arm64'), (framework, framework / 'Libmpv'))

    def test_ambiguous_wrong_architecture_or_catalyst_slice_is_rejected(self):
        for entries in ([self.entry(), self.entry()], [self.entry(SupportedArchitectures=['x86_64'])],
                        [self.entry(SupportedPlatformVariant='maccatalyst')]):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.artifact(root, entries)
                with self.assertRaises(ValueError):
                    proof.framework_slice(root, 'arm64')

    def test_slice_path_cannot_escape_artifact(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.artifact(root, [self.entry(LibraryIdentifier='../../outside')])
            with self.assertRaisesRegex(ValueError, 'Invalid framework path'):
                proof.framework_slice(root, 'arm64')

    def test_static_archive_slice_is_supported(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bundle = self.artifact(root, [self.entry(LibraryPath='libMoltenVK.a')])
            binary = bundle / 'macos-universal' / 'libMoltenVK.a'
            binary.parent.mkdir()
            binary.write_bytes(b'archive')
            self.assertEqual(proof.framework_slice(root, 'arm64'), (binary, binary))


if __name__ == '__main__':
    unittest.main()
