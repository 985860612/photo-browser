#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PHOTO_BUILD_ARGS=(-c release)
if [ -n "${PHOTO_BROWSER_BUILD_PATH:-}" ]; then PHOTO_BUILD_ARGS+=(--scratch-path "$PHOTO_BROWSER_BUILD_PATH"); fi
APP_PATH="$PWD/dist/照片浏览器.app"
PHOTO_SETTINGS="$PWD/scripts/app-settings.plist"
PHOTO_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :Version' "$PHOTO_SETTINGS")
PHOTO_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :Build' "$PHOTO_SETTINGS")
PHOTO_FEED=$(/usr/libexec/PlistBuddy -c 'Print :FeedURL' "$PHOTO_SETTINGS")
PHOTO_PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c 'Print :PublicEDKey' "$PHOTO_SETTINGS")
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$APP_PATH/Contents/Frameworks"
if [ "${PHOTO_BROWSER_UNIVERSAL:-0}" = "1" ]; then
  PHOTO_BINARIES=()
  for PHOTO_ARCH in arm64 x86_64; do
    swift build "${PHOTO_BUILD_ARGS[@]}" --product PhotoBrowser --triple "$PHOTO_ARCH-apple-macosx14.0"
    PHOTO_BINARY_DIR=$(swift build "${PHOTO_BUILD_ARGS[@]}" --triple "$PHOTO_ARCH-apple-macosx14.0" --show-bin-path)
    PHOTO_BINARIES+=("$PHOTO_BINARY_DIR/PhotoBrowser")
  done
  lipo -create "${PHOTO_BINARIES[@]}" -output "$APP_PATH/Contents/MacOS/PhotoBrowser"
else
  swift build "${PHOTO_BUILD_ARGS[@]}" --product PhotoBrowser
  PHOTO_BINARY_DIR=$(swift build "${PHOTO_BUILD_ARGS[@]}" --show-bin-path)
  cp "$PHOTO_BINARY_DIR/PhotoBrowser" "$APP_PATH/Contents/MacOS/PhotoBrowser"
fi
ditto "$PHOTO_BINARY_DIR/PhotoBrowser_BrowserCore.bundle" "$APP_PATH/Contents/Resources/PhotoBrowser_BrowserCore.bundle"
PHOTO_SPARKLE_ROOT="${PHOTO_BROWSER_BUILD_PATH:-$PWD/.build}/artifacts/sparkle/Sparkle"
ditto "$PHOTO_SPARKLE_ROOT/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$APP_PATH/Contents/Frameworks/Sparkle.framework"
cp "$PHOTO_SPARKLE_ROOT/LICENSE" "$APP_PATH/Contents/Resources/Sparkle-LICENSE"
ditto scripts/Resources "$APP_PATH/Contents/Resources"
cp LICENSE "$APP_PATH/Contents/Resources/LICENSE"
cat > "$APP_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PhotoBrowser</string>
<key>CFBundleIdentifier</key><string>local.wxj.PhotoBrowser</string>
<key>CFBundleName</key><string>照片浏览器</string>
<key>CFBundleDisplayName</key><string>照片浏览器</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0</string>
<key>CFBundleVersion</key><string>0</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>SUEnableAutomaticChecks</key><true/>
<key>SUAutomaticallyUpdate</key><false/>
<key>SUScheduledCheckInterval</key><integer>86400</integer>
<key>SUVerifyUpdateBeforeExtraction</key><true/>
<key>SURequireSignedFeed</key><true/>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $PHOTO_VERSION" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $PHOTO_BUILD" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SUFeedURL string $PHOTO_FEED" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $PHOTO_PUBLIC_KEY" "$APP_PATH/Contents/Info.plist"
swift scripts/create-icon.swift "$PWD/.build/AppIcon.iconset"
iconutil -c icns "$PWD/.build/AppIcon.iconset" -o "$APP_PATH/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP_PATH/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
printf '%s\n' "$APP_PATH"
