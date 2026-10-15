#!/bin/bash
# Real Sparkle integration, isolated from the installed app, user defaults and production signing key.
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
PHOTO_APP="${1:-dist/照片浏览器.app}"
bash scripts/check-updates.sh "$PHOTO_APP"
PHOTO_BUILD_ARGS=(--package-path "$PWD")
if [ -n "${PHOTO_BROWSER_BUILD_PATH:-}" ]; then PHOTO_BUILD_ARGS+=(--scratch-path "$PHOTO_BROWSER_BUILD_PATH"); fi
PHOTO_BIN=$(swift build "${PHOTO_BUILD_ARGS[@]}" --show-bin-path)
PHOTO_TOOLS="${PHOTO_BROWSER_BUILD_PATH:-$PWD/.build}/artifacts/sparkle/Sparkle/bin"
PHOTO_TEST_ROOT=$(mktemp -d)
PHOTO_TEST_PREFIX="local.wxj.PhotoBrowser.InstallChecks.$RANDOM.$RANDOM"
PHOTO_SERVER_PID=''
PHOTO_PROBE_PID=''
cleanup() {
  if [ -n "$PHOTO_PROBE_PID" ] && kill -0 "$PHOTO_PROBE_PID" 2>/dev/null; then kill "$PHOTO_PROBE_PID"; wait "$PHOTO_PROBE_PID" || true; fi
  if [ -n "$PHOTO_SERVER_PID" ]; then kill "$PHOTO_SERVER_PID"; wait "$PHOTO_SERVER_PID" || true; fi
  for PHOTO_CASE in found current bad-feed bad-archive install automatic; do
    defaults delete "$PHOTO_TEST_PREFIX.$PHOTO_CASE" 2>/dev/null || true
    rm -rf "$HOME/Library/Caches/$PHOTO_TEST_PREFIX.$PHOTO_CASE"
  done
  rm -rf "$PHOTO_TEST_ROOT"
}
trap cleanup EXIT
PHOTO_PUBLIC_KEY=$("$PHOTO_BIN/UpdaterChecks" --generate-test-key "$PHOTO_TEST_ROOT/test-key")
uv run --no-project --no-python-downloads --python "$(command -v python3)" python -u \
  Tests/BrowserUpdateChecks/serve-fixtures.py "$PHOTO_TEST_ROOT" "$PHOTO_TEST_ROOT/port" > "$PHOTO_TEST_ROOT/server.log" 2>&1 &
PHOTO_SERVER_PID=$!
for ((i=0; i<300; i++)); do
  if [ -s "$PHOTO_TEST_ROOT/port" ]; then break; fi
  if ! kill -0 "$PHOTO_SERVER_PID" 2>/dev/null; then cat "$PHOTO_TEST_ROOT/server.log"; exit 1; fi
  sleep 0.1
done
if [ ! -s "$PHOTO_TEST_ROOT/port" ]; then
  cat "$PHOTO_TEST_ROOT/server.log"
  echo 'Local update test server did not become ready within 30 seconds.' >&2
  exit 1
