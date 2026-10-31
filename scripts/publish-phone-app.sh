#!/usr/bin/env bash
# Publishes the phone web app (web/app) to GitHub Pages, at
#   https://vgawor.github.io/orbit-releases/app/
# which is where Orbit sends you (Settings → Accounts → Orbit account → Copy link).
#
#   scripts/publish-phone-app.sh
#
# It copies web/app into the app/ folder of the orbit-releases repo (next to the update feed),
# pushes it, and switches on GitHub Pages for that repo the first time. Needs gh logged in.
# Afterwards, add the address to Supabase → Authentication → URL Configuration → Redirect URLs,
# so sign-in links from the phone come back to the app.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="vgawor/orbit-releases"
DIR="build/orbit-releases"

if [ -d "$DIR/.git" ]; then
  git -C "$DIR" pull -q --ff-only
else
  rm -rf "$DIR"
  gh repo clone "$REPO" "$DIR" -- -q
fi

rm -rf "$DIR/app"
mkdir -p "$DIR/app"
cp web/app/* "$DIR/app/"
# GitHub Pages would otherwise skip files and folders that start with "_".
touch "$DIR/.nojekyll"

git -C "$DIR" add app .nojekyll
if git -C "$DIR" diff --cached --quiet; then
  echo "The phone app is already up to date."
else
  git -C "$DIR" commit -q -m "Phone app"
  git -C "$DIR" push -q
  echo "Pushed the phone app."
fi

if ! gh api "repos/$REPO/pages" >/dev/null 2>&1; then
  gh api -X POST "repos/$REPO/pages" -f "source[branch]=main" -f "source[path]=/" >/dev/null
  echo "Switched on GitHub Pages (the first publish takes a minute or two)."
fi
echo "Phone app: https://vgawor.github.io/orbit-releases/app/"
