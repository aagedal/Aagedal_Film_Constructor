#!/usr/bin/env python3
"""Time repeated launches of one already-built app bundle (a user's normal launch).

release-launch-proof.py copies and registers a fresh bundle for every run, so each
of its samples includes first-launch system assessment. This measures the same
bundle launched repeatedly, through Launch Services, to the instrumented first
processed interaction. Usage: repeat-launch-timing.py /path/App.app [--runs 5]
"""
import argparse, json, os, subprocess, tempfile, time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app')
parser.add_argument('--runs', type=int, default=5)
args = parser.parse_args()
results = []
for run in range(1, args.runs + 1):
    fd, log = tempfile.mkstemp(suffix='.jsonl'); os.close(fd)
    start = time.clock_gettime(time.CLOCK_UPTIME_RAW)
    process = subprocess.Popen(['open', '-n', '-W', '--env', f'AFC_LAUNCH_PROBE_LOG={log}', args.app,
                                '--args', '-ApplePersistenceIgnoreState', 'YES'])
    events, pid, deadline = {}, None, time.time() + 20
    while time.time() < deadline and 'scripted_interaction_processed' not in events:
        with open(log) as handle:
            for line in handle:
                event = json.loads(line); pid = event['pid']
                events.setdefault(event['event'], event['uptimeSeconds'] - start)
        time.sleep(0.02)
    if pid: os.kill(pid, 15)
    process.wait(); os.unlink(log)
    seconds = events.get('scripted_interaction_processed')
    results.append(seconds)
    print(f"run {run}: did-finish-launching {events.get('application_did_finish_launching', float('nan')):.3f} s, "
          f"interaction {seconds if seconds is None else round(seconds, 3)} s")
    time.sleep(1)
valid = sorted(s for s in results if s is not None)
if valid:
    print(f"min {valid[0]:.3f} s, median {valid[len(valid)//2]:.3f} s, max {valid[-1]:.3f} s; "
          f"{sum(s < 2 for s in valid)}/{len(results)} under two seconds")
