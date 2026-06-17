#!/usr/bin/env bash
#
# Build GitCheckerBar (SPM executable) and wrap it in a proper macOS .app bundle
# so it can be a menu bar agent (no Dock icon) and register as a login item.
# Output: clients/menubar/build/GitCheckerBar.app

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$DIR/build/GitCheckerBar.app"
EXE_NAME="GitCheckerBar"

echo "==> swift build -c release"
( cd "$DIR" && swift build -c release )

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$DIR/.build/release/$EXE_NAME" "$APP/Contents/MacOS/$EXE_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>GitCheckerBar</string>
    <key>CFBundleDisplayName</key>     <string>GitCheckerBar</string>
    <key>CFBundleIdentifier</key>      <string>com.user.gitcheckerbar</string>
    <key>CFBundleExecutable</key>      <string>$EXE_NAME</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <!-- Agent app: lives in the menu bar, no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key>             <true/>
</dict>
</plist>
PLIST

echo "==> Ad-hoc code signing"
# Ad-hoc (-) signature: enough for local use and for SMAppService login-item
# registration on this machine. Replace with a Developer ID to distribute.
codesign --force --sign - --timestamp=none "$APP"

echo "✅ Built $APP"
