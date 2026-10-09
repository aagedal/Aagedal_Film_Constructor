#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="${TMPDIR:-/private/tmp}/aagedal-film-constructor-verification"
mkdir -p "$build_root/module-cache"
export CLANG_MODULE_CACHE_PATH="$build_root/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_root/module-cache"
python3 -m unittest discover -s "$repo_root/scripts" -p 'test_*.py'
swift test --package-path "$repo_root/Packages/EditorCore" \
  --scratch-path "$build_root/editor-core" --cache-path "$build_root/package-cache" --disable-sandbox
xcodebuild -project "$repo_root/Aagedal Film Constructor.xcodeproj" \
  -scheme 'Aagedal Film Constructor' -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$build_root/app" \
  -packageCachePath "$build_root/package-cache" \
  CLANG_MODULE_CACHE_PATH="$build_root/module-cache" CODE_SIGNING_ALLOWED=NO build
