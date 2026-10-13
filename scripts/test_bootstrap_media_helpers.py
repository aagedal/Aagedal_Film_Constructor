import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location('bootstrap', Path(__file__).with_name('bootstrap-media-helpers.py'))
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)


class BootstrapTests(unittest.TestCase):
    def test_archive_integrity_precedes_extraction_and_signature_checks(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            archive = root / 'helpers.zip'
            archive.write_bytes(b'corrupt archive')
            with patch.object(bootstrap.subprocess, 'run') as signing:
                with self.assertRaisesRegex(ValueError, 'archive SHA256'):
                    bootstrap.extract_verified(archive, root, {'sha256': 'incorrect'})
                signing.assert_not_called()
            self.assertFalse((root / 'ffmpeg').exists())

    def test_only_known_members_extracted_and_binary_hashes_checked(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            archive = root / 'helpers.zip'
            with zipfile.ZipFile(archive, 'w') as package:
                for name in ('ffmpeg', 'ffprobe', 'README.md', 'qualification.json', 'notarization.json'):
                    package.writestr('full/' + name, name.encode())
                package.writestr('../escaped', 'untrusted')
            pin = {'sha256': bootstrap.digest(archive), 'binaries': {
                name: hashlib.sha256(name.encode()).hexdigest() for name in ('ffmpeg', 'ffprobe')}}
            output = root / 'output'
            output.mkdir()
            with patch.object(bootstrap.subprocess, 'run') as signing:
                bootstrap.extract_verified(archive, output, pin)
                self.assertEqual(signing.call_count, 2)
            self.assertFalse((root.parent / 'escaped').exists())
            self.assertEqual(len(list(output.iterdir())), 5)
            pin['binaries']['ffmpeg'] = 'incorrect'
            with self.assertRaisesRegex(ValueError, 'ffmpeg SHA256'):
                bootstrap.extract_verified(archive, output, pin)

    def test_cache_validates_bytes_and_reuses_without_network(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            pin = {'sha256': 'archive', 'binaries': {}}
            prepared = root / 'archive'
            prepared.mkdir()
            files = {}
            for name in ('ffmpeg', 'ffprobe', 'provenance.txt'):
                (prepared / name).write_text(name)
                files[name] = bootstrap.digest(prepared / name)
            pin['binaries'] = {name: files[name] for name in ('ffmpeg', 'ffprobe')}
            manifest = {'schemaVersion': 1, 'files': files, 'helpers': {
                name: {'inputSHA256': files[name]} for name in ('ffmpeg', 'ffprobe')}}
            (prepared / 'manifest.json').write_text(json.dumps(manifest))
            with patch.object(bootstrap.urllib.request, 'urlopen', side_effect=AssertionError('Network used')):
                self.assertEqual(bootstrap.bootstrap(root, pin), prepared)
            (prepared / 'manifest.json').write_text(json.dumps({'schemaVersion': 1, 'files': []}))
            self.assertFalse(bootstrap.validate_prepared(prepared, pin))
            (prepared / 'manifest.json').write_text(json.dumps(manifest))
            (prepared / 'ffmpeg').write_text('tampered')
            self.assertFalse(bootstrap.validate_prepared(prepared, pin))
            (prepared / 'ffmpeg').write_text('ffmpeg')
            (prepared / 'extra').write_text('unexpected')
            self.assertFalse(bootstrap.validate_prepared(prepared, pin))
            (prepared / 'extra').unlink()
            (prepared / 'ffprobe').unlink()
            (prepared / 'ffprobe').symlink_to(prepared / 'ffmpeg')
            self.assertFalse(bootstrap.validate_prepared(prepared, pin))


if __name__ == '__main__':
    unittest.main()
