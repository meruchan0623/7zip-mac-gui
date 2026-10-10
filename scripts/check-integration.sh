#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/build"
xcrun swiftc -swift-version 5 -module-name IntegrationCheck "$ROOT/Sources/SevenZipMac/SystemIntegration.swift" "$ROOT/scripts/check-integration.swift" -o "$ROOT/build/check-integration" -framework AppKit
xattr -d com.apple.quarantine "$ROOT/build/check-integration" 2>/dev/null || true
"$ROOT/build/check-integration"
