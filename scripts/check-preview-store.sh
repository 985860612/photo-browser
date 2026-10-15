#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PREVIEW_BUILD_ARGS=(--package-path "$PWD")
if [ -n "${PHOTO_BROWSER_BUILD_PATH:-}" ]; then PREVIEW_BUILD_ARGS+=(--scratch-path "$PHOTO_BROWSER_BUILD_PATH"); fi
swift build "${PREVIEW_BUILD_ARGS[@]}" --product PhotoBrowser
PREVIEW_BUILD_PATH="$(swift build "${PREVIEW_BUILD_ARGS[@]}" --show-bin-path)"
swiftc -parse-as-library -I "$PREVIEW_BUILD_PATH/Modules" \
  Sources/PhotoBrowser/Browsing/*.swift Sources/PhotoBrowser/Previews/*.swift \
  Sources/PhotoBrowser/Culling/CullingStore.swift Sources/PhotoBrowser/Culling/CullingAnalysis.swift Sources/PhotoBrowser/Culling/CullingFiltering.swift \
  Sources/PhotoBrowser/Actions/Browser*.swift Sources/PhotoBrowser/Actions/CameraRawLauncher.swift \
  Sources/PhotoBrowser/Playback/BrowserPlayback.swift Sources/PhotoBrowser/Playback/VideoPlayback.swift \
  Sources/PhotoBrowser/Playback/VideoMemory.swift \
  Tests/BrowserPreviewStoreChecks/*.swift Tests/BrowserThumbnailChecks/VideoFixture.swift Tests/BrowserThumbnailChecks/LivePhotoFixture.swift \
  "$PREVIEW_BUILD_PATH"/BrowserCore.build/*.swift.o \
  "$PREVIEW_BUILD_PATH"/CullingCore.build/*.swift.o \
  -o "$PREVIEW_BUILD_PATH/PreviewStoreChecks"
"$PREVIEW_BUILD_PATH/PreviewStoreChecks"
