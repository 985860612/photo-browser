#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PHOTO_CHECK_ARGS=(--package-path "$PWD")
if [ -n "${PHOTO_BROWSER_BUILD_PATH:-}" ]; then PHOTO_CHECK_ARGS+=(--scratch-path "$PHOTO_BROWSER_BUILD_PATH"); fi
swift build "${PHOTO_CHECK_ARGS[@]}" --product PhotoBrowser
PHOTO_BIN=$(swift build "${PHOTO_CHECK_ARGS[@]}" --show-bin-path)
swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" -I "$PHOTO_BIN/Modules" -F "$PHOTO_BIN" -framework Sparkle \
  -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' -Xlinker -rpath -Xlinker "$PHOTO_BIN" \
  Sources/PhotoBrowser/App/AppUpdater.swift Tests/BrowserUpdateChecks/*.swift \
  "$PHOTO_BIN"/BrowserCore.build/*.swift.o -o "$PHOTO_BIN/UpdaterChecks"
"$PHOTO_BIN/UpdaterChecks"
if [ "$#" -eq 0 ]; then exit 0; fi
PHOTO_APP="$1"
codesign --verify --deep --strict "$PHOTO_APP"
PHOTO_PLIST="$PHOTO_APP/Contents/Info.plist"
PHOTO_FEED=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$PHOTO_PLIST")
case "$PHOTO_FEED" in https://*) ;; *) echo 'Update feed must use HTTPS' >&2; exit 1 ;; esac
test "$(/usr/libexec/PlistBuddy -c 'Print :SURequireSignedFeed' "$PHOTO_PLIST")" = true
test "$(/usr/libexec/PlistBuddy -c 'Print :SUVerifyUpdateBeforeExtraction' "$PHOTO_PLIST")" = true
test "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PHOTO_PLIST")" = "$(/usr/libexec/PlistBuddy -c 'Print :PublicEDKey' scripts/app-settings.plist)"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PHOTO_PLIST")" = "$(/usr/libexec/PlistBuddy -c 'Print :Build' scripts/app-settings.plist)"
test -x "$PHOTO_APP/Contents/Frameworks/Sparkle.framework/Autoupdate"
test -x "$PHOTO_APP/Contents/Frameworks/Sparkle.framework/Updater.app/Contents/MacOS/Updater"
PHOTO_CHECK_ROOT=$(mktemp -d)
PHOTO_TEST_ID="local.wxj.PhotoBrowser.UpdateChecks.$RANDOM.$RANDOM"
trap 'defaults delete "$PHOTO_TEST_ID" 2>/dev/null || true; rm -rf "$PHOTO_CHECK_ROOT"' EXIT
PHOTO_CHECK_APP="$PHOTO_CHECK_ROOT/UpdaterChecks.app"
ditto "$PHOTO_APP" "$PHOTO_CHECK_APP"
cp "$PHOTO_BIN/UpdaterChecks" "$PHOTO_CHECK_APP/Contents/MacOS/PhotoBrowser"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $PHOTO_TEST_ID" "$PHOTO_CHECK_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :SUEnableAutomaticChecks false' "$PHOTO_CHECK_APP/Contents/Info.plist"
codesign --force --sign - "$PHOTO_CHECK_APP"
"$PHOTO_CHECK_APP/Contents/MacOS/PhotoBrowser"
