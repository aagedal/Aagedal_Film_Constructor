import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('native_packager', Path(__file__).with_name('package-native-runtime.py'))
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class NativeDependencyTests(unittest.TestCase):
    def test_transitive_cycle_and_symlink_alias_are_copied_once(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            executable, a, b = (root / name for name in ['app', 'a.dylib', 'b.dylib'])
            for path in [executable, a, b]:
                path.touch()
            alias = root / 'alias.dylib'
            alias.symlink_to(a)
            graph = {executable: [str(alias), str(a)], a: [str(b)], b: [str(a), '/usr/lib/libSystem.B.dylib']}
            with patch.object(packager, 'inspect', side_effect=lambda p: dict(dependencies=graph[p], identifier=None, rpaths=[])):
                nodes = packager.discover(executable, [])
            self.assertEqual(set(nodes), {executable, a, b})
            self.assertEqual(nodes[executable]['resolved'][str(alias)], a)
            self.assertEqual(nodes[b]['resolved'], {str(a): a})

    def test_same_filename_collision_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            executable = root / 'app'
            executable.touch()
            libs = []
            for parent in ['one', 'two']:
                folder = root / parent
                folder.mkdir()
                library = folder / 'same.dylib'
                library.touch()
                libs.append(library)
            graph = {executable: list(map(str, libs)), **{p: [] for p in libs}}
            with patch.object(packager, 'inspect', side_effect=lambda p: dict(dependencies=graph[p], identifier=None, rpaths=[])):
                with self.assertRaisesRegex(ValueError, 'same bundle filename'):
                    packager.discover(executable, [])

    def test_rpath_ambiguity_and_missing_library_are_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            folders = [root / name for name in ['one', 'two']]
            for folder in folders:
                folder.mkdir()
                (folder / 'same.dylib').touch()
            with self.assertRaisesRegex(ValueError, 'ambiguous'):
                packager.resolve_dependency('@rpath/same.dylib', root / 'app', root / 'app', folders, [])
            with self.assertRaisesRegex(ValueError, 'Unresolved'):
                packager.resolve_dependency('@rpath/missing.dylib', root / 'app', root / 'app', folders, [])

    def test_output_staging_cannot_be_inside_an_input_tree(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            app = root / 'source.app'
            app.mkdir()
            for output in [app / 'output.app', app / 'nested/output.app']:
                with self.assertRaisesRegex(ValueError, 'outside input tree'):
                    packager.validate_output_location(output, [app])
            alias = root / 'alias'
            alias.symlink_to(app, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, 'outside input tree'):
                packager.validate_output_location(alias / 'output.app', [app])
            packager.validate_output_location(root / 'new.app', [app])

    def test_universal_or_mismatched_architectures_are_refused(self):
        self.assertEqual(packager.require_thin_architecture(['arm64']), 'arm64')
        with self.assertRaisesRegex(ValueError, 'thin Mach-O'):
            packager.require_thin_architecture(['arm64', 'x86_64'])
        with self.assertRaisesRegex(ValueError, 'does not match'):
            packager.require_thin_architecture(['x86_64'], 'arm64')

    def test_loader_relative_path_and_system_prefix(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            library = root / 'library.dylib'
            library.touch()
            self.assertEqual(packager.resolve_dependency('@loader_path/library.dylib', root / 'owner', root / 'app', [], []), library)
        self.assertTrue(packager.system_dependency('/usr/lib/swift/libswiftCore.dylib'))
        self.assertFalse(packager.system_dependency('/usr/library/custom.dylib'))
        self.assertFalse(packager.system_dependency('/opt/homebrew/lib/library.dylib'))


if __name__ == '__main__':
    unittest.main()
