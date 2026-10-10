#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ ! -x "$ROOT/build/native-engine/7zz" ]]; then "$ROOT/scripts/build-engine.sh"; fi
export SEVENZIP_BINARY="$ROOT/build/native-engine/7zz"
FRAMEWORKS="$(xcode-select -p)/Library/Developer/Frameworks"
if [[ -d "$FRAMEWORKS/Testing.framework" ]]; then
  swift test --build-system native --disable-xctest --enable-swift-testing -Xswiftc "-F$FRAMEWORKS" -Xlinker -rpath -Xlinker "$FRAMEWORKS" "$@"
else
  swift test --build-system native --disable-xctest --enable-swift-testing "$@"
fi
"$ROOT/scripts/check-integration.sh"
