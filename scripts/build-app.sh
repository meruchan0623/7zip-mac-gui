#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
UNIVERSAL=0
FINDER=0
for option in "$@"; do
  case "$option" in --universal) UNIVERSAL=1;; --finder-extension) FINDER=1;; *) echo "Usage: $0 [--universal] [--finder-extension]" >&2; exit 2;; esac
done
if [[ "$UNIVERSAL" == 1 ]]; then "$ROOT/scripts/build-engine.sh" --universal
else "$ROOT/scripts/build-engine.sh"; fi
APP="$ROOT/build/7zip Mac.app"
if [[ -e "$APP" && ! -f "$APP/Contents/Info.plist" ]]; then echo "Refusing to replace unexpected build path: $APP" >&2; exit 1; fi
python3 scripts/make-plists.py
ARCHS=("$(uname -m)")
if [[ "$UNIVERSAL" == 1 ]]; then ARCHS=(arm64 x86_64); fi
mkdir -p "$ROOT/build"
BINARIES=()
for arch in "${ARCHS[@]}"; do
  swift build --build-system native -c release --arch "$arch"
  BINPATH="$(swift build --build-system native -c release --arch "$arch" --show-bin-path)"
  cp "$BINPATH/SevenZipMac" "$ROOT/build/SevenZipMac-$arch"
  BINARIES+=("$ROOT/build/SevenZipMac-$arch")
done
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Upstream"
if [[ "$UNIVERSAL" == 1 ]]; then lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/SevenZipMac"; else cp "${BINARIES[0]}" "$APP/Contents/MacOS/SevenZipMac"; fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/Localization "$APP/Contents/Resources/Localization"
cp -X 7zz "$APP/Contents/Resources/Upstream/7zz"
cp -X build/native-engine/7zz "$APP/Contents/Resources/7zz"
cp build/native-engine/SOURCE.txt "$APP/Contents/Resources/Upstream/SOURCE.txt"
cp Vendor/7zip/DOC/copying.txt "$APP/Contents/Resources/Upstream/LGPL-2.1.txt"
cp Vendor/7zip/DOC/License.txt "$APP/Contents/Resources/Upstream/Source-License.txt"
cp Vendor/7zip/DOC/unRarLicense.txt "$APP/Contents/Resources/Upstream/unRarLicense.txt"
chmod 755 "$APP/Contents/Resources/7zz"
cp -R MANUAL "$APP/Contents/Resources/MANUAL"
cp License.txt History.txt readme.txt Resources/ATTRIBUTION.txt "$APP/Contents/Resources/"
mkdir -p build/AppIcon.iconset
xcrun swift scripts/make-icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP/Contents/Resources/7zz"
if [[ "$FINDER" == 1 ]]; then
  EXT="$APP/Contents/PlugIns/SevenZipFinder.appex"
  mkdir -p "$EXT/Contents/MacOS" "$EXT/Contents/Resources"
  cp -R Resources/Localization "$EXT/Contents/Resources/Localization"
  EXTBINS=()
  for arch in "${ARCHS[@]}"; do
    OUT="$ROOT/build/SevenZipFinder-$arch"
    xcrun swiftc -swift-version 5 -O -sdk "$(xcrun --show-sdk-path)" -target "$arch-apple-macos13.0" -module-name SevenZipFinder -parse-as-library -Xlinker -e -Xlinker _NSExtensionMain FinderExtension/FinderSync.swift -o "$OUT" -framework AppKit -framework FinderSync
    EXTBINS+=("$OUT")
  done
  if [[ "$UNIVERSAL" == 1 ]]; then lipo -create "${EXTBINS[@]}" -output "$EXT/Contents/MacOS/SevenZipFinder"; else cp "${EXTBINS[0]}" "$EXT/Contents/MacOS/SevenZipFinder"; fi
  cp FinderExtension/Info.plist "$EXT/Contents/Info.plist"
  codesign --force --sign - --entitlements FinderExtension/Entitlements.plist "$EXT"
fi
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
codesign --force --sign - "$APP"
"$ROOT/scripts/verify-app.sh" "$APP"
echo "Built: $APP (local ad-hoc signature)"
