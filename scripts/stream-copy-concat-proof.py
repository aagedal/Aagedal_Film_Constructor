#!/usr/bin/env python3
"""Bounded development proof of exact ProRes/PCM MOV cuts-only concatenation.

The manifest is a JSON array of two to four objects containing an absolute source
path and exact rational start/end seconds. No app export mode is enabled.
"""
import argparse
from fractions import Fraction
import importlib.util
import json
from pathlib import Path
import subprocess

spec = importlib.util.spec_from_file_location('stream_copy_proof',
                                              Path(__file__).with_name('stream-copy-proof.py'))
proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proof)


def read_ranges(path):
    with path.open('rb') as source:
        data = source.read(65537)
    proof.require(len(data) <= 65536, 'Range manifest exceeds 64 KiB')
    manifest = json.loads(data)
    proof.require(isinstance(manifest, list) and 2 <= len(manifest) <= 4,
                  'Range manifest requires two to four entries')
    ranges = []
    for entry in manifest:
        proof.require(isinstance(entry, dict) and set(entry) == {'source', 'start', 'end'} and
                      all(isinstance(value, str) for value in entry.values()),
                      'Each range requires string source/start/end fields')
        source = Path(entry['source'])
        proof.require(source.is_absolute(), 'Source path must be absolute')
        start, end = Fraction(entry['start']), Fraction(entry['end'])
        proof.require(0 <= start < end, 'Require a positive exact range')
        ranges.append((source, start, end))
    return ranges


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ffmpeg', type=Path)
    parser.add_argument('ffprobe', type=Path)
    parser.add_argument('ranges', type=Path)
    parser.add_argument('scratch', type=Path, help='New absolute private output directory')
    args = parser.parse_args()
    try:
        tools = proof.Tools(args.ffmpeg, args.ffprobe)
        ranges = read_ranges(args.ranges)
        proof.require(args.scratch.is_absolute() and not args.scratch.exists(),
                      'Scratch must be a new absolute directory')
        args.scratch.mkdir(mode=0o700)
        result = proof.verify_concat(tools, ranges, args.scratch)
        (args.scratch / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2))
    except (proof.Ineligible, subprocess.SubprocessError, OSError, KeyError, ValueError,
            ZeroDivisionError) as error:
        parser.exit(1, f'Not qualified: {error}\n')


if __name__ == '__main__':
    main()
