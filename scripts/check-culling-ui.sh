#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PHOTO_UI_ARGS=(--package-path "$PWD")
if [ -n "${PHOTO_BROWSER_BUILD_PATH:-}" ]; then PHOTO_UI_ARGS+=(--scratch-path "$PHOTO_BROWSER_BUILD_PATH"); fi
swift build "${PHOTO_UI_ARGS[@]}" --product PhotoBrowser
PHOTO_UI_BIN="$(swift build "${PHOTO_UI_ARGS[@]}" --show-bin-path)"
PHOTO_UI_SOURCES=(Sources/PhotoBrowser/{Actions,Browsing,Culling,Playback,Previews}/*.swift)
for PHOTO_UI_FILE in Sources/PhotoBrowser/Views/*.swift; do
  case "$PHOTO_UI_FILE" in
    */PreviewSettingsView.swift|*/PreviewSortMenu.swift|*/UpdateSettingsView.swift) ;;
    *) PHOTO_UI_SOURCES+=("$PHOTO_UI_FILE") ;;
  esac
done
PHOTO_UI_SOURCES+=(Sources/PhotoBrowser/Views/PreviewSortMenu.swift)
swiftc -parse-as-library -I "$PHOTO_UI_BIN/Modules" \
  "${PHOTO_UI_SOURCES[@]}" Tests/BrowserCullingUIChecks/*.swift \
  "$PHOTO_UI_BIN"/BrowserCore.build/*.swift.o "$PHOTO_UI_BIN"/CullingCore.build/*.swift.o \
  -o "$PHOTO_UI_BIN/CullingUIChecks"
"$PHOTO_UI_BIN/CullingUIChecks" "$@"