fi
PHOTO_PORT=$(cat "$PHOTO_TEST_ROOT/port")
PHOTO_BASE_URL="http://127.0.0.1:$PHOTO_PORT"
prepare_case() {
PHOTO_CASE_ROOT="$PHOTO_TEST_ROOT/$1"
mkdir -p "$PHOTO_CASE_ROOT/feed"
PHOTO_OLD_APP="$PHOTO_CASE_ROOT/installed/UpdaterChecks.app"
PHOTO_NEW_APP="$PHOTO_CASE_ROOT/payload/UpdaterChecks.app"
ditto "$PHOTO_APP" "$PHOTO_OLD_APP"
cp "$PHOTO_BIN/UpdaterChecks" "$PHOTO_OLD_APP/Contents/MacOS/PhotoBrowser"
PHOTO_INFO="$PHOTO_OLD_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $PHOTO_TEST_PREFIX.$1" "$PHOTO_INFO"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 1' "$PHOTO_INFO"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 1.0' "$PHOTO_INFO"
/usr/libexec/PlistBuddy -c 'Set :SUEnableAutomaticChecks false' "$PHOTO_INFO"
if [ "$1" = automatic ]; then
  /usr/libexec/PlistBuddy -c 'Set :SUEnableAutomaticChecks true' "$PHOTO_INFO"
  /usr/libexec/PlistBuddy -c 'Set :SUAutomaticallyUpdate true' "$PHOTO_INFO"
fi
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $PHOTO_PUBLIC_KEY" "$PHOTO_INFO"
/usr/libexec/PlistBuddy -c "Set :SUFeedURL $PHOTO_BASE_URL/$1/feed/appcast.xml" "$PHOTO_INFO"
# HTTP is allowed only in these isolated localhost fixtures.
/usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity dict' "$PHOTO_INFO"
/usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true' "$PHOTO_INFO"
ditto "$PHOTO_OLD_APP" "$PHOTO_NEW_APP"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 2' "$PHOTO_NEW_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 2.0' "$PHOTO_NEW_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :UpdateTestRelaunchMarker string $PHOTO_CASE_ROOT/relaunched" "$PHOTO_NEW_APP/Contents/Info.plist"
codesign --force --sign - "$PHOTO_NEW_APP"
ditto -c -k --sequesterRsrc --keepParent "$PHOTO_NEW_APP" "$PHOTO_CASE_ROOT/feed/update.zip"
"$PHOTO_TOOLS/generate_appcast" --ed-key-file "$PHOTO_TEST_ROOT/test-key" --maximum-deltas 0 \
  --download-url-prefix "$PHOTO_BASE_URL/$1/feed/" "$PHOTO_CASE_ROOT/feed"
codesign --force --sign - "$PHOTO_OLD_APP"
}
run_probe() {
  rm -f "$PHOTO_TEST_ROOT/result"
  "$PHOTO_OLD_APP/Contents/MacOS/PhotoBrowser" --probe --expect "$1" --result "$PHOTO_TEST_ROOT/result" -AppleLanguages '(en)' > "$PHOTO_TEST_ROOT/probe.log" 2>&1 &
  PHOTO_PROBE_PID=$!
  for ((j=0; j<450; j++)); do
    if ! kill -0 "$PHOTO_PROBE_PID" 2>/dev/null; then
      PHOTO_RESULT=0
      wait "$PHOTO_PROBE_PID" || PHOTO_RESULT=$?
      PHOTO_PROBE_PID=''
      cat "$PHOTO_TEST_ROOT/probe.log"
      if [ "$1" != installed ]; then
        test -f "$PHOTO_TEST_ROOT/result"
        test "$(cat "$PHOTO_TEST_ROOT/result")" = "$1"
      fi
      return "$PHOTO_RESULT"
    fi
    sleep 0.1
  done
  cat "$PHOTO_TEST_ROOT/probe.log"
  echo 'Update probe timed out' >&2
  return 1
}
prepare_case found
run_probe found
prepare_case current
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 3' "$PHOTO_INFO"
codesign --force --sign - "$PHOTO_OLD_APP"
run_probe current
prepare_case bad-feed
perl -pi -e 's/<title>/<title>TAMPERED /' "$PHOTO_CASE_ROOT/feed/appcast.xml"
run_probe signature-error
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PHOTO_INFO")" = 1
prepare_case bad-archive
printf 'tampered' >> "$PHOTO_CASE_ROOT/feed/update.zip"
run_probe signature-error
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PHOTO_INFO")" = 1
prepare_case install
run_probe installed
for ((i=0; i<300; i++)); do
  if [ -s "$PHOTO_CASE_ROOT/relaunched" ]; then break; fi
  sleep 0.1
done
test -s "$PHOTO_CASE_ROOT/relaunched"
case "$(cat "$PHOTO_CASE_ROOT/relaunched")" in */install/installed/UpdaterChecks.app) ;; *) echo 'Relaunched the wrong app' >&2; exit 1 ;; esac
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PHOTO_OLD_APP/Contents/Info.plist")" = 2
prepare_case automatic
run_probe automatic
for ((i=0; i<300; i++)); do
  if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PHOTO_INFO")" = 2 ]; then break; fi
  sleep 0.1
done
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PHOTO_INFO")" = 2
test ! -e "$PHOTO_CASE_ROOT/relaunched"
echo 'PASS: signed feed, tampering rejection, manual installation/relaunch, automatic download/install on quit'
