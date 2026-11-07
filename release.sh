#!/bin/sh
# Builds Spamurai.app and packs it into dist/Spamurai-<version>.dmg for the Releases page.
set -eu
cd "$(dirname "$0")"
VERSION="${1:-2.2}"
STAGE="$(mktemp -d)"
./build.sh "$STAGE" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$STAGE/Spamurai.app/Contents/Info.plist"
KC="$HOME/Library/Application Support/Spamurai/signing.keychain-db"
security unlock-keychain -p spamurai "$KC"
codesign --force --keychain "$KC" --sign "Spamurai Local Signing" "$STAGE/Spamurai.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p dist
rm -f "dist/Spamurai-$VERSION.dmg"
hdiutil create -volname "Spamurai" -srcfolder "$STAGE" -ov -format UDZO "dist/Spamurai-$VERSION.dmg" >/dev/null
echo "dist/Spamurai-$VERSION.dmg"
