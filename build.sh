#!/bin/sh
# Builds Callwatch.app (Apple silicon and Intel) into ~/Applications, or into the folder given as $1.
# Needs Xcode (the Command Line Tools alone cannot build SwiftUI).
set -eu
cd "$(dirname "$0")"
DEST="${1:-$HOME/Applications}"
APP="$DEST/Callwatch.app"
XCODE="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[ -d "$XCODE" ] || { echo "Callwatch needs Xcode to build. Install it from the App Store, then run this again."; exit 1; }
BUILD="$(mktemp -d)"
for ARCH in arm64 x86_64; do
  DEVELOPER_DIR="$XCODE" xcrun swiftc -O -swift-version 5 -target "$ARCH-apple-macos14.0" \
    -parse-as-library -o "$BUILD/Callwatch-$ARCH" Sources/*.swift -lsqlite3
done
lipo -create "$BUILD/Callwatch-arm64" "$BUILD/Callwatch-x86_64" -output "$BUILD/Callwatch"
# Replacing the installed copy: quit it first. Builds into another folder leave the running app alone.
[ "$DEST" = "$HOME/Applications" ] && { osascript -e 'tell application id "com.callwatch.app" to quit' >/dev/null 2>&1 || true; }
launchctl bootout "gui/$(id -u)/com.callwatch.agent" 2>/dev/null || true
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/Callwatch" "$APP/Contents/MacOS/Callwatch"
ICONSET="$BUILD/Callwatch.iconset"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2)); sips -z $d $d Resources/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Callwatch.icns"
cat > "$APP/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.callwatch.app</string>
<key>CFBundleName</key><string>Callwatch</string>
<key>CFBundleDisplayName</key><string>Callwatch</string>
<key>CFBundleExecutable</key><string>Callwatch</string>
<key>CFBundleIconFile</key><string>Callwatch</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Callwatch sends you an iMessage when an unknown number calls, so you can answer from your iPhone.</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
P
# Sign with a certificate made once on this Mac, so macOS sees every rebuild as the same app and keeps
# its Full Disk Access. The certificate lives in its own keychain file and is not trusted for anything else.
KC="$HOME/Library/Application Support/Callwatch/signing.keychain-db"
IDENT="Callwatch Local Signing"
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
    -out "$BUILD/id.p12" -passout pass:callwatch >/dev/null 2>&1
  security create-keychain -p callwatch "$KC"
  security set-keychain-settings "$KC"
  security import "$BUILD/id.p12" -k "$KC" -P callwatch -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s -k callwatch "$KC" >/dev/null 2>&1
  rm -f "$BUILD/key.pem" "$BUILD/id.p12"
fi
security unlock-keychain -p callwatch "$KC"
codesign --force --keychain "$KC" --sign "$IDENT" "$APP"
rm -f "$HOME/Library/LaunchAgents/com.callwatch.agent.plist"   # earlier versions started at login this way; Setup has a switch now
echo "built $APP"
