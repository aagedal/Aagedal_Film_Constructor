#!/usr/bin/env python3
"""Validation of retained live-run evidence, independent of a physical device."""
import argparse
import importlib.util
import json
from pathlib import Path
import tempfile
import subprocess
import sys
from unittest.mock import patch
import unittest

spec = importlib.util.spec_from_file_location('native_live_proof', Path(__file__).with_name('native-live-proof.py'))
proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proof)


class ObservationTests(unittest.TestCase):
    def record(self, event='closed', elapsed=1.0, **changes):
        value = dict(schemaVersion=1, event=event, elapsedSeconds=elapsed,
                     hardwareQualified=False, statistics={'clockSamples': 42}, errors=[])
        value.update(changes)
        return value

    def read(self, records):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'observations.jsonl'
            path.write_text(''.join(json.dumps(record) + '\n' for record in records))
            return proof.read_observations(path)

    def test_retains_final_statistics_and_errors(self):
        final = self.record(errors=['Live audio underrun'])
        summary = self.read([self.record(event='opened', elapsed=0), final])
        self.assertEqual(summary, {'recordCount': 2, 'final': final})

    def test_rejects_incomplete_runs(self):
        for records in [[], [self.record(event='sample')]]:
            with self.subTest(records=records), self.assertRaises(ValueError):
                self.read(records)

    def test_rejects_invalid_or_hardware_claiming_records(self):
        for changes in [dict(hardwareQualified=True), dict(schemaVersion=2),
                        dict(elapsedSeconds=-1), dict(elapsedSeconds=float('nan')),
                        dict(elapsedSeconds=True), dict(statistics=None), dict(errors='error')]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.read([self.record(**changes)])
        with self.assertRaises(ValueError):
            self.read([self.record(event='sample', elapsed=2), self.record(elapsed=1)])

    def test_positive_seconds(self):
        self.assertEqual(proof.positive_seconds('0.25'), 0.25)
        for value in ['0', '-1', 'nan', 'inf']:
            with self.subTest(value=value), self.assertRaises(argparse.ArgumentTypeError):
                proof.positive_seconds(value)


class HarnessTests(unittest.TestCase):
    record = ObservationTests.record
    def run_harness(self, launch=False, records=None, scripted=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pkg = root / 'pkg-config'; pkg.write_text('fixture')
            project = root / 'project.json'; project.write_text('{}')
            output = root / 'result'
            for library in ['libavformat', 'libavcodec', 'libavutil', 'libswscale', 'libswresample']:
                (root / (library + '.dylib')).write_bytes(b'fixture')
            commands = []

            def check_output(command, **kwargs):
                if '--variable=libdir' in command:
                    return str(root)
                if command[0] == 'otool':
                    return 'fixture linkage'
                return ''

            def run(command, **kwargs):
                commands.append(command)
                if command[:2] == ['swift', 'build']:
                    executable = output / 'build/debug/NativeLiveProof'
                    executable.parent.mkdir(parents=True)
                    executable.write_bytes(b'fixture executable')
                elif command[0] != 'swift' and records is not None:
                    path = Path(command[command.index('--observations') + 1])
                    path.write_text(''.join(json.dumps(record) + '\n' for record in records))
                return subprocess.CompletedProcess(command, 0)

            arguments = ['native-live-proof.py', '--pkg-config', str(pkg), '--project',
                         str(project), '--output', str(output)]
            if launch:
                arguments.append('--launch')
            if scripted:
                arguments += ['--scripted-duration', '1']
            with patch.object(sys, 'argv', arguments), patch.object(proof.subprocess, 'run', run), \
                    patch.object(proof.subprocess, 'check_output', check_output), patch('builtins.print'):
                exit_code = None
                try:
                    proof.main()
                except SystemExit as error:
                    exit_code = error.code
            manifest = json.loads((output / 'manifest.json').read_text())
            return commands, manifest, exit_code

    def test_build_only_does_not_launch(self):
        commands, manifest, exit_code = self.run_harness()
        self.assertEqual(len(commands), 2)
        self.assertFalse(manifest['launched'])
        self.assertFalse(manifest['hardwareQualified'])
        self.assertIsNone(exit_code)

    def test_scripted_launch_retains_final_record(self):
        commands, manifest, exit_code = self.run_harness(launch=True,
            records=[self.record()], scripted=True)
        self.assertIn('--scripted-duration', commands[-1])
        self.assertEqual(manifest['observations']['final']['statistics'], {'clockSamples': 42})
        self.assertFalse(manifest['hardwareQualified'])
        self.assertEqual(exit_code, 0)

    def test_missing_final_or_errors_fail_run(self):
        for records in [None, [self.record(event='sample')], [self.record(errors=['underrun'])]]:
            with self.subTest(records=records):
                _, manifest, exit_code = self.run_harness(launch=True, records=records)
                self.assertEqual(exit_code, 1)
                self.assertEqual(manifest['observationExitCode'], 1)


if __name__ == '__main__':
    unittest.main()
