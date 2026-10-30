#!/usr/bin/env python3
"""Select the native FFmpeg playback runtime for Xcode Debug builds.

FFmpeg comes from the pinned MPVKit package; nothing is installed or discovered on
this machine. This is a machine-local opt-in, not release approval.
"""
import argparse
from pathlib import Path

SETTINGS = '\n'.join([
    '// Local Debug selection of the native runtime; never release approval.',
    'AFC_NATIVE_PLAYBACK = YES',
    'SWIFT_INCLUDE_PATHS = $(inherited) "$(DERIVED_FILE_DIR)/native-playback/products" "$(DERIVED_FILE_DIR)/native-playback/products/Modules"',
    'OTHER_SWIFT_FLAGS = $(inherited) -Xcc "-fmodule-map-file=$(DERIVED_FILE_DIR)/native-playback/CNativeDecoder.modulemap"',
    'OTHER_LDFLAGS = $(inherited) -L"$(DERIVED_FILE_DIR)/native-playback/products" -lNativePlaybackRuntime',
    '',
])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument('--enable', action='store_true', help='Build and embed the native runtime in Debug')
    selection.add_argument('--disable', action='store_true', help='Remove local native Debug selection')
    args = parser.parse_args()
    destination = Path(__file__).resolve().parent.parent / 'Configuration/LocalNativePlayback.xcconfig'
    if args.disable:
        destination.unlink(missing_ok=True)
        print('Native playback local Debug selection removed.')
        return
    destination.write_text(SETTINGS)
    print(destination)


if __name__ == '__main__':
    main()
