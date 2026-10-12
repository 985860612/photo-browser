#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product PhotoBrowser
PREVIEW_BUILD_PATH="$(swift build --show-bin-path)"
swiftc -parse-as-library -I "$PREVIEW_BUILD_PATH/Modules" \
  Sources/PhotoBrowser/BrowserStore.swift Sources/PhotoBrowser/CameraRawLauncher.swift \
  Tests/BrowserPreviewStoreChecks/PreviewStoreChecks.swift \
  "$PREVIEW_BUILD_PATH"/BrowserCore.build/*.swift.o \
  -o "$PREVIEW_BUILD_PATH/PreviewStoreChecks"
"$PREVIEW_BUILD_PATH/PreviewStoreChecks"
