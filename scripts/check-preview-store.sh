#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PREVIEW_BUILD_ARGS=(--package-path "$PWD")
if [ -n "${PHOTO_BROWSER_BUILD_PATH:-}" ]; then PREVIEW_BUILD_ARGS+=(--scratch-path "$PHOTO_BROWSER_BUILD_PATH"); fi
swift build "${PREVIEW_BUILD_ARGS[@]}" --product PhotoBrowser
PREVIEW_BUILD_PATH="$(swift build "${PREVIEW_BUILD_ARGS[@]}" --show-bin-path)"
swiftc -parse-as-library -I "$PREVIEW_BUILD_PATH/Modules" \
  Sources/PhotoBrowser/BrowserStore.swift Sources/PhotoBrowser/CameraRawLauncher.swift \
  Sources/PhotoBrowser/PreviewPresentation.swift Sources/PhotoBrowser/PhotoCanvas.swift \
  Tests/BrowserPreviewStoreChecks/PreviewStoreChecks.swift \
  Tests/BrowserPreviewStoreChecks/CanvasRenderChecks.swift \
  "$PREVIEW_BUILD_PATH"/BrowserCore.build/*.swift.o \
  -o "$PREVIEW_BUILD_PATH/PreviewStoreChecks"
"$PREVIEW_BUILD_PATH/PreviewStoreChecks"
