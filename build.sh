#!/bin/sh
# Builds Spamurai.app (Apple silicon and Intel) into ~/Applications, or into the folder given as $1.
# Needs Xcode (the Command Line Tools alone cannot build SwiftUI).
set -eu
cd "$(dirname "$0")"
DEST="${1:-$HOME/Applications}"
APP="$DEST/Spamurai.app"
XCODE="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[ -d "$XCODE" ] || { echo "Spamurai needs Xcode to build. Install it from the App Store, then run this again."; exit 1; }
BUILD="$(mktemp -d)"
for ARCH in arm64 x86_64; do
  DEVELOPER_DIR="$XCODE" xcrun swiftc -O -swift-version 5 -target "$ARCH-apple-macos14.0" \
    -parse-as-library -o "$BUILD/Spamurai-$ARCH" Sources/*.swift -lsqlite3
done
lipo -create "$BUILD/Spamurai-arm64" "$BUILD/Spamurai-x86_64" -output "$BUILD/Spamurai"
# Replacing the installed copy: quit it first. Builds into another folder leave the running app alone.
[ "$DEST" = "$HOME/Applications" ] && { osascript -e 'tell application id "com.spamurai.app" to quit' >/dev/null 2>&1 || true; }
launchctl bootout "gui/$(id -u)/com.spamurai.agent" 2>/dev/null || true
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/Spamurai" "$APP/Contents/MacOS/Spamurai"
ICONSET="$BUILD/Spamurai.iconset"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2)); sips -z $d $d Resources/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Spamurai.icns"
cat > "$APP/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.spamurai.app</string>
<key>CFBundleName</key><string>Spamurai</string>
<key>CFBundleDisplayName</key><string>Spamurai</string>
<key>CFBundleExecutable</key><string>Spamurai</string>
<key>CFBundleIconFile</key><string>Spamurai</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.2</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Spamurai sends you an iMessage when an unknown number calls, so you can answer from your iPhone.</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
P
# Sign with a certificate made once on this Mac, so macOS sees every rebuild as the same app and keeps
# its Full Disk Access. The certificate lives in its own keychain file and is not trusted for anything else.
KC="$HOME/Library/Application Support/Spamurai/signing.keychain-db"
IDENT="Spamurai Local Signing"
if ! security find-certificate -c "$IDENT" "$KC" >/dev/null 2>&1; then
  mkdir -p "$(dirname "$KC")"; rm -f "$KC"
  cat > "$BUILD/cert.cnf" <<C
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $IDENT
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
C
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$BUILD/cert.cnf" \
    -keyout "$BUILD/key.pem" -out "$BUILD/cert.pem" >/dev/null 2>&1
  /usr/bin/openssl pkcs12 -export -inkey "$BUILD/key.pem" -in "$BUILD/cert.pem" -name "$IDENT" \
    -out "$BUILD/id.p12" -passout pass:spamurai >/dev/null 2>&1
  security create-keychain -p spamurai "$KC"
  security set-keychain-settings "$KC"
  security import "$BUILD/id.p12" -k "$KC" -P spamurai -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s -k spamurai "$KC" >/dev/null 2>&1
  rm -f "$BUILD/key.pem" "$BUILD/id.p12"
fi
security unlock-keychain -p spamurai "$KC"
codesign --force --keychain "$KC" --sign "$IDENT" "$APP"
rm -f "$HOME/Library/LaunchAgents/com.spamurai.agent.plist"   # earlier versions started at login this way; Setup has a switch now
echo "built $APP"
