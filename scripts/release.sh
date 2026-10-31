#!/usr/bin/env bash
# Makes a test release of Orbit: build/Orbit-<version>.dmg plus an entry in the Sparkle update
# feed (appcast.xml). With --publish it also uploads the DMG to GitHub (vgawor/orbit-releases)
# and pushes the feed, so installed copies offer the update.
#
#   scripts/release.sh 0.2.0                      # build the DMG and the feed entry only
#   scripts/release.sh 0.2.0 --publish            # ...and publish it
#   scripts/release.sh 0.2.0 --publish --notes "Snooze for nudges, Orbit in every add-on"
#
# Needs: your Apple Development certificate (same as install.sh), the Sparkle signing key in your
# Keychain (made once with .build/artifacts/sparkle/Sparkle/bin/generate_keys), and gh logged in.
# With a Developer ID certificate (Apple Developer Program) it is also notarized by Apple, so it
# opens without warnings. That needs the notary login saved once:
#   xcrun notarytool store-credentials orbit-notary --apple-id <you> --team-id <team> --password <app-specific password>
# Without one it isn't notarized: testers open it the first time via Privacy & Security → Open Anyway.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Usage: scripts/release.sh <version like 0.2.0> [--publish] [--notes \"…\"]"; exit 1; }
shift
PUBLISH=0
NOTES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --publish) PUBLISH=1 ;;
    --notes) NOTES="${2:-}"; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

REPO="vgawor/orbit-releases"
FEED_DIR="build/orbit-releases"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
DMG="build/Orbit-$VERSION.dmg"
TAG="v$VERSION"
URL="https://github.com/$REPO/releases/download/$TAG/Orbit-$VERSION.dmg"

if [ -n "$(git status --porcelain)" ]; then
  echo "Note: you have uncommitted changes; they go into this build."
fi

# 1. Build and sign the app. The build number is the commit count, so it only goes up.
BUILD="$(git rev-list --count HEAD)"
ORBIT_RELEASE=1 ORBIT_VERSION="$VERSION" ORBIT_BUILD="$BUILD" ./scripts/build-app.sh
if [ -f build/Orbit.app/Contents/.signing-failed ]; then
  echo "Stopped: signing with your certificate failed (macOS may be waiting for a Keychain prompt)."
  exit 1
fi

# 2. The DMG: Orbit.app and a shortcut to Applications, in a designed Finder window (background
#    from make-dmg-background.swift). Finder itself applies the layout, since macOS 26 ignores
#    layouts written by other tools. The first run asks once to let your terminal control Finder.
#    If that fails, it makes a plain DMG instead, so releases never break.
BG_DIR="build/dmg-background"
VOL="Orbit $VERSION"
STAGE="build/dmg"
RW="build/Orbit-rw.dmg"
rm -f "$DMG" "$RW"
stage_files() {
  rm -rf "$STAGE"; mkdir -p "$STAGE"
  ditto build/Orbit.app "$STAGE/Orbit.app"
  ln -s /Applications "$STAGE/Applications"
}
make_designed_dmg() {
  swift scripts/make-dmg-background.swift "$BG_DIR" >/dev/null || return 1
  stage_files
  mkdir -p "$STAGE/.background"
  cp "$BG_DIR/dmg-background.tiff" "$STAGE/.background/background.tiff"
  cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"
  # Another disk with the same name would make Finder style the wrong one.
  ls -d "/Volumes/$VOL"* 2>/dev/null | while read -r v; do hdiutil detach -quiet "$v" || true; done
  hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDRW -fs HFS+ "$RW" >/dev/null || return 1
  local dev
  dev="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk '/Apple_HFS/ {print $1; exit}')"
  [ -n "$dev" ] || return 1
  SetFile -a C "/Volumes/$VOL" 2>/dev/null || true   # use .VolumeIcon.icns as the disk icon
  local ok=0
  perl -e 'alarm 90; exec @ARGV' osascript - "$VOL" >/dev/null <<'APPLESCRIPT' || ok=1
on run argv
  set vol to item 1 of argv
  tell application "Finder"
    tell disk vol
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      -- {left, top, right, bottom}; the 28 pt extra is the title bar, so the picture fits 660×400.
      set the bounds of container window to {200, 120, 860, 548}
      set opts to the icon view options of container window
      set arrangement of opts to not arranged
      set icon size of opts to 128
      set text size of opts to 13
      set background picture of opts to file ".background:background.tiff"
      set position of item "Orbit.app" of container window to {170, 188}
      set position of item "Applications" of container window to {490, 188}
      update without registering applications
      delay 1
      close container window
    end tell
  end tell
end run
APPLESCRIPT
  sync; sleep 1
  hdiutil detach -quiet "$dev" || hdiutil detach -force -quiet "$dev"
  [ "$ok" = 0 ] || { rm -f "$RW"; return 1; }
  hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG" >/dev/null || return 1
  rm -f "$RW"; rm -rf "$STAGE"
}
make_plain_dmg() {
  stage_files
  hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGE"
}
if ! make_designed_dmg; then
  echo "Warning: couldn't style the DMG window (Finder automation not allowed?); making a plain DMG."
  rm -f "$DMG" "$RW"
  make_plain_dmg
