#!/bin/bash
# Integration check against an already-built local AI catalog; never calls a model.
set -euo pipefail
cd "$(dirname "$0")/.."
PHOTO_AI_ARGS=(--package-path "$PWD")
if [ -n "${PHOTO_BROWSER_BUILD_PATH:-}" ]; then PHOTO_AI_ARGS+=(--scratch-path "$PHOTO_BROWSER_BUILD_PATH"); fi
swift build "${PHOTO_AI_ARGS[@]}" --product PhotoBrowser
PHOTO_AI_BIN=$(swift build "${PHOTO_AI_ARGS[@]}" --show-bin-path)
mkdir -p dist
swiftc -parse-as-library -I "$PHOTO_AI_BIN/Modules" -F "$PHOTO_AI_BIN" \
  Sources/PhotoBrowser/Browsing/*.swift Sources/PhotoBrowser/Previews/*.swift \
  Sources/PhotoBrowser/Actions/*.swift Sources/PhotoBrowser/Playback/*.swift \
  Sources/PhotoBrowser/Views/*.swift Sources/PhotoBrowser/AIBrowsing/*.swift Sources/PhotoBrowser/BackgroundTasks/*.swift \
  Sources/PhotoBrowser/App/AppUpdater.swift Tests/AIBrowseUIChecks/UIChecks.swift \
  "$PHOTO_AI_BIN"/BrowserCore.build/*.swift.o -Xlinker -rpath -Xlinker "$PHOTO_AI_BIN" -o "$PHOTO_AI_BIN/AIBrowseUIChecks"
"$PHOTO_AI_BIN/AIBrowseUIChecks" "$PWD/dist/ai-categories.png"
