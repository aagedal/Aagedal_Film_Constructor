import importlib.util
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
        tool = root / 'pkg-config'
        tool.write_text('#!/bin/sh\nexit 0\n')
        tool.chmod(0o755)
        notices = root / 'notices'
        notices.mkdir()
        (notices / 'NOTICE').write_text('Development notices')
        provenance = root / 'provenance.txt'
        provenance.write_text('Development provenance')
        return dict(AFC_NATIVE_PLAYBACK='YES', CONFIGURATION='Debug', ACTION='build', ARCHS='arm64',
            MACOSX_DEPLOYMENT_TARGET='27.0', SRCROOT=str(root), DERIVED_FILE_DIR=str(root / 'derived'),
            SDKROOT=str(root), AFC_NATIVE_PKG_CONFIG=str(tool), AFC_NATIVE_NOTICES=str(notices),
            AFC_NATIVE_PROVENANCE=str(provenance))

    def test_default_is_unselected_and_unsupported_selection_fails(self):
        self.assertIsNone(build.selection({}))
        with self.assertRaises(ValueError):
            build.selection({'AFC_NATIVE_PLAYBACK': 'maybe'})

    def test_release_archive_universal_wrong_deployment_and_missing_attribution_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.fixture(Path(directory))
            self.assertEqual(build.selection(env)['SRCROOT'], Path(directory))
            for field, value in [('CONFIGURATION', 'Release'), ('ACTION', 'install'),
                ('ARCHS', 'arm64 x86_64'), ('MACOSX_DEPLOYMENT_TARGET', '14.0'),
                ('AFC_NATIVE_PKG_CONFIG', 'relative'), ('AFC_NATIVE_NOTICES', '/missing'),
                ('AFC_NATIVE_PROVENANCE', '/missing')]:
                with self.subTest(field=field), self.assertRaises(ValueError):
                    build.selection(dict(env, **{field: value}))

    def test_selection_is_explicit_local_and_preserves_spaces(self):
        with tempfile.TemporaryDirectory(prefix='native selection ') as directory:
            env = self.fixture(Path(directory))
            with patch.object(configure.subprocess, 'run') as run:
                settings = configure.selected_settings(*[Path(env[key]) for key in (
                    'AFC_NATIVE_PKG_CONFIG', 'AFC_NATIVE_NOTICES', 'AFC_NATIVE_PROVENANCE')])
            self.assertIn('AFC_NATIVE_PLAYBACK = YES', settings)
            self.assertIn('AFC_NATIVE_PKG_CONFIG = ' + env['AFC_NATIVE_PKG_CONFIG'], settings)
            self.assertIn('-lNativePlaybackRuntime', settings)
            self.assertIn('SWIFT_INCLUDE_PATHS = $(inherited) "$(DERIVED_FILE_DIR)/native-playback/products" "$(DERIVED_FILE_DIR)/native-playback/products/Modules"', settings)
            run.assert_called_once_with([env['AFC_NATIVE_PKG_CONFIG'], '--exists', *configure.LIBRARIES], check=True)

    def test_unrepresentable_xcconfig_values_are_rejected(self):
        for value in ('/tmp/a\nb', '/tmp/a//b', '/tmp/a"b', '/tmp/$(HOME)', '/tmp/a\\b'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                configure.xcconfig_value(value)

    def test_build_uses_selected_tool_target_sdk_and_records_exact_flags(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.fixture(Path(directory))
            paths = build.selection(env)
            products = Path(directory) / 'actual-products'
            products.mkdir()
            (products / 'libNativePlaybackRuntime.dylib').write_bytes(b'development test')
            def capture(command, **kwargs):
                if '--cflags' in command:
                    return '-I/explicit/include\n'
                if '--libs' in command:
                    return '-L/explicit/lib -lavformat\n'
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
            self.assertIn('-I/explicit/include', command)
            self.assertIn('-lavformat', command)
            root = paths['DERIVED_FILE_DIR'] / 'native-playback'
            self.assertEqual((root / 'products').resolve(), products.resolve())
            self.assertTrue((root / 'CNativeDecoder.modulemap').is_file())
            self.assertIn('releaseCertified', (root / 'build-selection.json').read_text())

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
