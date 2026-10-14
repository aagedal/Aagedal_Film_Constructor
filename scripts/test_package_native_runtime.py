import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('native_packager', Path(__file__).with_name('package-native-runtime.py'))
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


def build_command(version, platform='1'):
    return f'Load command 3\n      cmd LC_BUILD_VERSION\n  cmdsize 32\n platform {platform}\n    minos {version}\n      sdk 27.0\n'


class DeploymentCompatibilityTests(unittest.TestCase):
    def test_modern_numeric_and_named_platforms_and_legacy_metadata(self):
        for platform in ['1', 'MACOS', 'macos']:
            self.assertEqual(packager.deployment_versions(build_command('14.2.1', platform), 'app'), ['14.2.1'])
        legacy = 'Load command 4\n cmd LC_VERSION_MIN_MACOSX\n cmdsize 16\n version 10.15\n sdk 11.0\n'
        self.assertEqual(packager.deployment_versions(legacy, 'library'), ['10.15'])
        versions = packager.deployment_versions(build_command('14.0') + legacy, 'library')
        self.assertEqual(max(versions, key=packager.version_key), '14.0')
        self.assertEqual(packager.version_key('14'), packager.version_key('14.0.0'))

    def test_missing_malformed_and_non_macos_deployment_metadata_are_refused(self):
        for output in ['', 'Load command 0\n cmd LC_SEGMENT_64\n',
                       build_command('14.0', '2'), build_command('14.0', 'MACCATALYST'),
                       build_command('14.0').replace(' platform 1\n', ''),
                       build_command('14.0').replace('    minos 14.0\n', ''),
                       build_command('14.bad'),
                       'Load command 1\n cmd LC_VERSION_MIN_IPHONEOS\n version 14.0\n']:
            with self.subTest(output=output), self.assertRaises(ValueError):
                packager.deployment_versions(output, 'library')

    def test_bundle_preserves_stricter_app_and_architecture_requirements(self):
        info = {'LSMinimumSystemVersion': '14.0', 'LSMinimumSystemVersionByArchitecture': {'arm64': '15.1'}}
        self.assertEqual(packager.bundle_minimum_os(info, 'arm64', '15.0', '15.1'), '15.1')
        self.assertEqual(info['LSMinimumSystemVersion'], '15.1')
        self.assertEqual(info['LSMinimumSystemVersionByArchitecture']['arm64'], '15.1')
        with self.assertRaisesRegex(ValueError, 'exceeding deployment target'):
            packager.bundle_minimum_os(info, 'arm64', '15.0', '15.0')
        with self.assertRaisesRegex(ValueError, 'Invalid macOS deployment version'):
            packager.bundle_minimum_os({'LSMinimumSystemVersion': 'unknown'}, 'arm64', '14.0')

    def package_fixture(self, root):
        app = root / 'source.app'
        (app / 'Contents/MacOS').mkdir(parents=True)
        executable = app / 'Contents/MacOS/app'
        executable.write_bytes(b'executable')
        executable.chmod(0o755)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleExecutable': 'app', 'LSMinimumSystemVersion': '14.0',
            'LSMinimumSystemVersionByArchitecture': {'arm64': '14.0'}}))
        libraries = root / 'libraries'
        libraries.mkdir()
        runtime = libraries / 'libNativePlaybackRuntime.dylib'
        runtime.write_bytes(b'runtime')
        notices = root / 'notices'
        notices.mkdir()
        (notices / 'NOTICE').write_text('Development fixture')
        provenance = root / 'provenance.txt'
        provenance.write_text('Development fixture')
        args = SimpleNamespace(app=app, output=root / 'output/package.app', notices=notices,
            provenance=provenance, library_dir=[libraries], deployment_target=None)
        nodes = {path: dict(dependencies=[], identifier=None, rpaths=[], resolved={}) for path in [executable, runtime]}
        def capture(*command):
            if command[0] == '/usr/bin/lipo':
                return 'arm64\n'
            return build_command('14.0' if Path(command[-1]) == executable else '27.0')
        return args, nodes, capture

    def test_incompatible_closure_is_refused_before_any_staging(self):
        with tempfile.TemporaryDirectory() as directory:
            args, nodes, capture = self.package_fixture(Path(directory).resolve())
            args.deployment_target = '14.0'
            with patch.object(packager, 'discover', return_value=nodes), \
                 patch.object(packager, 'capture', side_effect=capture), \
                 patch.object(packager.tempfile, 'mkdtemp') as stage, \
                 patch.object(packager.subprocess, 'run') as mutate:
                with self.assertRaisesRegex(ValueError, 'requires macOS 27.0'):
                    packager.package(args)
                stage.assert_not_called()
                mutate.assert_not_called()
            self.assertFalse(args.output.parent.exists())

    def test_packaged_plist_and_manifest_match_actual_closure_floor(self):
        with tempfile.TemporaryDirectory() as directory:
            args, nodes, capture = self.package_fixture(Path(directory).resolve())
            args.deployment_target = '27.0'
            with patch.object(packager, 'discover', return_value=nodes), \
                 patch.object(packager, 'capture', side_effect=capture), \
                 patch.object(packager, 'inspect', return_value=dict(dependencies=[], identifier=None, rpaths=[])), \
                 patch.object(packager.subprocess, 'run'):
                packager.package(args)
            info = plistlib.loads((args.output / 'Contents/Info.plist').read_bytes())
            self.assertEqual(info['LSMinimumSystemVersion'], '27.0')
            self.assertEqual(info['LSMinimumSystemVersionByArchitecture']['arm64'], '27.0')
            source_info = plistlib.loads((args.app / 'Contents/Info.plist').read_bytes())
            self.assertEqual(source_info['LSMinimumSystemVersion'], '14.0')
            manifest = json.loads((args.output / 'Contents/Resources/NativeRuntime/manifest.json').read_text())
            self.assertEqual(manifest['minimumOS'], '27.0')
            self.assertEqual(manifest['binaryMinimumOS'], '27.0')
            self.assertEqual(manifest['deploymentTarget'], '27.0')
            self.assertFalse(manifest['releaseCertified'])


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


