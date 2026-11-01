#!/usr/bin/env python3
"""Prepare explicitly supplied FFmpeg helpers; never downloads or certifies licensing."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

# The app's command lines declare what they use in Configuration/FFmpegRequirements.json.
_spec = importlib.util.spec_from_file_location('ffmpeg_copies_audit', Path(__file__).with_name('ffmpeg-copies-audit.py'))
audit = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(audit)
REQUIRED = audit.required(audit.load_requirements())

def capture(executable, *arguments):
    return subprocess.check_output([str(executable), *arguments], stderr=subprocess.STDOUT, text=True)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def prepare(args):
    output = args.output
    if not output.is_absolute() or output.exists():
        raise ValueError('Output must be a new absolute directory')
    if not args.notices.is_dir() or not any(p.is_file() for p in args.notices.rglob('*')):
        raise ValueError('Supply a nonempty notices directory for this exact build')
    if not args.provenance.is_file():
        raise ValueError('Supply a provenance file; unknown attribution must be recorded explicitly')
    helpers = {}
    for name, path in [('ffmpeg', args.ffmpeg), ('ffprobe', args.ffprobe)]:
        if not path.is_absolute() or not path.is_file() or not os.access(path, os.X_OK):
            raise ValueError(f'{name} requires an explicit absolute executable path')
        version = capture(path, '-version')
        first = version.splitlines()[0]
        match = re.match(r'\S+ version (\S+)', first)
        config = next((line.strip() for line in version.splitlines() if line.startswith('configuration:')), None)
        if not match or not config:
            raise ValueError(f'Cannot identify {name} version/build configuration')
        if '--enable-nonfree' in config.split():
            raise ValueError('Nonfree builds cannot be prepared for app packaging')
        dependencies = capture('/usr/bin/otool', '-L', str(path))
        linked = [line.strip().split(' (compatibility')[0] for line in dependencies.splitlines()[1:] if line.strip()]
        if any(not (item.startswith('/usr/lib/') or item.startswith('/System/Library/')) for item in linked):
            raise ValueError(f'{name} has non-system dependencies: {linked}')
        helpers[name] = {'version': match.group(1), 'configuration': config, 'versionOutput': version,
                         'dependencies': linked, 'inputSHA256': digest(path)}
    if helpers['ffmpeg']['version'] != helpers['ffprobe']['version'] or helpers['ffmpeg']['configuration'] != helpers['ffprobe']['configuration']:
        raise ValueError('FFmpeg and FFprobe must have matching versions and build configurations')
    filters = capture(args.ffmpeg, '-hide_banner', '-filters')
    encoders = capture(args.ffmpeg, '-hide_banner', '-encoders')
    decoders = capture(args.ffmpeg, '-hide_banner', '-decoders')
    muxers = capture(args.ffmpeg, '-hide_banner', '-muxers')
    listings = dict(encoders=encoders, decoders=decoders, filters=filters, muxers=muxers)
    missing = {kind: sorted(REQUIRED[kind] - audit.listing_names(listings[kind])) for kind in audit.KINDS}
    if any(missing.values()):
        raise ValueError('Supplied FFmpeg lacks components the app uses (Configuration/FFmpegRequirements.json): '
                         + '; '.join(f'{kind} {", ".join(names)}' for kind, names in missing.items() if names))
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix='.media-helpers-', dir=output.parent))
    try:
        for name, source in [('ffmpeg', args.ffmpeg), ('ffprobe', args.ffprobe)]:
            shutil.copyfile(source, temporary / name)
            (temporary / name).chmod(0o755)
        # Flatten no links: documentation must be self-contained and reviewable.
        for source in args.notices.rglob('*'):
            if source.is_symlink():
                raise ValueError('Notices must not contain symbolic links')
        shutil.copytree(args.notices, temporary / 'notices')
        shutil.copyfile(args.provenance, temporary / 'provenance.txt')
        (temporary / 'filters.txt').write_text(filters)
        (temporary / 'encoders.txt').write_text(encoders)
        (temporary / 'decoders.txt').write_text(decoders)
        (temporary / 'muxers.txt').write_text(muxers)
        files = {str(p.relative_to(temporary)): digest(p) for p in sorted(temporary.rglob('*')) if p.is_file()}
        manifest = {'schemaVersion': 1, 'helpers': helpers, 'files': files,
                    'capabilities': {'requiredFilters': sorted(REQUIRED['filters']), 'requiredEncoders': sorted(REQUIRED['encoders']), 'requiredImageDecoders': sorted(REQUIRED['decoders']), 'requiredMuxers': sorted(REQUIRED['muxers'])},
                    'licenseReview': 'unreviewed', 'provenanceReview': 'unreviewed', 'releaseCertified': False}
        (temporary / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        temporary.rename(output)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)
    print(f'Prepared {output}; notices and provenance remain unreviewed, releaseCertified=false')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('ffmpeg', 'ffprobe', 'output', 'notices', 'provenance'):
        parser.add_argument('--' + name, type=Path, required=True)
    try:
        prepare(parser.parse_args())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Preparation failed: {error}\n')
