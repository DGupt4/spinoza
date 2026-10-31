#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="Spinoza"
DMG_NAME="SpinozaVoice"
VOLUME_NAME="Spinoza Voice"
STAGING_DIR="$BUILD_DIR/dmg-staging"
TMP_DMG="$BUILD_DIR/${DMG_NAME}-tmp.dmg"
FINAL_DMG="$BUILD_DIR/${DMG_NAME}.dmg"

# ── 1. Build ────────────────────────────────────────────────────────────────
echo "==> Cleaning previous build..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/Release"

echo "==> Building Release..."
xcodebuild \
    -project "$PROJECT_DIR/desktop.xcodeproj" \
    -scheme desktop \
    -configuration Release \
    -destination 'platform=macOS' \
    build \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR/Release" \
    2>&1 | tail -5

if [ ! -d "$BUILD_DIR/Release/$APP_NAME.app" ]; then
    echo "❌ Build failed — $APP_NAME.app not found"
    exit 1
fi

# ── 2. Stage contents ────────────────────────────────────────────────────────
echo "==> Staging DMG contents..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -r "$BUILD_DIR/Release/$APP_NAME.app" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

# ── 3. Create a read-write DMG directly from staging folder ──────────────────
echo "==> Creating temporary RW DMG..."
hdiutil create \
    -srcfolder "$STAGING_DIR" \
    -volname "$VOLUME_NAME" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,b=16" \
    -format UDRW \
    -ov \
    "$TMP_DMG"

echo "==> Mounting RW DMG..."
MOUNT_DIR=$(hdiutil attach -readwrite -noverify -noautoopen "$TMP_DMG" \
    | sed -n 's|.*\(/Volumes/.*\)|\1|p' | tail -1)

echo "   Mounted at: $MOUNT_DIR"

# ── 4. Set Finder window layout via AppleScript ──────────────────────────────
echo "==> Setting Finder window layout..."
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {400, 100, 920, 420}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set position of item "$APP_NAME.app" of container window to {150, 165}
        set position of item "Applications" of container window to {370, 165}
        update without registering applications
        close
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_DIR" -quiet

# ── 5. Convert to compressed read-only DMG ───────────────────────────────────
echo "==> Converting to final compressed DMG..."
rm -f "$FINAL_DMG"
hdiutil convert "$TMP_DMG" \
    -format UDZO \
    -imagekey zlib-level=6 \
    -o "$FINAL_DMG"

rm -f "$TMP_DMG"

echo ""
echo "✅ Done! DMG at:"
echo "   $FINAL_DMG"
echo ""
echo "Size: $(du -h "$FINAL_DMG" | cut -f1)"
