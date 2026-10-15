import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('mpv_coexistence', Path(__file__).with_name('mpv-coexistence-proof.py'))
proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proof)


class CoexistenceValidationTests(unittest.TestCase):
    def setUp(self):
        self.image = Path('/private/tmp/private-mpv.dylib')
        self.versions = dict(zip(proof.LIBRARIES, [0x3f0166, 0x3f0166, 0x3d0166, 0x70166, 0xa0166]))
        self.report = dict(passed=True, nativeIterations=120, nativeCompletionsDuringMPV=100, hiddenAPIs=True,
                           native=[dict(library=name, version=version, image=f'/deps/lib{name}.1.dylib')
                                   for name, version in self.versions.items()],
                           mpv=[dict(library=name, version=version - 0x10000, image=str(self.image))
                                for name, version in self.versions.items()])

    def test_distinct_private_and_dynamic_bindings_pass(self):
        proof.validate_bindings(self.report, self.image, self.versions)
        del self.report['mpv']
        proof.validate_bindings(self.report, self.image, self.versions)

    def test_mpv_binding_to_native_image_is_rejected_even_with_expected_version(self):
        self.report['mpv'][0]['image'] = self.report['native'][0]['image']
        with self.assertRaisesRegex(ValueError, 'escaped'):
            proof.validate_bindings(self.report, self.image, self.versions)

    def test_native_binding_to_private_copy_is_rejected(self):
        self.report['native'][1]['image'] = str(self.image)
        with self.assertRaisesRegex(ValueError, 'unexpected image'):
            proof.validate_bindings(self.report, self.image, self.versions)

    def test_same_image_basename_at_another_path_cannot_pass(self):
        self.report['mpv'][1]['image'] = '/another/private-mpv.dylib'
        with self.assertRaisesRegex(ValueError, 'escaped'):
            proof.validate_bindings(self.report, self.image, self.versions)

    def test_wrong_native_version_or_identical_closures_are_rejected(self):
        bad = copy.deepcopy(self.report)
        bad['native'][0]['version'] -= 1
        with self.assertRaisesRegex(ValueError, 'version differs'):
            proof.validate_bindings(bad, self.image, self.versions)
        for entry in self.report['mpv']:
            entry['version'] = self.versions[entry['library']]
        with self.assertRaisesRegex(ValueError, 'distinct'):
            proof.validate_bindings(self.report, self.image, self.versions)

    def test_incomplete_or_failed_host_cannot_pass(self):
        for key, value in [('passed', False), ('nativeIterations', 119), ('hiddenAPIs', False),
                           ('nativeCompletionsDuringMPV', 0), ('nativeCompletionsDuringMPV', 121),
                           ('mpv', self.report['mpv'][:-1]), ('native', self.report['native'][:-1])]:
            bad = dict(self.report, **{key: value})
            with self.subTest(key=key), self.assertRaises(ValueError):
                proof.validate_bindings(bad, self.image, self.versions)

    def test_pkg_config_version_must_fit_ffmpeg_encoding(self):
        self.assertEqual(proof.version_integer('63.1.102\n'), 0x3f0166)
        for value in ('63.1', '63.1.102.0', '63.-1.2', '256.1.2', 'x.1.2'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                proof.version_integer(value)


if __name__ == '__main__':
    unittest.main()
