#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/build}"
APP_NAME="Spinoza"
DMG_NAME="SpinozaVoice"
VOLUME_NAME="Spinoza Voice"

# Apple silicon only — no x86_64 slice is produced.
ARCH="arm64"

# Override for machines where /usr/bin/xcodebuild is broken, e.g.
#   XCODEBUILD=/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild ./build_dmg.sh
XCODEBUILD="${XCODEBUILD:-xcodebuild}"

STAGING_DIR="$BUILD_DIR/dmg-staging"
TMP_DMG="$BUILD_DIR/${DMG_NAME}-tmp.dmg"

MOUNT_DIR=""
cleanup() {
    if [ -n "$MOUNT_DIR" ] && [ -d "$MOUNT_DIR" ]; then
        hdiutil detach "$MOUNT_DIR" -quiet -force >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

# ── 1. Build ────────────────────────────────────────────────────────────────
echo "==> Cleaning previous build..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/Release"

echo "==> Building Release for $ARCH..."
"$XCODEBUILD" \
    -project "$PROJECT_DIR/desktop.xcodeproj" \
    -scheme desktop \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -resultBundlePath "$BUILD_DIR/build.xcresult" \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR/Release" \
    ARCHS="$ARCH" \
    ONLY_ACTIVE_ARCH=NO \
    build \
    -quiet

APP_PATH="$BUILD_DIR/Release/$APP_NAME.app"
if [ ! -d "$APP_PATH" ]; then
    echo "❌ Build failed — $APP_NAME.app not found"
    exit 1
fi

# Fail loudly rather than shipping a fat binary by accident.
BINARY_DESC="$(file -b "$APP_PATH/Contents/MacOS/$APP_NAME")"
echo "==> Binary: $BINARY_DESC"
case "$BINARY_DESC" in
    *universal*|*x86_64*)
        echo "❌ Expected an $ARCH-only binary, got: $BINARY_DESC"
        exit 1
        ;;
    *"$ARCH"*) ;;
    *)
        echo "❌ Unrecognised architecture: $BINARY_DESC"
        exit 1
        ;;
esac

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "0.0")"

# Stable asset name on purpose: GitHub's /releases/latest/download/<name>
# redirect only resolves when the filename is identical in every release.
# The version lives in the release tag and title instead.
FINAL_DMG="$BUILD_DIR/${DMG_NAME}-${ARCH}.dmg"
echo "==> Version: $VERSION"

# ── 2. Stage contents ────────────────────────────────────────────────────────
echo "==> Staging DMG contents..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -r "$APP_PATH" "$STAGING_DIR/"
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
# Purely cosmetic: on headless runners Finder may be unavailable, so never
# let this abort the packaging step.
echo "==> Setting Finder window layout..."
if osascript <<APPLESCRIPT
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
then
    echo "   Finder layout applied."
else
    echo "   ⚠️  Finder layout skipped (no GUI session); DMG contents are unaffected."
fi

sync
hdiutil detach "$MOUNT_DIR" -quiet
MOUNT_DIR=""

# ── 5. Convert to compressed read-only DMG ───────────────────────────────────
echo "==> Converting to final compressed DMG..."
rm -f "$FINAL_DMG"
hdiutil convert "$TMP_DMG" \
    -format UDZO \
    -imagekey zlib-level=6 \
    -o "$FINAL_DMG"

rm -f "$TMP_DMG"
rm -rf "$STAGING_DIR"

echo ""
echo "✅ Done! DMG at:"
echo "   $FINAL_DMG"
echo ""
echo "Size: $(du -h "$FINAL_DMG" | cut -f1)"
