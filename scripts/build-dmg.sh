#!/usr/bin/env bash
# Build a Release .dmg of HandsFree.
#
# Usage:
#   ./scripts/build-dmg.sh            # builds with whatever project.yml says
#   SIGN_IDENTITY=- ./scripts/build-dmg.sh   # force ad-hoc (useful in CI)
#
# Optional notarization (requires a paid Apple Developer account):
#   APPLE_ID=you@example.com \
#   APPLE_TEAM_ID=XXXXXXXXXX \
#   APPLE_APP_PASSWORD=abcd-efgh-ijkl-mnop \
#   SIGN_IDENTITY="Developer ID Application: You (XXXXXXXXXX)" \
#   ./scripts/build-dmg.sh

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(grep CFBundleShortVersionString project.yml | head -1 | sed 's/.*"\([^"]*\)".*/\1/' || echo '0.1.0')}"
SIGN_IDENTITY="${SIGN_IDENTITY:-HandsFree Dev}"
BUILD_DIR=".build"
STAGE_DIR=".build/dmg-staging"
APP_PATH=".build/Build/Products/Release/HandsFree.app"
DMG_PATH="HandsFree-${VERSION}.dmg"

echo "→ Environment"
echo "  xcodegen:  $(xcodegen --version 2>&1 | head -1)"
echo "  xcodebuild: $(xcodebuild -version 2>&1 | head -1)"
echo "  pwd:       $(pwd)"

echo "→ Regenerating Xcode project"
xcodegen generate
if [ ! -d HandsFree.xcodeproj ]; then
    echo "✗ xcodegen did not produce HandsFree.xcodeproj"
    exit 1
fi

echo "→ Resolving Swift packages"
xcodebuild -project HandsFree.xcodeproj -scheme HandsFree \
    -resolvePackageDependencies 2>&1 | tail -3 || true

echo "→ Building Release (will sign separately)"
mkdir -p "$BUILD_DIR"
set +e
xcodebuild \
  -project HandsFree.xcodeproj \
  -scheme HandsFree \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tee "$BUILD_DIR/build.log" | grep -E "(error:|warning:|BUILD )" | grep -v "Metadata extraction" || true
BUILD_STATUS=${PIPESTATUS[0]}
set -e

if [ ! -d "$APP_PATH" ]; then
    echo "✗ Build failed (xcodebuild exit=$BUILD_STATUS) — $APP_PATH not found"
    echo "  last 40 lines of build log:"
    tail -40 "$BUILD_DIR/build.log" 2>/dev/null || true
    exit 1
fi

echo "→ Signing app (identity: $SIGN_IDENTITY)"
# Without --entitlements, the signed binary inherits ZERO entitlements and
# hardened runtime blocks mic/camera/etc silently. Pass our entitlements
# plist so com.apple.security.device.audio-input actually reaches the binary.
ENTITLEMENTS="HandsFree/HandsFree.entitlements"
if [ ! -f "$ENTITLEMENTS" ]; then
    echo "✗ Entitlements file missing at $ENTITLEMENTS"
    exit 1
fi
codesign --force --deep --sign "$SIGN_IDENTITY" --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" "$APP_PATH"

echo "→ Verifying embedded entitlements"
codesign -d --entitlements - "$APP_PATH" 2>&1 | grep -q "audio-input" && \
    echo "  ✓ com.apple.security.device.audio-input present" || \
    (echo "  ✗ audio-input entitlement NOT present after signing"; exit 1)

echo "→ Verifying code signature"
codesign --verify --strict --verbose=2 "$APP_PATH" 2>&1 | tail -3 || true
codesign -dv "$APP_PATH" 2>&1 | grep -E "(Identifier|Authority|Signature)" || true

echo "→ Creating DMG"
rm -f "$DMG_PATH"

if command -v create-dmg >/dev/null 2>&1; then
    # Pretty DMG with a drag-to-Applications layout. Window is 560×380,
    # icons at fixed positions, finder sidebar hidden.
    create-dmg \
      --volname "HandsFree" \
      --window-pos 200 120 \
      --window-size 560 380 \
      --icon-size 96 \
      --icon "HandsFree.app" 150 180 \
      --hide-extension "HandsFree.app" \
      --app-drop-link 410 180 \
      --no-internet-enable \
      --hdiutil-quiet \
      "$DMG_PATH" \
      "$APP_PATH" >/dev/null 2>&1 || {
        echo "  create-dmg failed; falling back to plain hdiutil"
        rm -rf "$STAGE_DIR"
        mkdir -p "$STAGE_DIR"
        cp -R "$APP_PATH" "$STAGE_DIR/"
        ln -s /Applications "$STAGE_DIR/Applications"
        hdiutil create -volname "HandsFree" -srcfolder "$STAGE_DIR" \
            -ov -format UDZO -fs HFS+ "$DMG_PATH" >/dev/null
    }
else
    echo "  create-dmg not installed — producing plain DMG (brew install create-dmg for nice layout)"
    rm -rf "$STAGE_DIR"
    mkdir -p "$STAGE_DIR"
    cp -R "$APP_PATH" "$STAGE_DIR/"
    ln -s /Applications "$STAGE_DIR/Applications"
    hdiutil create -volname "HandsFree" -srcfolder "$STAGE_DIR" \
        -ov -format UDZO -fs HFS+ "$DMG_PATH" >/dev/null
fi

echo "→ Signing DMG"
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH" || \
  echo "  (codesign on DMG failed — self-signed certs can't always sign DMGs; the .app inside is still signed)"

if [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
    echo "→ Submitting to Apple notary service"
    xcrun notarytool submit "$DMG_PATH" \
      --apple-id "$APPLE_ID" \
      --team-id "$APPLE_TEAM_ID" \
      --password "$APPLE_APP_PASSWORD" \
      --wait
    echo "→ Stapling notarization ticket"
    xcrun stapler staple "$DMG_PATH"
    echo "→ Verifying"
    spctl -a -t open --context context:primary-signature -v "$DMG_PATH" || true
else
    echo "→ Skipping notarization (APPLE_ID / APPLE_TEAM_ID / APPLE_APP_PASSWORD not set)"
    echo "  Recipients will see 'unidentified developer' on first launch."
    echo "  They can right-click the app → Open → Open again to bypass."
fi

rm -rf "$STAGE_DIR"

size=$(du -h "$DMG_PATH" | cut -f1)
echo ""
echo "✓ Built $DMG_PATH ($size)"
