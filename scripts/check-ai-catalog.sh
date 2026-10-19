#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PHOTO_AI_ARGS=(--package-path "$PWD")
if [ -n "${PHOTO_BROWSER_BUILD_PATH:-}" ]; then PHOTO_AI_ARGS+=(--scratch-path "$PHOTO_BROWSER_BUILD_PATH"); fi
swift run "${PHOTO_AI_ARGS[@]}" AICatalogChecks
PHOTO_AI_BIN=$(swift build "${PHOTO_AI_ARGS[@]}" --show-bin-path)
swiftc -parse-as-library -I "$PHOTO_AI_BIN/Modules" \
  Sources/PhotoBrowser/AIBrowsing/AIBrowseStore.swift Tests/AIBrowseStoreChecks/StoreChecks.swift \
  "$PHOTO_AI_BIN"/BrowserCore.build/*.swift.o -o "$PHOTO_AI_BIN/AIBrowseStoreChecks"
"$PHOTO_AI_BIN/AIBrowseStoreChecks"
