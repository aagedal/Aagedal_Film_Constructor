#!/usr/bin/env python3
"""Create a deterministic offline, populated launch fixture; no media is accessed."""
import argparse
import copy
import json
from pathlib import Path
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--clips-per-track', type=int, default=1000)
    args = parser.parse_args()
    if args.clips_per_track < 1:
        parser.error('--clips-per-track must be positive')
    repo = Path(__file__).resolve().parents[1]
    project = json.loads((repo / 'docs/evidence/native-playback-20261011/baseline/project.json').read_text())
    for asset in project['assets']:
        # Deliberately nonexistent sources make the workload reproducible and
        # keep decoder/helper initialization outside this launch measurement.
        asset['originalURL'] = 'file:///nonexistent-afc-launch-proof/' + asset['name'] + '.mov'
    for track in project['tracks']:
        source = track['clips'][0]
        track['clips'] = []
        for index in range(args.clips_per_track):
            clip = copy.deepcopy(source)
            clip['id'] = str(uuid.uuid5(uuid.NAMESPACE_URL, track['id'] + str(index))).upper()
            clip['timelineStart'] = {'numerator': index * 10, 'denominator': 1}
            track['clips'].append(clip)
    envelope = {'formatVersion': 1, 'project': project, 'mediaBookmarks': [], 'proxyBookmarks': [], 'proxyJobs': []}
    with args.output.open('x') as output:
        json.dump(envelope, output, sort_keys=True)
        output.write('\n')
    print(json.dumps({'tracks': len(project['tracks']), 'clips': sum(len(t['clips']) for t in project['tracks']),
                      'assets': len(project['assets']), 'mediaCondition': 'offline'}))


if __name__ == '__main__':
    main()
