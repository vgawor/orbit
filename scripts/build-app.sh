#!/usr/bin/env bash
# Builds Orbit and wraps it into build/Orbit.app.
# Signs with your Apple Development certificate when there is one (stable identity across
# rebuilds), otherwise ad hoc. Set VIKTOR_SIGN_ID to pick a specific identity, or "-" for ad hoc.
# Set ORBIT_VERSION (e.g. 0.2.0) and ORBIT_BUILD (a whole number that only goes up) for releases.
# The viktor command-line tool is bundled at Orbit.app/Contents/Helpers/viktor.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="build/Orbit.app"
rm -rf "$APP" build/Viktor.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Viktor" "$APP/Contents/MacOS/Orbit"
cp "$BIN_DIR/viktor-cli" "$APP/Contents/Helpers/viktor"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Version: set for releases; otherwise the Info.plist version and the number of commits.
BUILD="${ORBIT_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
if [ -n "${ORBIT_VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $ORBIT_VERSION" "$APP/Contents/Info.plist"
fi

# Sparkle (automatic updates) lives in Contents/Frameworks.
SPARKLE="$(find "$BIN_DIR" -maxdepth 2 -name Sparkle.framework -type d | head -1)"
[ -z "$SPARKLE" ] && SPARKLE="$(find .build/artifacts -path '*macos*' -name Sparkle.framework -type d | head -1)"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Orbit" 2>/dev/null || true

# Releases (ORBIT_RELEASE=1, set by release.sh) use your Developer ID certificate when you have one,
# so Apple can notarize them. Everything else uses Apple Development.
identity() { security find-identity -v -p codesigning 2>/dev/null | sed -n "s/.*\"\($1[^\"]*\)\".*/\1/p" | head -1; }
DEV_ID=""
[ "${ORBIT_RELEASE:-0}" = "1" ] && DEV_ID="$(identity "Developer ID Application")"
SIGN_ID="${VIKTOR_SIGN_ID:-${DEV_ID:-$(identity "Apple Development")}}"

# Developer ID: what notarization needs. A secure timestamp and the hardened runtime on every piece
# of code, signed inside out (Sparkle's helpers first, as Sparkle's docs describe).
sign_distribution() {
  local cs=(perl -e 'alarm 120; exec @ARGV' codesign --force --timestamp --options runtime --sign "$1")
  local fw="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  "${cs[@]}" "$fw/XPCServices/Installer.xpc" &&
  "${cs[@]}" --preserve-metadata=entitlements "$fw/XPCServices/Downloader.xpc" &&
  "${cs[@]}" "$fw/Autoupdate" &&
  "${cs[@]}" "$fw/Updater.app" &&
  "${cs[@]}" "$APP/Contents/Frameworks/Sparkle.framework" &&
  "${cs[@]}" "$APP/Contents/Helpers/viktor" &&
  "${cs[@]}" --entitlements Resources/Orbit.entitlements "$APP" &&
  codesign --verify --deep --strict "$APP"
}

sign() {
  # Gives up after 60 s (e.g. if macOS is waiting for a Keychain prompt) instead of hanging.
  local cs=(perl -e 'alarm 60; exec @ARGV' codesign --force --timestamp=none --sign "$1")
  # With a real certificate, use the hardened runtime that Apple's notarization requires, so
  # anything it blocks shows up while testing. ORBIT_HARDENED=0 turns it off. Ad hoc builds
  # skip it: the hardened runtime refuses to load an ad hoc signed Sparkle.framework.
  "${cs[@]}" --deep "$APP/Contents/Frameworks/Sparkle.framework" >/dev/null 2>&1 || return 1
  if [ "$1" != "-" ] && [ "${ORBIT_HARDENED:-1}" = "1" ]; then
    "${cs[@]}" --options runtime "$APP/Contents/Helpers/viktor" >/dev/null 2>&1 &&
    "${cs[@]}" --options runtime --entitlements Resources/Orbit.entitlements "$APP" >/dev/null 2>&1
  else
    "${cs[@]}" "$APP/Contents/Helpers/viktor" >/dev/null 2>&1 &&
    "${cs[@]}" "$APP" >/dev/null 2>&1
  fi
}
if [[ "$SIGN_ID" == "Developer ID Application"* ]]; then
  if sign_distribution "$SIGN_ID" >/dev/null 2>&1; then
    touch "$APP/Contents/.developer-id"
    echo "Signed for distribution with: $SIGN_ID"
  else
    echo "Developer ID signing failed (macOS may be waiting for a Keychain prompt)."
    touch "$APP/Contents/.signing-failed"
  fi
elif [ -n "$SIGN_ID" ] && [ "$SIGN_ID" != "-" ] && sign "$SIGN_ID"; then
  echo "Signed with: $SIGN_ID"
else
  sign - && echo "Signed ad hoc"
  # Tell install.sh, so an unsigned build doesn't replace a signed one by accident.
  [ -n "$SIGN_ID" ] && [ "$SIGN_ID" != "-" ] && touch "$APP/Contents/.signing-failed"
fi
echo "Built $APP ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist") build $BUILD)"
