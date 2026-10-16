import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('async_proof', Path(__file__).with_name('mpv-async-source-proof.py'))
proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proof)


class AsyncSourceReportTests(unittest.TestCase):
    def report(self):
        return {'passed': True, 'cycles': 12, 'seeks': 60, 'rapidCommands': 36,
                'rejections': 7, 'pendingCloses': 12, 'boundedReplies': 64,
                'eofRecoveries': 1, 'disabledTypes': 2,
                'captures': [{'target': 0.5, 'position': 0.5, 'width': 320, 'height': 180}
                             for _ in range(60)]}

    def test_requires_every_lifecycle_category(self):
        proof.validate_report(self.report())
        for key in ('cycles', 'seeks', 'rapidCommands', 'rejections', 'pendingCloses',
                    'boundedReplies', 'eofRecoveries', 'disabledTypes'):
            report = self.report()
            report[key] -= 1
            with self.subTest(key=key), self.assertRaises(ValueError):
                proof.validate_report(report)

    def test_rejects_missing_capture_wrong_shape_or_stale_position(self):
        report = self.report()
        report['captures'].pop()
        with self.assertRaises(ValueError):
            proof.validate_report(report)
        for field, value in (('position', 1.5), ('position', float('nan')),
                             ('position', float('inf')), ('width', 319), ('height', 181)):
            report = self.report()
            report['captures'][0][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                proof.validate_report(report)

    def test_client_failure_cannot_be_qualified_by_partial_captures(self):
        report = self.report()
        report['passed'] = False
        with self.assertRaises(ValueError):
            proof.validate_report(report)


if __name__ == '__main__':
    unittest.main()
