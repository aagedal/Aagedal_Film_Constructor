#!/usr/bin/env python3
"""Build and measure an isolated Release app; no existing application is quit."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import signal
import statistics
import subprocess
import tempfile
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--runs', type=int, default=5)
    parser.add_argument('--timeout', type=float, default=20)
    parser.add_argument('--project', type=Path, help='Open an isolated copy of this project instead of an untitled workspace; referenced media remains at its original URLs')
    parser.add_argument('--hold-last', type=float, default=0, help='Keep the final isolated window open for optional visual inspection (0–60 seconds)')
    args = parser.parse_args()
    if args.runs < 2 or args.timeout <= 0 or not 0 <= args.hold_last <= 60:
        parser.error('Use at least two runs, a positive timeout and --hold-last between 0 and 60')
    project = args.project.resolve() if args.project else None
    if project and not project.is_file():
        parser.error('--project must be an existing regular project file')
    expected_counts = None
    if project:
        try:
            model = json.loads(project.read_text())['project']
            expected_counts = {'assetCount': len(model['assets']), 'trackCount': len(model['tracks']),
                               'clipCount': sum(len(track['clips']) for track in model['tracks'])}
        except (ValueError, KeyError, TypeError) as error:
            parser.error(f'--project must contain a document envelope with project assets/tracks: {error}')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    repo = Path(__file__).resolve().parents[1]
    failures = []
    samples = []
    manifest = {'schemaVersion': 2, 'configuration': 'Release',
                'environment': {'platform': platform.platform(), 'machine': platform.machine(),
                                'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip()},
                'sourceHashes': {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest() for p in [repo / 'Aagedal Film Constructor/MyApp.swift', repo / 'Aagedal Film Constructor/LaunchWorkspaceCoordinator.swift', Path(__file__).resolve()]},
                'method': 'Launch Services request to harness receipt of loaded visible key document-window marker and synthetic AppKit button mouse-event action',
                'limitations': ['unsigned local bundle', 'no physical input or compositor timestamp',
                                'first run is fresh preferences, not purged OS caches; subsequent runs are warm OS caches with fresh preferences',
                                'synthetic probe control; no ordinary editing or shipping sandbox/notarization acceptance']}
    manifest['workspace'] = {'kind': 'saved-project' if project else 'empty-untitled'}
    if project:
        manifest['workspace'].update(sourceName=project.name, sourceSHA256=hashlib.sha256(project.read_bytes()).hexdigest(), expectedCounts=expected_counts)
    with tempfile.TemporaryDirectory(prefix='afc-release-launch-') as temporary:
        root = Path(temporary)
        derived = root / 'DerivedData'
        identifier = 'dev.aagedal.launchproof.' + uuid.uuid4().hex
        command = ['xcodebuild', '-project', str(repo / 'Aagedal Film Constructor.xcodeproj'),
                   '-scheme', 'Aagedal Film Constructor', '-configuration', 'Release',
                   '-derivedDataPath', str(derived), 'CODE_SIGNING_ALLOWED=NO',
                   'PRODUCT_BUNDLE_IDENTIFIER=' + identifier, 'AFC_MEDIA_HELPER_DIR=', 'build']
        manifest['buildCommand'] = command
        with (output / 'build.log').open('w') as log:
            result = subprocess.run(command, cwd=repo, stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            failures.append('Release build failed; see build.log')
        else:
            app = derived / 'Build/Products/Release/Aagedal Film Constructor.app'
            plist_path = app / 'Contents/Info.plist'
            plist = plistlib.loads(plist_path.read_bytes())
            executable = app / 'Contents/MacOS' / plist['CFBundleExecutable']
            manifest['executableSHA256'] = hashlib.sha256(executable.read_bytes()).hexdigest()
            helpers = app / 'Contents/Resources/Helpers'
            manifest['bundledHelpers'] = sorted(str(p.relative_to(helpers)) for p in helpers.rglob('*') if p.is_file())
            for index in range(args.runs):
                # A separate bundle domain isolates AppStorage and AppKit state
                # without modifying preferences/documents for the installed app.
                run_id = identifier + '.run' + str(index + 1)
                run_app = root / ('Run' + str(index + 1) + '.app')
                shutil.copytree(app, run_app)
                run_plist = dict(plist, CFBundleIdentifier=run_id, NSQuitAlwaysKeepsWindows=False)
                (run_app / 'Contents/Info.plist').write_bytes(plistlib.dumps(run_plist))
                run_executable = run_app / 'Contents/MacOS' / plist['CFBundleExecutable']
                run_project = None
                if project:
                    run_project = root / ('Run' + str(index + 1)) / project.name
                    run_project.parent.mkdir()
                    shutil.copy2(project, run_project)
                marker = output / ('run-' + str(index + 1) + '.jsonl')
                marker.touch()
                env = dict(os.environ, AFC_LAUNCH_PROBE_LOG=str(marker))
                sample = {'run': index + 1, 'cacheCondition': 'first-process/fresh-preferences' if index == 0 else 'warm-OS-cache/fresh-preferences',
                          'bundleIdentifier': run_id, 'events': []}
                start = time.monotonic()
                with (output / ('run-' + str(index + 1) + '.stderr.log')).open('w') as log:
                    launch_command = ['/usr/bin/open', '-n', '-W', '--env',
                                      'AFC_LAUNCH_PROBE_LOG=' + str(marker),
                                      '--stderr', str(output / ('run-' + str(index + 1) + '.app.stderr.log'))]
                    launch_command += ['-a', str(run_app), str(run_project)] if run_project else [str(run_app)]
                    launch_command += ['--args', '-ApplePersistenceIgnoreState', 'YES']
                    sample['launchCommand'] = launch_command
                    process = subprocess.Popen(launch_command, env=env, stdout=log, stderr=log)
                    try:
                        seen = 0
                        while time.monotonic() - start < args.timeout:
                            lines = marker.read_text().splitlines()
                            for line in lines[seen:]:
                                try:
                                    event = json.loads(line)
                                except json.JSONDecodeError:
                                    break  # A concurrent append may still be incomplete.
                                event['observedSecondsAfterSpawn'] = time.monotonic() - start
                                sample['events'].append(event)
                                seen += 1
                            if any(e['event'] == 'scripted_interaction_processed' for e in sample['events']):
                                break
                            if process.poll() is not None:
                                break
                            time.sleep(0.01)
                        sample['interactionObserved'] = any(e['event'] == 'scripted_interaction_processed' for e in sample['events'])
                        gates = [e for e in sample['events'] if e['event'] == 'readiness_gate_changed']
                        sample['lastReadinessGate'] = gates[-1] if gates else None
                        if not sample['interactionObserved']:
                            failures.append(f'Run {index + 1}: no interaction marker before exit/timeout')
                        loaded = [e for e in sample['events'] if e['event'] == 'workspace_loaded']
                        sample['workspaceLoaded'] = loaded[-1] if loaded else None
                        if project and not any(e.get('savedDocument') is True and all(e.get(key) == value for key, value in expected_counts.items()) for e in loaded):
                            failures.append(f'Run {index + 1}: copied saved-project workspace/counts were not confirmed')
                        sample['exitBeforeCleanup'] = process.poll()
                        if index == args.runs - 1 and sample['interactionObserved'] and args.hold_last:
                            print(json.dumps({'inspectionApp': str(run_app), 'holdSeconds': args.hold_last}), flush=True)
                            deadline = time.monotonic() + args.hold_last
                            while time.monotonic() < deadline and process.poll() is None:
                                time.sleep(0.1)
                    finally:
                        # Verify each PID's executable path before terminating an app.
                        # open -W itself is only the Launch Services waiter.
                        library = ctypes.CDLL('/usr/lib/libproc.dylib')
                        def matches_isolated_executable(pid):
                            buffer = ctypes.create_string_buffer(4096)
                            return (library.proc_pidpath(pid, buffer, len(buffer)) > 0
                                    and os.fsdecode(buffer.value) == str(run_executable))
                        isolated_pids = [int(pid) for pid in subprocess.check_output(['ps', '-axo', 'pid='], text=True).split()
                                         if matches_isolated_executable(int(pid))]
                        for pid in isolated_pids:
                            try:
                                os.kill(pid, signal.SIGTERM)
                            except ProcessLookupError:
                                pass
                        # Finish quitting this run before Launch Services activates
                        # the next one; overlapping document windows can steal key status.
                        quit_deadline = time.monotonic() + 3
                        while any(matches_isolated_executable(pid) for pid in isolated_pids) and time.monotonic() < quit_deadline:
                            time.sleep(0.01)
                        remaining = [pid for pid in isolated_pids if matches_isolated_executable(pid)]
                        sample['forcedTerminationPIDs'] = remaining
                        for pid in remaining:
                            try:
                                os.kill(pid, signal.SIGKILL)
                            except ProcessLookupError:
                                pass
                        if process.poll() is None:
                            process.terminate()
                            try:
                                process.wait(timeout=3)
                            except subprocess.TimeoutExpired:
                                process.kill()
                                process.wait()
                        subprocess.run(['defaults', 'delete', run_id], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                        saved_state = Path.home() / 'Library/Saved Application State' / (run_id + '.savedState')
                        # AppKit may write restoration state despite ignore-state.
                        # Do not remove outside the temporary root here.
                        sample['savedStateExists'] = saved_state.exists()
                samples.append(sample)
    observed = [e['observedSecondsAfterSpawn'] for s in samples for e in s['events'] if e['event'] == 'scripted_interaction_processed']
    manifest.update(samples=samples, failures=failures, validRuns=len(observed), requestedRuns=args.runs,
                    allRunsUnderTwoSeconds=(not failures and len(observed) == args.runs and max(observed) < 2))
    if observed:
        manifest['scriptedInteractionSeconds'] = {'min': min(observed), 'median': statistics.median(observed), 'max': max(observed)}
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({k: manifest[k] for k in ('validRuns', 'requestedRuns', 'allRunsUnderTwoSeconds', 'failures')}, indent=2))
    return 1 if failures else 0


if __name__ == '__main__':
    raise SystemExit(main())
