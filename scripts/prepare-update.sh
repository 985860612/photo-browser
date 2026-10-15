#!/bin/bash
# Prepare signed release assets locally. This script never publishes or pushes.
set -euo pipefail
cd "$(dirname "$0")/.."
PHOTO_SETTINGS="$PWD/scripts/app-settings.plist"
PHOTO_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :Version' "$PHOTO_SETTINGS")
PHOTO_ACCOUNT=$(/usr/libexec/PlistBuddy -c 'Print :SigningAccount' "$PHOTO_SETTINGS")
PHOTO_PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c 'Print :PublicEDKey' "$PHOTO_SETTINGS")
PHOTO_RELEASE_DIR="$PWD/dist/releases/v$PHOTO_VERSION"
if [ -e "$PHOTO_RELEASE_DIR" ]; then
  echo "Release assets already exist: $PHOTO_RELEASE_DIR. Move them aside before preparing a new release." >&2
  exit 1
fi
PHOTO_BUILD_ARGS=(--package-path "$PWD")
if [ -n "${PHOTO_BROWSER_BUILD_PATH:-}" ]; then PHOTO_BUILD_ARGS+=(--scratch-path "$PHOTO_BROWSER_BUILD_PATH"); fi
swift package "${PHOTO_BUILD_ARGS[@]}" resolve
PHOTO_TOOLS="${PHOTO_BROWSER_BUILD_PATH:-$PWD/.build}/artifacts/sparkle/Sparkle/bin"
PHOTO_KEYCHAIN_PUBLIC=$("$PHOTO_TOOLS/generate_keys" --account "$PHOTO_ACCOUNT" -p)
if [ "$PHOTO_KEYCHAIN_PUBLIC" != "$PHOTO_PUBLIC_KEY" ]; then
  echo 'The signing key in Keychain does not match scripts/app-settings.plist.' >&2
  exit 1
fi
PHOTO_BROWSER_UNIVERSAL=1 bash scripts/build-app.sh
bash scripts/check-localization.sh 'dist/照片浏览器.app'
bash scripts/check-updates.sh 'dist/照片浏览器.app'
mkdir -p "$PWD/dist/releases"
PHOTO_STAGE=$(mktemp -d "$PWD/dist/releases/.preparing.XXXXXX")
trap 'rm -rf "$PHOTO_STAGE"' EXIT
PHOTO_ARCHIVE="PhotoBrowser-v$PHOTO_VERSION-macos-universal.zip"
ditto -c -k --sequesterRsrc --keepParent 'dist/照片浏览器.app' "$PHOTO_STAGE/$PHOTO_ARCHIVE"
if [ "$#" -gt 0 ]; then cp "$1" "$PHOTO_STAGE/${PHOTO_ARCHIVE%.zip}.md"; fi
"$PHOTO_TOOLS/generate_appcast" --account "$PHOTO_ACCOUNT" --maximum-deltas 0 --embed-release-notes \
  --download-url-prefix "https://github.com/985860612/photo-browser/releases/download/v$PHOTO_VERSION/" \
  --link 'https://github.com/985860612/photo-browser' "$PHOTO_STAGE"
"$PHOTO_TOOLS/sign_update" --account "$PHOTO_ACCOUNT" --verify "$PHOTO_STAGE/appcast.xml"
PHOTO_SIGNATURE=$(xmllint --xpath 'string(//enclosure/@*[local-name()="edSignature"])' "$PHOTO_STAGE/appcast.xml")
"$PHOTO_TOOLS/sign_update" --account "$PHOTO_ACCOUNT" --verify "$PHOTO_STAGE/$PHOTO_ARCHIVE" "$PHOTO_SIGNATURE"
(cd "$PHOTO_STAGE" && shasum -a 256 "$PHOTO_ARCHIVE" > "$PHOTO_ARCHIVE.sha256")
mv "$PHOTO_STAGE" "$PHOTO_RELEASE_DIR"
printf 'Prepared signed update assets (not published): %s\n' "$PHOTO_RELEASE_DIR"
