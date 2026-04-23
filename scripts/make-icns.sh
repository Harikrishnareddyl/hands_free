#!/usr/bin/env bash
# Generate HandsFree/Resources/AppIcon.icns and docs/logo.png from the
# Swift icon generator.
set -euo pipefail

cd "$(dirname "$0")/.."

WORK=scripts/.icon-build
BASE="$WORK/icon_1024.png"
ICONSET="$WORK/AppIcon.iconset"
DEST_ICNS="HandsFree/Resources/AppIcon.icns"
DEST_LOGO="docs/logo.png"

mkdir -p "$WORK" docs HandsFree/Resources

echo "→ Rendering 1024×1024 base"
swift scripts/make-icon.swift "$BASE"

echo "→ Building iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
sips -z 16   16   "$BASE" --out "$ICONSET/icon_16x16.png"       >/dev/null
sips -z 32   32   "$BASE" --out "$ICONSET/icon_16x16@2x.png"    >/dev/null
sips -z 32   32   "$BASE" --out "$ICONSET/icon_32x32.png"       >/dev/null
sips -z 64   64   "$BASE" --out "$ICONSET/icon_32x32@2x.png"    >/dev/null
sips -z 128  128  "$BASE" --out "$ICONSET/icon_128x128.png"     >/dev/null
sips -z 256  256  "$BASE" --out "$ICONSET/icon_128x128@2x.png"  >/dev/null
sips -z 256  256  "$BASE" --out "$ICONSET/icon_256x256.png"     >/dev/null
sips -z 512  512  "$BASE" --out "$ICONSET/icon_256x256@2x.png"  >/dev/null
sips -z 512  512  "$BASE" --out "$ICONSET/icon_512x512.png"     >/dev/null
cp "$BASE" "$ICONSET/icon_512x512@2x.png"

echo "→ iconutil → $DEST_ICNS"
iconutil -c icns "$ICONSET" -o "$DEST_ICNS"

echo "→ README logo → $DEST_LOGO"
sips -z 512 512 "$BASE" --out "$DEST_LOGO" >/dev/null

echo ""
echo "✓ Icon assets built."
ls -lh "$DEST_ICNS" "$DEST_LOGO"