fi
echo "Made $DMG ($(du -h "$DMG" | cut -f1 | xargs))"

# 2b. Notarize: Apple checks the DMG for malware, then the ticket is stapled on so it opens offline too.
NOTARIZED=0
if [ -f build/Orbit.app/Contents/.developer-id ]; then
  ID="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application[^"]*\)".*/\1/p' | head -1)"
  codesign --force --timestamp --sign "$ID" "$DMG"
  echo "Sending to Apple for notarization (usually a few minutes)…"
  if xcrun notarytool submit "$DMG" --keychain-profile "${ORBIT_NOTARY_PROFILE:-orbit-notary}" --wait | tee build/notary.log | grep -q "status: Accepted"; then
    xcrun stapler staple "$DMG" >/dev/null
    spctl --assess --type open --context context:primary-signature "$DMG" && NOTARIZED=1
    echo "Notarized and stapled."
  else
    echo "Stopped: Apple didn't accept it. See build/notary.log, and for details:"
    echo "  xcrun notarytool log <submission id> --keychain-profile ${ORBIT_NOTARY_PROFILE:-orbit-notary}"
    exit 1
  fi
else
  echo "Not notarized (no Developer ID certificate yet)."
fi

# 3. Sign the DMG for Sparkle (with the private key in your Keychain).
SIG="$(perl -e 'alarm 60; exec @ARGV' "$SPARKLE_BIN/sign_update" "$DMG")"
[[ "$SIG" == *edSignature* ]] || { echo "Stopped: couldn't sign the update ($SIG)"; exit 1; }

# 4. Add it to the feed (newest first).
if [ -d "$FEED_DIR/.git" ]; then
  git -C "$FEED_DIR" pull -q --ff-only || true
elif [ "$PUBLISH" = 1 ]; then
  rm -rf "$FEED_DIR"   # a feed from a trial run (not published) is replaced by the real one
  gh repo clone "$REPO" "$FEED_DIR" -- -q
else
  mkdir -p "$FEED_DIR"
fi
NOTES="${NOTES:-Orbit $VERSION}"
python3 - "$FEED_DIR/appcast.xml" "$VERSION" "$BUILD" "$URL" "$SIG" "$NOTES" <<'PY'
import sys, os, html, email.utils
path, version, build, url, sig, notes = sys.argv[1:]
head = '<?xml version="1.0" encoding="utf-8"?>\n<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n<channel>\n<title>Orbit</title>\n'
tail = '</channel>\n</rss>\n'
body = ""
if os.path.exists(path):
    text = open(path).read()
    start = text.find("<item>")
    end = text.rfind("</item>")
    if start != -1:
        body = text[start:end + len("</item>")] + "\n"
    # Re-releasing the same version replaces its entry.
    import re
    body = re.sub(r"<item>(?:(?!</item>).)*?<sparkle:shortVersionString>" + re.escape(version) + r"</sparkle:shortVersionString>.*?</item>\n?", "", body, flags=re.S)
item = f"""<item>
  <title>Orbit {version}</title>
  <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
  <sparkle:version>{build}</sparkle:version>
  <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
  <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
  <description><![CDATA[<p>{html.escape(notes)}</p>]]></description>
  <enclosure url="{url}" type="application/octet-stream" {sig} />
</item>
"""
open(path, "w").write(head + item + body + tail)
PY
echo "Feed entry added to $FEED_DIR/appcast.xml (version $VERSION, build $BUILD)"

if [ "$PUBLISH" != 1 ]; then
  echo "Not published. Run again with --publish to upload it."
  exit 0
fi

# 5. Publish: the DMG first, then the feed, so the feed never points at a missing file.
if [ "$NOTARIZED" = 1 ]; then
  RELEASE_NOTES="$NOTES

Open the DMG and drag Orbit to Applications. Updates install by themselves."
else
RELEASE_NOTES="$NOTES

**First time opening Orbit:** it isn't notarized by Apple yet, so macOS blocks it the first time.
Open the DMG, drag Orbit to Applications, open it once, then go to System Settings → Privacy & Security
and click **Open Anyway**. After that, updates install by themselves."
fi
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DMG" --repo "$REPO" --clobber
else
  gh release create "$TAG" "$DMG" --repo "$REPO" --title "Orbit $VERSION" --notes "$RELEASE_NOTES"
fi
git -C "$FEED_DIR" add appcast.xml
git -C "$FEED_DIR" commit -q -m "Orbit $VERSION"
git -C "$FEED_DIR" push -q
git tag -f "$TAG" >/dev/null
echo "Published Orbit $VERSION: https://github.com/$REPO/releases/tag/$TAG"
