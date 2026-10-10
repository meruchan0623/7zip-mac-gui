#!/bin/bash
# Build the upstream, unmodified native macOS implementation of 7-Zip.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REF=9128b80e3a471108678e2b3ec3c985861c8d7b0f
SRC="$ROOT/Vendor/7zip"
OUT="$ROOT/build/native-engine"
ARCHS=("$(uname -m)")
if [[ "${1:-}" == "--universal" ]]; then ARCHS=(arm64 x86_64)
elif [[ -n "${1:-}" ]]; then echo "Usage: $0 [--universal]" >&2; exit 2; fi
if [[ ! -d "$SRC/.git" ]]; then
  git clone --depth 1 --branch 26.04 https://github.com/ip7z/7zip.git "$SRC"
fi
if [[ "$(git -C "$SRC" rev-parse HEAD)" != "$REF" ]]; then
  echo "Upstream checkout does not match pinned 7-Zip 26.04 revision $REF" >&2; exit 1
fi
git -C "$SRC" diff --exit-code --quiet
git -C "$SRC" diff --cached --exit-code --quiet
mkdir -p "$OUT"
export MACOSX_DEPLOYMENT_TARGET=13.0
for arch in "${ARCHS[@]}"; do
  if [[ "$arch" == arm64 ]]; then variant=arm64; else variant=x64; fi
  echo "Building official 7-Zip 26.04 for $arch ($REF)"
  (
    cd "$SRC/CPP/7zip/Bundles/Alone2"
    make -j6 -f "../../cmpl_mac_${variant}.mak"
    cp "b/m_${variant}/7zz" "$OUT/7zz-$arch"
  )
done
if [[ "${#ARCHS[@]}" == 2 ]]; then
  lipo -create "$OUT/7zz-arm64" "$OUT/7zz-x86_64" -output "$OUT/7zz"
else cp "$OUT/7zz-${ARCHS[0]}" "$OUT/7zz"; fi
chmod 755 "$OUT/7zz"
codesign --force --sign - "$OUT/7zz"
cat > "$OUT/SOURCE.txt" <<EOF
7-Zip 26.04 native macOS engine
Copyright (C) 1999-2026 Igor Pavlov
Repository: https://github.com/ip7z/7zip
Source: https://github.com/ip7z/7zip/tree/26.04
Revision: $REF
Sources unmodified. Built with the upstream macOS makefiles.
Architectures: ${ARCHS[*]}
macOS deployment target: $MACOSX_DEPLOYMENT_TARGET
License: GNU LGPL, BSD portions, and unRAR restriction; see License.txt.
EOF
file "$OUT/7zz"
"$OUT/7zz" i
echo "Native upstream engine: $OUT/7zz"
