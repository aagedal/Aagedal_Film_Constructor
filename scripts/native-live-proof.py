#!/usr/bin/env python3
"""Build the isolated native live monitor with explicitly selected local libraries.

This records development linkage, not device latency or display conformance.
--launch opens a standalone AppKit window; close it to finish the recorded run.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shlex
import subprocess

from native_parity import mpvkit_pin


def positive_seconds(value):
    seconds = float(value)
    if not math.isfinite(seconds) or seconds <= 0:
        raise argparse.ArgumentTypeError('must be a finite positive number')
    return seconds


def read_observations(path, scripted=False):
    """Require a complete run; observations alone never qualify physical output."""
    records = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    if not records or not isinstance(records[-1], dict) or records[-1].get('event') != 'closed':
        raise ValueError('Live observations do not contain a final closed record')
    previous = 0.0
    for record in records:
        if not isinstance(record, dict):
            raise ValueError('Invalid live observation record')
        elapsed = record.get('elapsedSeconds')
        if (record.get('schemaVersion') != 1 or record.get('hardwareQualified') is not False
                or not isinstance(elapsed, (int, float)) or isinstance(elapsed, bool)
                or not math.isfinite(elapsed) or elapsed < previous
                or not isinstance(record.get('statistics'), dict)
                or not isinstance(record.get('errors'), list)
                or not all(isinstance(error, str) for error in record['errors'])):
            raise ValueError('Invalid live observation record')
        previous = elapsed
    if scripted:
        states = [('opened', False), ('initial-seek', False), ('script-play', True),
                  ('script-seek', True), ('script-pause', False), ('script-resume', True),
                  ('closed', False)]
        actions = [record for record in records
                   if record.get('event') in dict(states)
                   or str(record.get('event', '')).startswith('script-')]
        if [record.get('event') for record in actions] != [event for event, _ in states]:
            raise ValueError('Scripted live run did not complete all actions in order')
        for record, (event, playing) in zip(actions, states):
            if record.get('isPlaying') is not playing:
                raise ValueError(f'Scripted live action {event} has unexpected playing state')
    return {'recordCount': len(records), 'final': records[-1]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--launch', action='store_true')
    parser.add_argument('--observation-interval', type=positive_seconds, default=0.5,
                        help='Seconds between retained clock/frame observations (default: 0.5)')
    parser.add_argument('--scripted-duration', type=positive_seconds,
                        help='With --launch, run play, seek to start, pause, resume, then close; '
                             'duration excludes time spent priming or seeking')
    args = parser.parse_args()
    if args.scripted_duration is not None and not args.launch:
        parser.error('--scripted-duration requires --launch')
    project = args.project.resolve(strict=True)
    output = args.output.absolute()
    output.mkdir(parents=True, exist_ok=False)
    repo = Path(__file__).resolve().parent.parent
    env = os.environ.copy()
    env['CLANG_MODULE_CACHE_PATH'] = str(output / 'module-cache')
    env['SWIFTPM_MODULECACHE_OVERRIDE'] = str(output / 'module-cache')
    common = ['--package-path', str(repo / 'Packages/NativePlaybackProof'),
              '--scratch-path', str(output / 'build'), '--cache-path', str(output / 'cache'),
              '--disable-sandbox']
    commands = [['swift', 'build', '--product', 'NativeLiveProof', *common],
                ['swift', 'test', *common]]
    manifest = {'commands': commands, 'project': str(project),
                'projectSHA256': hashlib.sha256(project.read_bytes()).hexdigest(),
                'hardwareQualified': False, 'launched': False}
    for command, log in zip(commands, ['build.log', 'tests.log']):
        with (output / log).open('w') as handle:
            subprocess.run(command, env=env, stdout=handle, stderr=subprocess.STDOUT, check=True)
    executable = output / 'build/debug/NativeLiveProof'
    manifest['executableSHA256'] = hashlib.sha256(executable.read_bytes()).hexdigest()
    manifest['dependencies'] = subprocess.check_output(['otool', '-L', str(executable)], text=True)
    manifest['mpvkit'] = mpvkit_pin(repo)
    manifest_path = output / 'manifest.json'
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
    observation_path = output / 'live-observations.jsonl'
    launch = [str(executable), str(project), '--observations', str(observation_path),
              '--observation-interval', str(args.observation_interval)]
    if args.scripted_duration is not None:
        launch += ['--scripted-duration', str(args.scripted_duration)]
    manifest['launchCommand'] = launch
    manifest['clockBasis'] = 'AVAudioPlayerNode render sample clock; not acoustic or display presentation'
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
    print(shlex.join(launch), flush=True)
    if args.launch:
        manifest['launched'] = True
        with (output / 'live-observations.log').open('w') as handle:
            result = subprocess.run(launch, env=env, stdout=handle, stderr=subprocess.STDOUT)
        manifest['exitCode'] = result.returncode
        exit_code = result.returncode
        try:
            manifest['observations'] = read_observations(observation_path, scripted=args.scripted_duration is not None)
            if manifest['observations']['final']['errors']:
                exit_code = exit_code or 1
        except (OSError, ValueError, TypeError) as error:
            manifest['observationError'] = str(error)
            exit_code = exit_code or 1
        manifest['observationExitCode'] = exit_code
        manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
        raise SystemExit(exit_code)


if __name__ == '__main__':
    main()
