#!/bin/bash
# Produce a portable local build, retaining the .app's signed resource layout.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/7zip Mac.app}"
"$ROOT/scripts/verify-app.sh" "$APP"
OUT="$ROOT/build/7zip Mac-26.04.2.zip"
TEMP="$(mktemp "$ROOT/build/SevenZipMac-package.XXXXXX")"
trap 'rm -f "$TEMP"' EXIT
ditto -c -k --sequesterRsrc --keepParent "$APP" "$TEMP"
mv "$TEMP" "$OUT"
shasum -a 256 "$OUT" | tee "$OUT.sha256"
echo "Packaged local build: $OUT"
echo "Local ad-hoc signature; this archive has not been notarized by Apple."
