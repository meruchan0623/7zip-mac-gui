#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:-$ROOT/build/7zip Mac.app}"
DEST="$HOME/Applications/7zip Mac.app"
"$ROOT/scripts/verify-app.sh" "$SOURCE"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# Migrate only our application identity; backups are outside Applications so
# Launch Services does not advertise two handlers for the same bundle ID.
for PREVIOUS in "$HOME/Applications/SevenZip Mac.app" "$DEST"; do
  [[ -e "$PREVIOUS" ]] || continue
  ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PREVIOUS/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$ID" == local.sevenzip.mac ]] || { echo "Refusing to replace unrelated app: $PREVIOUS" >&2; exit 1; }
  BACKUP_DIR="$HOME/Library/Application Support/7zip Mac/Backups"
  mkdir -p "$BACKUP_DIR"
  BACKUP="$BACKUP_DIR/$(basename "$PREVIOUS").backup-$(date +%Y%m%d-%H%M%S)"
  [[ ! -e "$BACKUP" ]] || { echo "Backup already exists: $BACKUP" >&2; exit 1; }
  "$LSREGISTER" -u "$PREVIOUS" || true
  if [[ -d "$PREVIOUS/Contents/PlugIns/SevenZipFinder.appex" ]]; then
    pluginkit -r "$PREVIOUS/Contents/PlugIns/SevenZipFinder.appex" || true
  fi
  mv "$PREVIOUS" "$BACKUP"
  echo "Previous app preserved: $BACKUP"
done
mkdir -p "$HOME/Applications"
ditto "$SOURCE" "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
/System/Library/CoreServices/pbs -flush
/System/Library/CoreServices/pbs -update
open "$DEST"
echo "Installed $DEST. Finder → Services → 7zip Mac; enable services in Keyboard Shortcuts if needed."
echo "Optional Finder extension: enable explicitly in System Settings → Extensions. Registration is not activation."
pluginkit -m -v -i local.sevenzip.mac.finder || true
