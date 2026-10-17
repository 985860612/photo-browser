#!/bin/bash
# Downloads and verifies the current stable release. Does not publish or install.
set -euo pipefail

if [ "${1:-}" = --help ]; then
  echo 'Usage: bash verify-public-release.sh [VERSION]'
  echo 'Uses scripts/app-settings.plist; PHOTO_RELEASE_VERIFY_DIR sets the evidence parent directory.'
  exit 0
fi
if [ "$#" -gt 1 ]; then echo 'Expected at most one version argument.' >&2; exit 64; fi
PHOTO_SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PHOTO_ROOT=$(git -C "$PHOTO_SCRIPT_DIR" rev-parse --show-toplevel)
cd "$PHOTO_ROOT"
PHOTO_SETTINGS="$PHOTO_ROOT/scripts/app-settings.plist"
PHOTO_CONFIG_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :Version' "$PHOTO_SETTINGS")
PHOTO_VERSION="${1:-$PHOTO_CONFIG_VERSION}"
if [[ ! "$PHOTO_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo 'Invalid version.' >&2; exit 64
fi
PHOTO_ACCOUNT=$(/usr/libexec/PlistBuddy -c 'Print :SigningAccount' "$PHOTO_SETTINGS")
PHOTO_PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c 'Print :PublicEDKey' "$PHOTO_SETTINGS")
PHOTO_FEED=$(/usr/libexec/PlistBuddy -c 'Print :FeedURL' "$PHOTO_SETTINGS")
case "$PHOTO_FEED" in
  https://github.com/*/*/releases/latest/download/appcast.xml) ;;
  *) echo 'Expected the project GitHub latest-release feed.' >&2; exit 1 ;;
esac
PHOTO_REPO_URL="${PHOTO_FEED%/releases/latest/download/appcast.xml}"
PHOTO_TOOLS="${PHOTO_BROWSER_BUILD_PATH:-$PHOTO_ROOT/.build}/artifacts/sparkle/Sparkle/bin"
if [ ! -x "$PHOTO_TOOLS/sign_update" ] || [ ! -x "$PHOTO_TOOLS/generate_keys" ]; then
  echo 'Sparkle tools missing. Resolve the package or set PHOTO_BROWSER_BUILD_PATH.' >&2; exit 1
fi
PHOTO_KEYCHAIN_PUBLIC=$("$PHOTO_TOOLS/generate_keys" --account "$PHOTO_ACCOUNT" -p)
if [ "$PHOTO_KEYCHAIN_PUBLIC" != "$PHOTO_PUBLIC_KEY" ]; then
  echo 'Keychain public key does not match project settings.' >&2; exit 1
fi
PHOTO_EVIDENCE_PARENT="${PHOTO_RELEASE_VERIFY_DIR:-$PHOTO_ROOT/.build/release-verification/v$PHOTO_VERSION}"
mkdir -p "$PHOTO_EVIDENCE_PARENT"
PHOTO_OUTPUT=$(mktemp -d "$PHOTO_EVIDENCE_PARENT/public.XXXXXX")
trap 'echo "Verification evidence retained: $PHOTO_OUTPUT" >&2' EXIT
PHOTO_URL="$PHOTO_REPO_URL/releases/download/v$PHOTO_VERSION"
PHOTO_ARCHIVE="PhotoBrowser-v$PHOTO_VERSION-macos-universal.zip"
for PHOTO_ASSET in appcast.xml "$PHOTO_ARCHIVE" "$PHOTO_ARCHIVE.sha256"; do
  curl --fail --location --silent --show-error --connect-timeout 10 --max-time 45 \
    --retry 2 --retry-all-errors --retry-delay 2 --retry-max-time 90 \
    "$PHOTO_URL/$PHOTO_ASSET" -o "$PHOTO_OUTPUT/$PHOTO_ASSET"
done
read -r PHOTO_EXPECTED_SHA PHOTO_EXPECTED_FILE < "$PHOTO_OUTPUT/$PHOTO_ARCHIVE.sha256"
if [[ ! "$PHOTO_EXPECTED_SHA" =~ ^[0-9a-fA-F]{64}$ ]] || [ "$PHOTO_EXPECTED_FILE" != "$PHOTO_ARCHIVE" ] || \
  [ "$(wc -l < "$PHOTO_OUTPUT/$PHOTO_ARCHIVE.sha256" | tr -d ' ')" != 1 ]; then
  echo 'Unexpected checksum manifest.' >&2; exit 1
fi
(cd "$PHOTO_OUTPUT" && shasum -a 256 -c "$PHOTO_ARCHIVE.sha256")
"$PHOTO_TOOLS/sign_update" --account "$PHOTO_ACCOUNT" --verify "$PHOTO_OUTPUT/appcast.xml"
PHOTO_XML_VERSION=$(xmllint --nonet --xpath 'string(//*[local-name()="shortVersionString"])' "$PHOTO_OUTPUT/appcast.xml")
PHOTO_ARCHIVE_URL=$(xmllint --nonet --xpath 'string(//enclosure/@url)' "$PHOTO_OUTPUT/appcast.xml")
PHOTO_SIGNATURE=$(xmllint --nonet --xpath 'string(//enclosure/@*[local-name()="edSignature"])' "$PHOTO_OUTPUT/appcast.xml")
if [ "$PHOTO_XML_VERSION" != "$PHOTO_VERSION" ] || [ "$PHOTO_ARCHIVE_URL" != "$PHOTO_URL/$PHOTO_ARCHIVE" ] || [ -z "$PHOTO_SIGNATURE" ]; then
  echo 'Signed appcast version or archive URL does not match the requested release.' >&2; exit 1
fi
if [ "$PHOTO_VERSION" = "$PHOTO_CONFIG_VERSION" ]; then
  PHOTO_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :Build' "$PHOTO_SETTINGS")
  PHOTO_XML_BUILD=$(xmllint --nonet --xpath 'string(//*[local-name()="version"])' "$PHOTO_OUTPUT/appcast.xml")
  test "$PHOTO_XML_BUILD" = "$PHOTO_BUILD"
fi
"$PHOTO_TOOLS/sign_update" --account "$PHOTO_ACCOUNT" --verify "$PHOTO_OUTPUT/$PHOTO_ARCHIVE" "$PHOTO_SIGNATURE"
if [ -f "$PHOTO_ROOT/dist/releases/v$PHOTO_VERSION/appcast.xml" ]; then
  cmp "$PHOTO_ROOT/dist/releases/v$PHOTO_VERSION/appcast.xml" "$PHOTO_OUTPUT/appcast.xml"
fi
curl --fail --location --silent --show-error --connect-timeout 10 --max-time 45 \
  --retry 2 --retry-all-errors --retry-delay 2 --retry-max-time 90 "$PHOTO_FEED" -o "$PHOTO_OUTPUT/latest-appcast.xml"
cmp "$PHOTO_OUTPUT/appcast.xml" "$PHOTO_OUTPUT/latest-appcast.xml"
echo "PASS: stable v$PHOTO_VERSION archive, checksum, signatures and latest feed"
