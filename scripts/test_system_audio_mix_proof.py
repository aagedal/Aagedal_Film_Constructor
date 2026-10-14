import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location('audio_proof', Path(__file__).with_name('system-audio-mix-proof.py'))
proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proof)


class AudioMatrixIntegrityTests(unittest.TestCase):
    def setUp(self):
        self.cases = [dict(case=f'pcm-{mode}-{channels}-{rate}')
                      for mode in ['constant', 'linear', 'equal-power', 'overlapping-fades', 'crossfade']
                      for channels in [1, 2] for rate in [44100, 48000]]

    def test_complete_baseline_is_accepted(self):
        proof.validate_case_names(self.cases)

    def test_empty_partial_duplicate_and_unexpected_cases_are_refused(self):
        for cases in [[], self.cases[:-1], self.cases + [self.cases[0]],
                      self.cases + [dict(case='aac-constant-1-44100')]]:
            with self.subTest(cases=len(cases)), self.assertRaisesRegex(RuntimeError, 'audio matrix'):
                proof.validate_case_names(cases)

    def test_short_fade_matrix_requires_all_new_cases(self):
        short = [dict(case=f'pcm-{mode}-{channels}-{rate}')
                 for mode in ['short-equal-power', 'short-overlap']
                 for channels in [1, 2] for rate in [44100, 48000]]
        proof.validate_case_names(self.cases + short, short_fades=True)
        with self.assertRaisesRegex(RuntimeError, 'audio matrix'):
            proof.validate_case_names(self.cases + short[:-1], short_fades=True)

    def test_optional_matrix_cannot_pass_with_only_baseline(self):
        for flag in ['aac', 'extra_codecs', 'edges', 'packets', 'resampling', 'short_fades']:
            options = {flag: True}
            if flag == 'packets':
                options['aac'] = True
            with self.subTest(flag=flag), self.assertRaisesRegex(RuntimeError, 'audio matrix'):
                proof.validate_case_names(self.cases, **options)


if __name__ == '__main__':
    unittest.main()
