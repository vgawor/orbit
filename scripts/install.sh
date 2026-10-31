#!/usr/bin/env bash
# Builds Orbit, installs it to /Applications and restarts it.
# Also points ~/.local/bin/viktor (used by the Claude Code hooks) at the installed copy.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh
if [ -f build/Orbit.app/Contents/.signing-failed ] && [ "${VIKTOR_ALLOW_ADHOC:-}" != "1" ]; then
  echo "Not installed: signing with your certificate failed (macOS may be waiting for permission)."
  echo "Run this script from Terminal and choose Always Allow, or set VIKTOR_ALLOW_ADHOC=1."
  exit 1
fi
rm -f build/Orbit.app/Contents/.signing-failed
DEST="/Applications/Orbit.app"
pkill -f "Orbit.app/Contents/MacOS/Orbit" 2>/dev/null || true
pkill -f "Viktor.app/Contents/MacOS/Viktor" 2>/dev/null || true
sleep 0.5
# The app used to be called Viktor.app: move the old copy to the Trash.
if [ -d /Applications/Viktor.app ]; then
  mv /Applications/Viktor.app "$HOME/.Trash/Viktor $(date +%H%M%S).app" && echo "Moved the old Viktor.app to the Trash"
fi
rm -rf "$DEST"
cp -R build/Orbit.app "$DEST"
mkdir -p "$HOME/.local/bin"
if [ -L "$HOME/.local/bin/viktor" ] || [ ! -e "$HOME/.local/bin/viktor" ]; then
  ln -sfn "$DEST/Contents/Helpers/viktor" "$HOME/.local/bin/viktor"
fi
open "$DEST"
echo "Installed $DEST"
