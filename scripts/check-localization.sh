#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PHOTO_CHECK_ARGS=()
if [ -n "${PHOTO_BROWSER_BUILD_PATH:-}" ]; then PHOTO_CHECK_ARGS+=(--scratch-path "$PHOTO_BROWSER_BUILD_PATH"); fi
swift build "${PHOTO_CHECK_ARGS[@]}" --product BrowserLocalizationChecks
PHOTO_CHECK_BIN=$(swift build "${PHOTO_CHECK_ARGS[@]}" --show-bin-path)/BrowserLocalizationChecks
for PHOTO_LANGUAGE in en zh-Hans; do
  "$PHOTO_CHECK_BIN" -AppleLanguages "($PHOTO_LANGUAGE)" "--expected-language=$PHOTO_LANGUAGE"
done
"$PHOTO_CHECK_BIN" -AppleLanguages '(fr)' --expected-language=en
if [ "$#" -gt 0 ]; then
  PHOTO_APP_SOURCE="$1"
  PHOTO_CHECK_ROOT=$(mktemp -d)
  trap 'rm -rf "$PHOTO_CHECK_ROOT"' EXIT
  PHOTO_CHECK_APP="$PHOTO_CHECK_ROOT/PhotoBrowserCheck.app"
  ditto "$PHOTO_APP_SOURCE" "$PHOTO_CHECK_APP"
  # Match CFBundleExecutable so Foundation treats this as the actual app bundle.
  cp "$PHOTO_CHECK_BIN" "$PHOTO_CHECK_APP/Contents/MacOS/PhotoBrowser"
  codesign --force --deep --sign - "$PHOTO_CHECK_APP"
  for PHOTO_LANGUAGE in en zh-Hans; do
    "$PHOTO_CHECK_APP/Contents/MacOS/PhotoBrowser" -AppleLanguages "($PHOTO_LANGUAGE)" \
      "--expected-language=$PHOTO_LANGUAGE" "--resource-root=$PHOTO_CHECK_APP"
  done
fi
