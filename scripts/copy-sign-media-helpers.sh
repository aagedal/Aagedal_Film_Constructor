#!/bin/bash
# Xcode build phase: pinned automatic helpers, with explicit override/opt-out.
set -euo pipefail
: "${TARGET_BUILD_DIR:?Xcode TARGET_BUILD_DIR is required}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?Xcode resource destination is required}"
DESTINATION="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Helpers"
if [[ "${AFC_BUNDLE_MEDIA_HELPERS:-YES}" == NO ]]; then
    rm -rf "$DESTINATION"
    exit 0
fi
: "${SRCROOT:?Xcode SRCROOT is required}"
if [[ -z "${AFC_MEDIA_HELPER_DIR:-}" ]]; then
    AFC_MEDIA_HELPER_DIR="$(python3 "$SRCROOT/scripts/bootstrap-media-helpers.py")"
fi
python3 - "$AFC_MEDIA_HELPER_DIR" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
if not root.is_absolute() or not root.is_dir() or root.is_symlink():
    raise SystemExit('AFC_MEDIA_HELPER_DIR must identify an absolute prepared directory')
manifest = json.loads((root / 'manifest.json').read_text())
if manifest.get('schemaVersion') != 1 or not {'ffmpeg', 'ffprobe', 'provenance.txt'} <= manifest.get('files', {}).keys():
    raise SystemExit('Missing or unsupported helper manifest')
expected = set(manifest['files']) | {'manifest.json'}
actual = {str(p.relative_to(root)) for p in root.rglob('*') if p.is_file()}
if actual != expected or any(p.is_symlink() for p in root.rglob('*')):
    raise SystemExit('Prepared directory contains unexpected/missing files or links')
for name, sha in manifest['files'].items():
    relative = Path(name)
    if relative.is_absolute() or '..' in relative.parts:
        raise SystemExit('Unsafe manifest path')
    path = root / relative
    if hashlib.sha256(path.read_bytes()).hexdigest() != sha:
        raise SystemExit(f'Prepared helper hash mismatch: {name}')
for name in ('ffmpeg', 'ffprobe'):
    if '--enable-nonfree' in manifest['helpers'][name]['configuration'].split():
        raise SystemExit('Nonfree helper configuration is unsupported')
PY
rm -rf "$DESTINATION"
mkdir -p "$(dirname "$DESTINATION")"
/usr/bin/ditto "$AFC_MEDIA_HELPER_DIR" "$DESTINATION"
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == YES ]]; then
    : "${EXPANDED_CODE_SIGN_IDENTITY:?Xcode did not supply a helper signing identity}"
    for HELPER_NAME in ffmpeg ffprobe; do
        # OTHER_CODE_SIGN_FLAGS carries --timestamp for notarized distribution builds.
        # shellcheck disable=SC2086
        /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" ${OTHER_CODE_SIGN_FLAGS:-} \
            --options runtime --entitlements "$SRCROOT/Configuration/MediaHelper.entitlements" \
            "$DESTINATION/$HELPER_NAME"
        /usr/bin/codesign --verify --strict "$DESTINATION/$HELPER_NAME"
    done
fi
