#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product PhotoBrowser
APP_PATH="$PWD/dist/照片组浏览器.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp .build/release/PhotoBrowser "$APP_PATH/Contents/MacOS/PhotoBrowser"
cat > "$APP_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PhotoBrowser</string>
<key>CFBundleIdentifier</key><string>local.wxj.PhotoBrowser</string>
<key>CFBundleName</key><string>照片组浏览器</string>
<key>CFBundleDisplayName</key><string>照片组浏览器</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.1</string>
<key>CFBundleVersion</key><string>4</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
swift scripts/create-icon.swift "$PWD/.build/AppIcon.iconset"
iconutil -c icns "$PWD/.build/AppIcon.iconset" -o "$APP_PATH/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP_PATH"
printf '%s\n' "$APP_PATH"