class XcodeEmbeddingTests(unittest.TestCase):
    def test_output_ancestor_cannot_delete_selected_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            output = root / 'NativeRuntime'
            for tree in [output / 'notices', root]:
                with self.assertRaisesRegex(ValueError, 'overlap'):
                    packager.validate_embedding_inputs([output], [tree], [])
            for source in [output / 'provenance.txt', output / 'libraries/native.dylib']:
                with self.assertRaisesRegex(ValueError, 'input file'):
                    packager.validate_embedding_inputs([output], [], [source])
            alias = root / 'alias'
            output.mkdir()
            alias.symlink_to(output, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, 'input file'):
                packager.validate_embedding_inputs([output], [], [alias / 'provenance.txt'])
            packager.validate_embedding_inputs([output], [root / 'notices'], [root / 'runtime.dylib'])

    def embed_fixture(self, directory):
        args, nodes, capture = DeploymentCompatibilityTests().package_fixture(Path(directory).resolve())
        runtime = next(p for p in nodes if p.name == 'libNativePlaybackRuntime.dylib')
        args.runtime_only = runtime
        args.frameworks = Path(directory).resolve() / 'built.app/Contents/Frameworks'
        args.resources = Path(directory).resolve() / 'built.app/Contents/Resources/NativeRuntime'
        args.sign_identity = '-'
        args.deployment_target = '27.0'
        return args, {runtime: nodes[runtime]}, capture

    def test_embedding_rebuild_and_input_preservation(self):
        with tempfile.TemporaryDirectory() as directory:
            args, nodes, capture = self.embed_fixture(directory)
            original = args.runtime_only.read_bytes()
            with patch.object(packager, 'discover', return_value=nodes), \
                 patch.object(packager, 'capture', side_effect=capture), \
                 patch.object(packager, 'inspect', return_value=dict(dependencies=[], identifier=None, rpaths=['@loader_path'])), \
                 patch.object(packager.subprocess, 'run') as commands:
                packager.embed_runtime(args)
                packager.embed_runtime(args)
            self.assertEqual(args.runtime_only.read_bytes(), original)
            self.assertEqual([p.name for p in args.frameworks.iterdir()], ['libNativePlaybackRuntime.dylib'])
            manifest = json.loads((args.resources / 'manifest.json').read_text())
            self.assertEqual(manifest['embeddingMode'], 'xcode-development')
            self.assertEqual(manifest['minimumOS'], '27.0')
            self.assertFalse(manifest['releaseCertified'])
            self.assertEqual(manifest['files']['libNativePlaybackRuntime.dylib'], packager.digest(args.frameworks / 'libNativePlaybackRuntime.dylib'))
            self.assertTrue(any(call.args[0][:3] == ['/usr/bin/codesign', '--verify', '--strict'] for call in commands.call_args_list))

    def test_incompatible_closure_refuses_before_output_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            args, nodes, capture = self.embed_fixture(directory)
            args.deployment_target = '26.0'
            with patch.object(packager, 'discover', return_value=nodes), \
                 patch.object(packager, 'capture', side_effect=capture), \
                 patch.object(packager.tempfile, 'mkdtemp') as stage:
                with self.assertRaisesRegex(ValueError, 'requires macOS 27.0'):
                    packager.embed_runtime(args)
                stage.assert_not_called()
            self.assertFalse(args.frameworks.parent.exists())

    def test_embedding_failure_preserves_previous_output(self):
        with tempfile.TemporaryDirectory() as directory:
            args, nodes, capture = self.embed_fixture(directory)
            with patch.object(packager, 'discover', return_value=nodes), \
                 patch.object(packager, 'capture', side_effect=capture), \
                 patch.object(packager, 'inspect', return_value=dict(dependencies=[], identifier=None, rpaths=[])), \
                 patch.object(packager.subprocess, 'run'):
                packager.embed_runtime(args)
            previous = (args.resources / 'manifest.json').read_bytes()
            with patch.object(packager, 'discover', return_value=nodes), \
                 patch.object(packager, 'capture', side_effect=capture), \
                 patch.object(packager.subprocess, 'run', side_effect=RuntimeError('signing failed')):
                with self.assertRaisesRegex(RuntimeError, 'signing failed'):
                    packager.embed_runtime(args)
            self.assertEqual((args.resources / 'manifest.json').read_bytes(), previous)
            self.assertEqual((args.frameworks / args.runtime_only.name).read_bytes(), args.runtime_only.read_bytes())

    def test_unowned_or_linked_outputs_are_never_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            frameworks, resources = root / 'Frameworks', root / 'NativeRuntime'
            frameworks.mkdir()
            (frameworks / 'Unrelated.framework').mkdir()
            with self.assertRaisesRegex(ValueError, 'not an owned'):
                packager.validate_embedded_outputs(frameworks, resources)
            resources.mkdir()
            (resources / 'manifest.json').write_text(json.dumps(dict(schemaVersion=1,
                embeddingMode='xcode-development', files={'native.dylib': 'hash'})))
            with self.assertRaisesRegex(ValueError, 'unrelated'):
                packager.validate_embedded_outputs(frameworks, resources)
            (frameworks / 'Unrelated.framework').rmdir()
            (frameworks / 'native.dylib').symlink_to('/tmp/unrelated')
            with self.assertRaisesRegex(ValueError, 'links'):
                packager.validate_embedded_outputs(frameworks, resources)


if __name__ == '__main__':
    unittest.main()
