"""Input and isolation regressions for the cuts-only development proof."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('stream_copy_concat_proof',
                                              Path(__file__).with_name('stream-copy-concat-proof.py'))
concat = importlib.util.module_from_spec(spec)
spec.loader.exec_module(concat)


class ManifestTests(unittest.TestCase):
    def read(self, value):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'ranges.json'
            path.write_text(json.dumps(value))
            return concat.read_ranges(path)

    def test_exact_rationals_and_literal_paths(self):
        entry = {'source': '/private/tmp/a \' special.mov', 'start': '8008/375', 'end': '16016/375'}
        ranges = self.read([entry, entry])
        self.assertEqual(str(ranges[0][1]), '8008/375')
        self.assertEqual(str(ranges[0][0]), entry['source'])

    def test_invalid_shape_and_ranges(self):
        entry = {'source': '/private/tmp/a.mov', 'start': '0', 'end': '1'}
        for manifest in ({}, [], [entry], [entry] * 5,
                         [dict(entry, source='relative.mov'), entry],
                         [dict(entry, start=0), entry], [dict(entry, end='0'), entry],
                         [dict(entry, start='-1'), entry], [dict(entry, extra='value'), entry]):
            with self.subTest(manifest=manifest):
                with self.assertRaises(concat.proof.Ineligible):
                    self.read(manifest)

    def test_bounded_read(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'ranges.json'
            path.write_bytes(b' ' * 65537)
            with self.assertRaisesRegex(concat.proof.Ineligible, '64 KiB'):
                concat.read_ranges(path)

    def test_existing_scratch_content_preserved_without_running_helpers(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            root.chmod(0o700)
            output = root / 'copy.mov'
            output.write_bytes(b'keep')
            ranges = [(root / 'source.mov', 0, 1)] * 2
            with self.assertRaisesRegex(concat.proof.Ineligible, 'empty'):
                concat.proof.verify_concat(None, ranges, root)
            self.assertEqual(output.read_bytes(), b'keep')


if __name__ == '__main__':
    unittest.main()
