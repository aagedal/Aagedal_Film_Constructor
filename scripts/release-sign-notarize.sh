#!/bin/bash
# Build, sign with Developer ID (hardened runtime, sandbox), notarize and staple a
# distributable Release app, then package it as a notarized ZIP.
# Usage: scripts/release-sign-notarize.sh [output-directory]
# Environment: AFC_TEAM_ID (default 3R5QGG9DW6), AFC_NOTARY_PROFILE (default
# "notary", a `xcrun notarytool store-credentials` keychain profile),
# AFC_BUNDLE_ID (default me.aagedal.FilmConstructor), AFC_SKIP_NOTARIZE=1 to sign only.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
team="${AFC_TEAM_ID:-3R5QGG9DW6}"
profile="${AFC_NOTARY_PROFILE:-notary}"
bundle_id="${AFC_BUNDLE_ID:-me.aagedal.FilmConstructor}"
out="${1:-$repo_root/.local/release}"
mkdir -p "$out"
derived="$(mktemp -d "${TMPDIR:-/private/tmp}/afc-release-build.XXXXXX")"
export PATH="$(dirname "$(xcrun --find swift)"):$PATH"
xcodebuild -quiet -project "$repo_root/Aagedal Film Constructor.xcodeproj" -scheme 'Aagedal Film Constructor' \
  -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "$derived" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM="$team" \
  ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS=--timestamp PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" build
app="$derived/Build/Products/Release/Aagedal Film Constructor.app"
codesign --verify --deep --strict --verbose=2 "$app"
# Notarization rejects get-task-allow (debugging) entitlements.
if codesign -d --entitlements - "$app" 2>/dev/null | grep -q get-task-allow; then
  echo "Signed app still requests get-task-allow" >&2; exit 1
fi
codesign -dvv --entitlements - "$app" 2>&1 | grep -E 'Authority=Developer ID|TeamIdentifier|flags=|app-sandbox'
for helper in ffmpeg ffprobe; do
  codesign -dv "$app/Contents/Resources/Helpers/$helper" 2>&1 | grep -E 'Timestamp=|flags=.*runtime'
done
rm -rf "$out/Aagedal Film Constructor.app"
ditto "$app" "$out/Aagedal Film Constructor.app"
app="$out/Aagedal Film Constructor.app"
if [[ "${AFC_SKIP_NOTARIZE:-0}" == 1 ]]; then echo "Signed (not notarized): $app"; exit 0; fi
zip="$out/Aagedal Film Constructor-notarize.zip"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=4 "$app"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"
final="$out/Aagedal-Film-Constructor-$version.zip"
rm -f "$zip" "$final"
ditto -c -k --keepParent "$app" "$final"
echo "Notarized: $app"
echo "Distribution archive: $final"
