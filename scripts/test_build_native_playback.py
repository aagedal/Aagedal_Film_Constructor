import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), Path(__file__).with_name(name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


build = load('build-native-playback')
configure = load('configure-native-playback')


class NativeXcodeDevelopmentTests(unittest.TestCase):
    def fixture(self, root):
        return dict(AFC_NATIVE_PLAYBACK='YES', CONFIGURATION='Debug', ACTION='build', ARCHS='arm64',
            MACOSX_DEPLOYMENT_TARGET='27.0', SRCROOT=str(root), DERIVED_FILE_DIR=str(root / 'derived'),
            SDKROOT=str(root))

    def package(self, root, pins):
        package = root / build.PACKAGE
        package.mkdir(parents=True)
        (package / 'Package.resolved').write_text(json.dumps(dict(pins=pins, version=3)))
        return package

    def test_default_is_unselected_and_unsupported_selection_fails(self):
        self.assertIsNone(build.selection({}))
        with self.assertRaises(ValueError):
            build.selection({'AFC_NATIVE_PLAYBACK': 'maybe'})

    def test_release_archive_universal_wrong_deployment_and_relative_paths_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.fixture(Path(directory))
            self.assertEqual(build.selection(env)['SRCROOT'], Path(directory))
            for field, value in [('CONFIGURATION', 'Release'), ('ACTION', 'install'),
                ('ARCHS', 'arm64 x86_64'), ('MACOSX_DEPLOYMENT_TARGET', '14.0'),
                ('SRCROOT', 'relative'), ('DERIVED_FILE_DIR', '')]:
                with self.subTest(field=field), self.assertRaises(ValueError):
                    build.selection(dict(env, **{field: value}))

    def test_enable_writes_runtime_link_settings_without_machine_paths(self):
        self.assertIn('AFC_NATIVE_PLAYBACK = YES', configure.SETTINGS)
        self.assertIn('-lNativePlaybackRuntime', configure.SETTINGS)
        self.assertIn('SWIFT_INCLUDE_PATHS = $(inherited) "$(DERIVED_FILE_DIR)/native-playback/products" "$(DERIVED_FILE_DIR)/native-playback/products/Modules"', configure.SETTINGS)
        self.assertNotIn('PKG_CONFIG', configure.SETTINGS)

    def test_mpvkit_pin_requires_exactly_one_revision(self):
        with tempfile.TemporaryDirectory() as directory:
            pin = dict(identity='mpvkit', location='https://github.com/aagedal/MPVKit', state=dict(revision='abc'))
            package = self.package(Path(directory), [pin])
            self.assertEqual(build.mpvkit_pin(package), dict(location=pin['location'], revision='abc'))
            for pins in ([], [dict(pin, state={})], [pin, pin]):
                (package / 'Package.resolved').write_text(json.dumps(dict(pins=pins)))
                with self.subTest(pins=pins), self.assertRaises(ValueError):
                    build.mpvkit_pin(package)

    def test_build_uses_target_sdk_and_records_mpvkit_attribution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = self.fixture(root)
            paths = build.selection(env)
            self.package(root, [dict(identity='mpvkit', location='https://github.com/aagedal/MPVKit',
                                     state=dict(revision='f957f48'))])
            checkout = paths['DERIVED_FILE_DIR'] / 'native-playback/build/checkouts/MPVKit'
            checkout.mkdir(parents=True)
            (checkout / 'LICENSE').write_text('GNU GENERAL PUBLIC LICENSE')
            products = root / 'actual-products'
            products.mkdir()
            (products / 'libNativePlaybackRuntime.dylib').write_bytes(b'development test')
            def capture(command, **kwargs):
                if command[:2] == ['/usr/bin/xcrun', '--find']:
                    return '/usr/bin/swift\n'
                if '--version' in command:
                    return 'Swift development toolchain\n'
                return str(products) + '\n'
            with patch.object(build.subprocess, 'check_output', side_effect=capture), patch.object(build.subprocess, 'run') as run:
                build.compile_runtime(paths, env)
            command = run.call_args.args[0]
            self.assertIn('arm64-apple-macosx27.0', command)
            self.assertIn('--sdk', command)
            self.assertFalse(any(flag in command for flag in ('-Xcc', '-Xlinker')))
            native = paths['DERIVED_FILE_DIR'] / 'native-playback'
            self.assertEqual((native / 'products').resolve(), products.resolve())
            self.assertTrue((native / 'CNativeDecoder.modulemap').is_file())
            self.assertIn('releaseCertified', (native / 'build-selection.json').read_text())
            self.assertEqual((native / 'notices/MPVKit-LICENSE').read_text(), 'GNU GENERAL PUBLIC LICENSE')
            self.assertIn('f957f48', (native / 'notices/README').read_text())
            self.assertEqual(json.loads((native / 'provenance.json').read_text())['mpvkit']['revision'], 'f957f48')

    def test_embedding_audits_both_ffmpeg_copies(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = dict(self.fixture(root), TARGET_BUILD_DIR=str(root / 'app'), UNLOCALIZED_RESOURCES_FOLDER_PATH='Resources')
            paths = build.selection(env)
            resources = root / 'app/Resources/NativeRuntime'
            resources.mkdir(parents=True)
            with patch.object(build.subprocess, 'run') as run:
                build.audit_ffmpeg_copies(paths, env, resources)
            run.assert_not_called()
            self.assertIsNone(json.loads((resources / 'ffmpeg-copies.json').read_text())['helpers'])
            helpers = root / 'app/Resources/Helpers'
            helpers.mkdir()
            (helpers / 'manifest.json').write_text('{}')
            with patch.object(build.subprocess, 'run') as run:
                build.audit_ffmpeg_copies(paths, env, resources)
            command = run.call_args.args[0]
            self.assertTrue(run.call_args.kwargs['check'])
            self.assertIn('--check', command)
            self.assertEqual(command[command.index('--helpers') + 1], str(helpers))
            self.assertTrue(command[command.index('--runtime') + 1].endswith('native-playback/products/libNativePlaybackRuntime.dylib'))
            self.assertNotIn('--helper-demuxers', command)

    def test_disabled_cleanup_preserves_unrelated_frameworks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            resources = root / 'Resources/NativeRuntime'
            resources.mkdir(parents=True)
            (resources / 'manifest.json').write_text('{}')
            frameworks = root / 'Frameworks'
            frameworks.mkdir()
            (frameworks / 'Unrelated.dylib').write_bytes(b'unrelated')
            with self.assertRaises(ValueError):
                build.clean_disabled_outputs(dict(TARGET_BUILD_DIR=str(root), FRAMEWORKS_FOLDER_PATH='Frameworks', UNLOCALIZED_RESOURCES_FOLDER_PATH='Resources'))
            self.assertTrue((frameworks / 'Unrelated.dylib').exists())


if __name__ == '__main__':
    unittest.main()
