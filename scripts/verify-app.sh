#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/7zip Mac.app}"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP"
test -x "$APP/Contents/MacOS/SevenZipMac"
test -x "$APP/Contents/Resources/7zz"
test -f "$APP/Contents/Resources/MANUAL/start.htm"
test -f "$APP/Contents/Resources/License.txt"
test -f "$APP/Contents/Resources/Localization/zh-Hans.json"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP/Contents/Info.plist")" == "7zip Mac" ]]
test -f "$APP/Contents/Resources/Upstream/SOURCE.txt"
test -f "$APP/Contents/Resources/Upstream/LGPL-2.1.txt"
cmp "$ROOT/Vendor/7zip/DOC/copying.txt" "$APP/Contents/Resources/Upstream/LGPL-2.1.txt"
cmp "$ROOT/7zz" "$APP/Contents/Resources/Upstream/7zz"
shasum -a 256 "$ROOT/7zz" "$APP/Contents/Resources/Upstream/7zz"
lipo -archs "$APP/Contents/MacOS/SevenZipMac"
lipo -archs "$APP/Contents/Resources/7zz"
ENGINE_INFO="$("$APP/Contents/Resources/7zz" i)"
printf '%s\n' "$ENGINE_INFO" | sed -n '1,20p'
if [[ -d "$APP/Contents/PlugIns/SevenZipFinder.appex" ]]; then
  plutil -lint "$APP/Contents/PlugIns/SevenZipFinder.appex/Contents/Info.plist"
  codesign --verify --strict --verbose=2 "$APP/Contents/PlugIns/SevenZipFinder.appex"
  nm -g "$APP/Contents/PlugIns/SevenZipFinder.appex/Contents/MacOS/SevenZipFinder" | rg 'SevenZipFinderSync|NSExtensionMain'
fi
