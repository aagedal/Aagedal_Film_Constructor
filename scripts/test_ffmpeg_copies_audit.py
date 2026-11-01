import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), Path(__file__).with_name(name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


audit = load('ffmpeg-copies-audit')
prepare = load('prepare-media-helpers')
ROOT = Path(__file__).resolve().parent.parent

DECODERS = '''Decoders:
 V..... = Video
 A..... = Audio
 ------
 V....D h264                 H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10
 V....D libdav1d             dav1d AV1 decoder by VideoLAN (codec av1)
 V....D png                  PNG (Portable Network Graphics) image
 V....D mjpeg                MJPEG (Motion JPEG)
 A....D pcm_s16le            PCM signed 16-bit little-endian
'''
FILTERS = '''Filters:
  T.. = Timeline support
  | = Source or sink filter
  ------
 TS aap               AA->A      Apply Affine Projection algorithm to first audio stream.
 .. scale             V->V       Scale the input video size and/or convert the image format.
'''
CONFIGURATION = '--enable-gpl --enable-version3 --enable-static'


def inventory(version='9.0.2', configuration=CONFIGURATION, **kinds):
    base = dict(version=version, configuration=configuration, encoders=[], decoders=[], filters=[], muxers=[],
                decodableCodecs=[], demuxers=None)
    return dict(base, **kinds)


class FFmpegCopiesAuditTests(unittest.TestCase):
    def test_listings_skip_legends_and_map_decoders_to_codecs(self):
        self.assertEqual(audit.listing_names(FILTERS), {'aap', 'scale'})
        self.assertEqual(audit.listing_names(DECODERS), {'h264', 'libdav1d', 'png', 'mjpeg', 'pcm_s16le'})
        self.assertEqual(audit.decodable_codecs(DECODERS), {'h264', 'av1', 'png', 'mjpeg', 'pcm_s16le'})

    def test_versions_and_licences(self):
        self.assertEqual(audit.normalised_version('n9.0.2'), '9.0.2')
        self.assertEqual(audit.normalised_version('9.0.2'), '9.0.2')
        self.assertEqual(audit.normalised_version('N-12345-gabc'), 'N-12345-gabc')
        self.assertEqual(audit.licence(CONFIGURATION), 'GPL version 3 or later')
        self.assertEqual(audit.licence('--enable-gpl'), 'GPL version 2 or later')
        self.assertEqual(audit.licence('--enable-version3'), 'LGPL version 3 or later')
        self.assertEqual(audit.licence('--enable-gpl --enable-nonfree'), 'nonfree')

    def test_comparison_reports_gaps_and_fails_only_on_helper_or_drift(self):
        requirements = {'export': {kind: (set(), set()) for kind in audit.KINDS}}
        requirements['export']['encoders'] = ({'prores_ks'}, {'libx264'})
        helper = inventory(encoders=['prores_ks'], decodableCodecs=['h264'], demuxers=['mov'])
        runtime = inventory('n9.0.2', encoders=['prores'], decodableCodecs=['h264', 'avs3'], demuxers=['mov', 'dash'])
        report = audit.compare(helper, runtime, requirements)
        self.assertTrue(report['versions']['match'])
        self.assertTrue(report['licences']['match'])
        self.assertEqual(report['errors'], [])
        self.assertEqual(report['features']['export']['helperMissing'], {'encoders': ['libx264']})
        self.assertEqual(report['features']['export']['runtimeMissing'], {'encoders': ['libx264', 'prores_ks']})
        self.assertEqual(report['runtimeOnlyDecodableCodecs'], ['avs3'])
        self.assertEqual(report['runtimeOnlyDemuxers'], ['dash'])

        drift = audit.compare(inventory(encoders=[]), inventory('n9.1', configuration='--enable-gpl --enable-nonfree'), requirements)
        self.assertEqual(len(drift['errors']), 4)
        self.assertIsNone(drift['runtimeOnlyDemuxers'])
        self.assertIn('Helper lacks encoders required by export: prores_ks', drift['errors'])

    def test_prepared_helper_listings_are_read_without_running_helpers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'manifest.json').write_text(json.dumps(dict(helpers=dict(ffmpeg=dict(version='9.0.2', configuration=CONFIGURATION)))))
            for kind, text in dict(encoders='', decoders=DECODERS, filters=FILTERS, muxers='').items():
                (root / f'{kind}.txt').write_text(text)
            result = audit.helper_inventory(root)
            self.assertIn('av1', result['decodableCodecs'])
            self.assertEqual(result['filters'], ['aap', 'scale'])
            self.assertIsNone(result['demuxers'])

    def test_tracked_requirements_drive_preparation(self):
        requirements = audit.load_requirements()
        self.assertEqual(prepare.REQUIRED, audit.required(requirements))
        # The helper features the app ships and the previously hard-coded preparation minimum.
        self.assertEqual(set(requirements), {'export', 'proxies', 'conversion', 'stabilise', 'noiseReduction'})
        self.assertTrue({'prores_ks', 'pcm_s24le', 'libx264', 'aac', 'hevc_videotoolbox'} <= prepare.REQUIRED['encoders'])
        self.assertTrue({'color', 'anullsrc', 'trim', 'atrim', 'setpts', 'asetpts', 'fps', 'scale', 'pad', 'crop', 'setsar',
                         'format', 'overlay', 'loop', 'settb', 'aresample', 'pan', 'aformat', 'volume', 'aeval', 'adelay',
                         'amix', 'deshake', 'afftdn'} <= prepare.REQUIRED['filters'])
        self.assertEqual(prepare.REQUIRED['muxers'], {'mov', 'mp4', 'wav', 'f32le'})
        self.assertNotIn('libx264', requirements['proxies']['encoders'][0])

    def test_every_required_component_appears_in_app_sources(self):
        # Catches stale entries; additions to command lines must be added to the requirements by hand.
        # Image decoders (png, mjpeg for JPEG stills) are implied by still formats, not named.
        sources = '\n'.join(path.read_text() for directory in ('Aagedal Film Constructor', 'Packages/EditorCore/Sources')
                            for path in (ROOT / directory).rglob('*.swift'))
        for name in sorted(set().union(*(prepare.REQUIRED[kind] for kind in ('encoders', 'filters', 'muxers')))):
            with self.subTest(component=name):
                self.assertTrue(name in sources, f'{name} is required but no longer used')

    @unittest.skipUnless((ROOT / 'Packages/NativePlaybackProof/.build/debug/libNativePlaybackRuntime.dylib').is_file(),
                         'Optional: build Packages/NativePlaybackProof first')
    def test_runtime_inventory_of_built_runtime(self):
        runtime = audit.runtime_inventory(ROOT / 'Packages/NativePlaybackProof/.build/debug/libNativePlaybackRuntime.dylib')
        self.assertEqual(audit.normalised_version(runtime['version']), '9.0.2')
        self.assertEqual(audit.licence(runtime['configuration']), 'GPL version 3 or later')
        self.assertIn('prores', runtime['decodableCodecs'])
        self.assertNotIn('prores_ks', runtime['encoders'])


if __name__ == '__main__':
    unittest.main()
