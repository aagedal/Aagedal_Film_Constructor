#!/usr/bin/env python3
"""Select an already prepared helper directory for this checkout's Debug builds."""
import argparse
import json
from pathlib import Path


def configure(directory):
    root = Path(__file__).resolve().parent.parent
    config = root / 'Configuration' / 'LocalMediaHelpers.xcconfig'
    if directory is None:
        config.unlink(missing_ok=True)
        print('Local Debug helpers disabled; rebuild to remove bundled helpers.')
        return
    if not directory.is_absolute() or not directory.is_dir() or directory.is_symlink():
        raise ValueError('Supply an absolute prepared directory, not a link')
    value = str(directory)
    if any(character in value for character in '\n\r"$\\') or '//' in value:
        raise ValueError('Directory cannot contain xcconfig control characters')
    manifest = json.loads((directory / 'manifest.json').read_text())
    if (not isinstance(manifest, dict) or manifest.get('schemaVersion') != 1
            or not isinstance(manifest.get('files'), dict)
            or not {'ffmpeg', 'ffprobe', 'provenance.txt'} <= manifest['files'].keys()):
        raise ValueError('Unsupported prepared manifest; run prepare-media-helpers.py first')
    config.write_text('// Generated local Debug setting; do not commit.\n'
                      f'AFC_MEDIA_HELPER_DIR = {value}\n')
    print(f'Debug builds will embed helpers from {directory}. Release configuration is unchanged.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument('--prepared-dir', type=Path)
    selection.add_argument('--disable', action='store_true')
    arguments = parser.parse_args()
    try:
        configure(arguments.prepared_dir)
    except (ValueError, OSError) as error:
        parser.exit(1, f'Configuration failed: {error}\n')
