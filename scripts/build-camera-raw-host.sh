#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PHOTO_HOST_APP="${1:-$PWD/.build/CameraRawHost.app}"
PHOTO_SDK_REVISION=7e9aca4353a3d4615e9522f47521bf840fb4388c
PHOTO_SDK="${PHOTO_CAMERA_RAW_SDK:-$PWD/.build/camera-raw-sdk}"
if [ ! -d "$PHOTO_SDK" ]; then
  if [ -n "${PHOTO_CAMERA_RAW_SDK:-}" ]; then
    echo "Adobe SDK directory does not exist: $PHOTO_SDK" >&2
    exit 1
  fi
  mkdir -p .build
  git clone --filter=blob:none --no-checkout https://github.com/AdobeDocs/photoshop-cpp-sdk.git "$PHOTO_SDK"
  git -C "$PHOTO_SDK" checkout --detach "$PHOTO_SDK_REVISION"
fi
if [ -z "${PHOTO_CAMERA_RAW_SDK:-}" ] && [ "$(git -C "$PHOTO_SDK" rev-parse HEAD)" != "$PHOTO_SDK_REVISION" ]; then
  echo "Unexpected SDK revision. Use the pinned SDK or set PHOTO_CAMERA_RAW_SDK explicitly." >&2
  exit 1
fi
PHOTO_API="$PHOTO_SDK/pluginsdk/photoshopapi"
if [ ! -f "$PHOTO_API/photoshop/PIFormat.h" ]; then
  echo "Adobe Photoshop C++ SDK headers missing at: $PHOTO_API" >&2
  exit 1
fi
PHOTO_HOST_FLAGS=(-std=c++17 -fobjc-arc -DMAC_ENV=1 -Wno-deprecated-declarations
  -I "$PHOTO_API/photoshop" -I "$PHOTO_API/pica_sp" -framework Cocoa -framework Carbon)
if [ "${PHOTO_CAMERA_RAW_TESTING:-0}" = 1 ]; then PHOTO_HOST_FLAGS+=(-DPHOTO_CAMERA_RAW_TESTING=1); fi
mkdir -p "$PHOTO_HOST_APP/Contents/MacOS" "$PHOTO_HOST_APP/Contents/Resources"
# The RAW variant distinguishes this editor from the blue photo browser.
PHOTO_HOST_ICONSET="$PHOTO_HOST_APP/Contents/Resources/AppIcon.iconset"
swift scripts/create-icon.swift "$PHOTO_HOST_ICONSET" --camera-raw
iconutil -c icns "$PHOTO_HOST_ICONSET" -o "$PHOTO_HOST_APP/Contents/Resources/AppIcon.icns"
rm -r "$PHOTO_HOST_ICONSET"
PHOTO_HOST_ARCHES=("$(uname -m)")
if [ "${PHOTO_BROWSER_UNIVERSAL:-0}" = 1 ]; then PHOTO_HOST_ARCHES=(arm64 x86_64); fi
PHOTO_HOST_PARTS=()
for PHOTO_HOST_ARCH in "${PHOTO_HOST_ARCHES[@]}"; do
  PHOTO_HOST_PART="$PHOTO_HOST_APP/Contents/MacOS/CameraRawHost.$PHOTO_HOST_ARCH"
  xcrun clang++ "${PHOTO_HOST_FLAGS[@]}" -target "$PHOTO_HOST_ARCH-apple-macos14.0" \
    Native/CameraRawHost/main.mm -o "$PHOTO_HOST_PART"
  PHOTO_HOST_PARTS+=("$PHOTO_HOST_PART")
done
if [ "${#PHOTO_HOST_PARTS[@]}" = 1 ]; then
  mv "${PHOTO_HOST_PARTS[0]}" "$PHOTO_HOST_APP/Contents/MacOS/CameraRawHost"
else
  lipo -create "${PHOTO_HOST_PARTS[@]}" -output "$PHOTO_HOST_APP/Contents/MacOS/CameraRawHost"
  rm "${PHOTO_HOST_PARTS[@]}"
fi
cat > "$PHOTO_HOST_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CameraRawHost</string>
<key>CFBundleIdentifier</key><string>local.wxj.PhotoBrowser.CameraRawHost</string>
<key>CFBundleName</key><string>Photo Browser Camera Raw</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$PHOTO_HOST_APP"
codesign --verify --strict "$PHOTO_HOST_APP"
printf '%s\n' "$PHOTO_HOST_APP"
