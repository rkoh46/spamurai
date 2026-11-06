#!/bin/sh
# Builds Callwatch.app and packs it into dist/Callwatch-<version>.dmg for the Releases page.
set -eu
cd "$(dirname "$0")"
VERSION="${1:-1.0}"
STAGE="$(mktemp -d)"
./build.sh "$STAGE" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$STAGE/Callwatch.app/Contents/Info.plist"
KC="$HOME/Library/Application Support/Callwatch/signing.keychain-db"
security unlock-keychain -p callwatch "$KC"
codesign --force --keychain "$KC" --sign "Callwatch Local Signing" "$STAGE/Callwatch.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p dist
rm -f "dist/Callwatch-$VERSION.dmg"
hdiutil create -volname "Callwatch" -srcfolder "$STAGE" -ov -format UDZO "dist/Callwatch-$VERSION.dmg" >/dev/null
echo "dist/Callwatch-$VERSION.dmg"
