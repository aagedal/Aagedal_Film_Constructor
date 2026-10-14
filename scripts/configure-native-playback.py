#!/usr/bin/env python3
"""Select explicitly attributed local FFmpeg development libraries for Xcode Debug.

This is a machine-local opt-in, not release approval or dependency installation.
"""
import argparse
import os
from pathlib import Path
import subprocess

LIBRARIES = ('libavformat', 'libavcodec', 'libavutil', 'libswscale', 'libswresample')


def xcconfig_value(value):
    value = str(value)
    # Xcode's parser treats // as a comment even in quoted values. Fail closed.
    if any(char in value for char in ('\n', '\r', '"', '$', '\\')) or '//' in value:
        raise ValueError('Path contains unsupported xcconfig syntax')
    return value


def selected_settings(pkg_config, notices, provenance):
    for path in (pkg_config, notices, provenance):
        if not path.is_absolute():
            raise ValueError('All selected paths must be absolute')
        xcconfig_value(path)
    if not pkg_config.is_file() or not os.access(pkg_config, os.X_OK):
        raise ValueError('pkg-config must be an executable file')
    if not notices.is_dir() or not any(p.is_file() for p in notices.rglob('*')):
        raise ValueError('Notices must be a nonempty directory')
    if not provenance.is_file() or not provenance.read_bytes().strip():
        raise ValueError('Provenance must be a nonempty file')
    subprocess.run([str(pkg_config), '--exists', *LIBRARIES], check=True)
    return '\n'.join([
        '// Explicit local development dependency selection; never release approval.',
        'AFC_NATIVE_PLAYBACK = YES',
        'AFC_NATIVE_PKG_CONFIG = ' + xcconfig_value(pkg_config),
        'AFC_NATIVE_NOTICES = ' + xcconfig_value(notices),
        'AFC_NATIVE_PROVENANCE = ' + xcconfig_value(provenance),
        'SWIFT_INCLUDE_PATHS = $(inherited) "$(DERIVED_FILE_DIR)/native-playback/products" "$(DERIVED_FILE_DIR)/native-playback/products/Modules"',
        'OTHER_SWIFT_FLAGS = $(inherited) -Xcc "-fmodule-map-file=$(DERIVED_FILE_DIR)/native-playback/CNativeDecoder.modulemap"',
        'OTHER_LDFLAGS = $(inherited) -L"$(DERIVED_FILE_DIR)/native-playback/products" -lNativePlaybackRuntime',
        '',
    ])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument('--pkg-config', type=Path)
    selection.add_argument('--disable', action='store_true', help='Remove local native Debug selection')
    parser.add_argument('--notices', type=Path)
    parser.add_argument('--provenance', type=Path)
    args = parser.parse_args()
    destination = Path(__file__).resolve().parent.parent / 'Configuration/LocalNativePlayback.xcconfig'
    if args.disable:
        if args.notices or args.provenance:
            parser.error('--disable does not accept notices/provenance')
        destination.unlink(missing_ok=True)
        print('Native playback local Debug selection removed.')
        return
    if not args.notices or not args.provenance:
        parser.error('Selected native playback requires --notices and --provenance')
    try:
        settings = selected_settings(args.pkg_config, args.notices, args.provenance)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.error(str(error))
    destination.write_text(settings)
    print(destination)


if __name__ == '__main__':
    main()
