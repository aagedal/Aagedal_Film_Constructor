import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('coexistence', Path(__file__).with_name('mpv-swift-coexistence-proof.py'))
proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proof)


class SwiftCoexistenceReportTests(unittest.TestCase):
    def report(self, concurrent=True):
        return {'passed': True, 'cycles': 12, 'replacements': 12, 'oldEpochRejections': 11,
                'closedAdmissionRejected': True,
                'native': [{'sourceFrame': frame + (6 if cycle % 2 else 0),
                            'file': f'native-{cycle}-{index}', 'completed': cycle + .5}
                           for cycle in range(12)
                           for index, frame in enumerate([0, 36, 6, 48, 12] * 2)],
                'windows': [{'start': cycle, 'end': cycle + 1} for cycle in range(12)] if concurrent else [],
                'captures': [{'file': f'mpv-{cycle}-{target}', 'target': target, 'position': target}
                             for cycle in range(12) for target in [0, 1.5, .25, 2, .5]] if concurrent else []}

    def test_requires_complete_native_and_source_work(self):
        proof.validate_report(self.report(), True)
        proof.validate_report(self.report(False), False)
        for key in ('cycles', 'replacements', 'oldEpochRejections'):
            report = self.report()
            report[key] -= 1
            with self.subTest(key=key), self.assertRaises(ValueError):
                proof.validate_report(report, True)
        for key in ('native', 'windows', 'captures'):
            report = self.report()
            report[key].pop()
            with self.subTest(key=key), self.assertRaises(ValueError):
                proof.validate_report(report, True)

    def test_rejects_wrong_frames_duplicate_outputs_and_nonoverlap(self):
        for key, value in [('sourceFrame', 1), ('file', 'native-0-1'),
                           ('completed', float('nan'))]:
            report = self.report()
            report['native'][0][key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                proof.validate_report(report, True)
        report = self.report()
        for row in report['native'][:10]:
            row['completed'] = -1
        with self.assertRaises(ValueError):
            proof.validate_report(report, True)
        for key, value in [('position', 2), ('position', float('inf')), ('target', 1), ('file', 'mpv-0-1.5')]:
            report = self.report()
            report['captures'][0][key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                proof.validate_report(report, True)

    def test_baseline_and_close_failures_cannot_pass(self):
        report = self.report()
        with self.assertRaises(ValueError):
            proof.validate_report(report, False)
        for key in ('passed', 'closedAdmissionRejected'):
            report = self.report()
            report[key] = False
            with self.subTest(key=key), self.assertRaises(ValueError):
                proof.validate_report(report, True)
        for value in (-1, float('nan')):
            report = self.report()
            report['windows'][0]['end'] = value
            with self.assertRaises(ValueError):
                proof.validate_report(report, True)


if __name__ == '__main__':
    unittest.main()
