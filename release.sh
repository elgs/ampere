#!/bin/bash
#
# Release script: build app bundle, sign, notarize, publish
#
# Usage: ./release.sh <version>
#   e.g. ./release.sh 1.0.0
#
# Prerequisites:
#   - Xcode with Developer ID certificate
#   - Notarization credentials stored in keychain:
#     xcrun notarytool store-credentials "BatteryManager"
#   - GitHub CLI (gh) authenticated
#   - .project.env in the same directory
#
set -euo pipefail

source "$(dirname "$0")/.project.env"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "Usage: ./release.sh <version>"
    echo "Example: ./release.sh 1.0.0"
    exit 1
fi

SIGN_IDENTITY="$(security find-identity -v -p codesigning | grep "$TEAM_ID" | head -1 | sed 's/.*"\(.*\)"/\1/')"
BUILD_DIR="/tmp/${SCHEME}Build"
APP_DIR="$BUILD_DIR/$SCHEME.app"
DMG_PATH="/tmp/${SCHEME}.dmg"

echo "==> Tagging v$VERSION..."
git tag -f "v$VERSION"

echo "==> Building Release..."
swift build -c release 2>&1

echo "==> Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy binaries
cp .build/release/BatteryManager "$APP_DIR/Contents/MacOS/BatteryManager"
cp .build/release/SMCWriter "$APP_DIR/Contents/MacOS/SMCWriter"

# Write version file
echo "$VERSION" > "$APP_DIR/Contents/Resources/version.txt"

# Create Info.plist
cat > "$APP_DIR/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>BatteryManager</string>
    <key>CFBundleIdentifier</key>
    <string>com.elgs.battery-manager</string>
    <key>CFBundleName</key>
    <string>BatteryManager</string>
    <key>CFBundleDisplayName</key>
    <string>BatteryManager</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> Signing with hardened runtime..."
codesign --force --timestamp --options runtime \
    --sign "$SIGN_IDENTITY" \
    "$APP_DIR/Contents/MacOS/SMCWriter"
codesign --force --timestamp --options runtime \
    --sign "$SIGN_IDENTITY" \
    "$APP_DIR"

echo "==> Verifying signature..."
codesign -dvv "$APP_DIR" 2>&1 | grep -E "Authority|Timestamp"

echo "==> Creating zip for notarization..."
cd "$BUILD_DIR"
rm -f "$SCHEME.zip"
ditto -c -k --keepParent "$SCHEME.app" "$SCHEME.zip"

echo "==> Submitting for notarization..."
xcrun notarytool submit "$SCHEME.zip" \
    --keychain-profile "$SCHEME" \
    --wait

echo "==> Stapling ticket..."
xcrun stapler staple "$APP_DIR"

echo "==> Creating DMG..."
rm -rf "/tmp/${SCHEME}DMG" "$DMG_PATH"
mkdir -p "/tmp/${SCHEME}DMG"
cp -R "$APP_DIR" "/tmp/${SCHEME}DMG/"
ln -s /Applications "/tmp/${SCHEME}DMG/Applications"
hdiutil create -volname "$SCHEME" \
    -srcfolder "/tmp/${SCHEME}DMG" \
    -ov -format UDZO "$DMG_PATH"

SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
echo "==> DMG SHA256: $SHA256"

echo "==> Pushing tag..."
git push origin "v$VERSION" -f

echo "==> Updating GitHub release v$VERSION..."
gh release delete "v$VERSION" --repo "$GITHUB_REPO" --yes 2>/dev/null || true
gh release create "v$VERSION" "$DMG_PATH" \
    --repo "$GITHUB_REPO" \
    --title "v$VERSION" \
    --notes "## $SCHEME v$VERSION

Signed and notarized.

**SHA256:** \`$SHA256\`"

echo "==> Updating Homebrew cask..."
TAP_DIR=$(mktemp -d)
gh repo clone "$HOMEBREW_TAP_REPO" "$TAP_DIR" -- -q
cd "$TAP_DIR"
sed -i '' "s/version \".*\"/version \"$VERSION\"/" "Casks/${GITHUB_REPO#*/}.rb"
sed -i '' "s/sha256 \".*\"/sha256 \"$SHA256\"/" "Casks/${GITHUB_REPO#*/}.rb"
git add "Casks/${GITHUB_REPO#*/}.rb"
git commit -m "Update ${GITHUB_REPO#*/} to v$VERSION"
git push
rm -rf "$TAP_DIR"

echo "==> Updating local tap..."
cd "$(brew --repo elgs/taps)" && git pull -q

echo ""
echo "==> Done! Released v$VERSION"
echo "    GitHub: https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
echo "    Install: brew tap elgs/taps && brew install --cask ${GITHUB_REPO#*/}"
