#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PHOTO_CHECK_ARGS=(--package-path "$PWD")
if [ -n "${PHOTO_BROWSER_BUILD_PATH:-}" ]; then PHOTO_CHECK_ARGS+=(--scratch-path "$PHOTO_BROWSER_BUILD_PATH"); fi
swift build "${PHOTO_CHECK_ARGS[@]}" --product BrowserLocalizationChecks
PHOTO_CHECK_BIN=$(swift build "${PHOTO_CHECK_ARGS[@]}" --show-bin-path)
PHOTO_CHECK_ROOT=$(mktemp -d "$PWD/.build/camera-raw-checks.XXXXXX")
PHOTO_CHECK_APP="$PHOTO_CHECK_ROOT/LauncherChecks.app"
mkdir -p "$PHOTO_CHECK_APP/Contents/MacOS" "$PHOTO_CHECK_APP/Contents/Resources"
swiftc -parse-as-library -I "$PHOTO_CHECK_BIN/Modules" Sources/PhotoBrowser/Actions/CameraRawLauncher.swift \
  Tests/CameraRawHostChecks/LauncherChecks.swift "$PHOTO_CHECK_BIN"/BrowserCore.build/*.swift.o \
  -o "$PHOTO_CHECK_APP/Contents/MacOS/LauncherChecks"
ditto "$PHOTO_CHECK_BIN/PhotoBrowser_BrowserCore.bundle" "$PHOTO_CHECK_APP/Contents/Resources/PhotoBrowser_BrowserCore.bundle"
cat > "$PHOTO_CHECK_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LauncherChecks</string>
<key>CFBundleIdentifier</key><string>local.wxj.PhotoBrowser.CameraRawLauncherChecks</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
PHOTO_CAMERA_RAW_TESTING=0 bash scripts/build-camera-raw-host.sh "$PHOTO_CHECK_ROOT/ProductionHost.app"
PHOTO_TEST_ARGS=(--binary "$PHOTO_CHECK_ROOT/ProductionHost.app/Contents/MacOS/CameraRawHost" --output "$PHOTO_CHECK_ROOT/results")
if [ "${1:-}" = --ui ]; then
  shift
  PHOTO_CAMERA_RAW_TESTING=1 bash scripts/build-camera-raw-host.sh "$PHOTO_CHECK_APP/Contents/Helpers/CameraRawHost.app"
  PHOTO_TEST_ARGS+=(--test-binary "$PHOTO_CHECK_APP/Contents/Helpers/CameraRawHost.app/Contents/MacOS/CameraRawHost"
    --launcher "$PHOTO_CHECK_APP/Contents/MacOS/LauncherChecks")
fi
codesign --force --sign - "$PHOTO_CHECK_APP"
"$PHOTO_CHECK_APP/Contents/MacOS/LauncherChecks"
uv run python Tests/CameraRawHostChecks/check-host.py "${PHOTO_TEST_ARGS[@]}" "$@"
printf 'Camera Raw check results: %s\n' "$PHOTO_CHECK_ROOT"
