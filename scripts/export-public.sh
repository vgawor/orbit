#!/usr/bin/env bash
# Makes the public, open-source copy of Orbit from this (private) repository.
#
#   scripts/export-public.sh                 # into build/orbit-public
#   scripts/export-public.sh ~/Code/orbit    # or another folder
#
# It copies every file except the private ones below, then checks the copy against
# .public-export-blocklist (names, account ids, keys) and stops if anything matches.
# The first run makes a fresh git repository with one commit, so the private history never goes
# public. Later runs add one commit with the changes. Pushing is up to you.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="${1:-build/orbit-public}"

# Private: planning, launch and setup notes, design drafts, the promo video, and this list.
PRIVATE=(
  docs/PLAN.md docs/COMPLETION-PLAN.md docs/ORBIT-PRO-SETUP.md docs/LAUNCH.md
  docs/COMMUNITY.md docs/BOTS-PLAN.md design/ promo/ .public-export-blocklist
)
# Allowed on purpose: the app's id and the company that publishes it, the update feed, contact address.
ALLOWED='com\.viktorgawor\.orbit|se\.visualised|Copyright 2026 Viktor Gawor|of Viktor Gawor\.|to Viktor Gawor\.|vgawor/orbit-releases|vgawor\.github\.io/orbit-releases|contains\("Visualised"\)'

mkdir -p "$DEST"
LIST="$(mktemp)"
git ls-files --cached --others --exclude-standard | while read -r f; do
  skip=0
  for p in "${PRIVATE[@]}"; do [[ "$f" == "$p" || "$f" == "$p"* && "$p" == */ ]] && skip=1; done
  [ -e "$f" ] && [ "$skip" = 0 ] && echo "$f"
done > "$LIST"
rsync -a --delete --exclude .git --files-from="$LIST" ./ "$DEST/"
# rsync --files-from doesn't delete files that left the list; remove them by hand.
# (Only inside the copy's own repository, never a parent one.)
[ -d "$DEST/.git" ] && ( cd "$DEST" && git ls-files ) | while read -r f; do
  grep -qxF "$f" "$LIST" || rm -f "$DEST/$f"
done
rm -f "$LIST"

# Check the copy.
BAD=0
while read -r pattern; do
  [[ -z "$pattern" || "$pattern" == \#* ]] && continue
  hits="$(grep -rIniE "$pattern" "$DEST" --exclude-dir=.git --exclude-dir=.build | grep -viE "$ALLOWED" || true)"
  if [ -n "$hits" ]; then
    echo "Private text found (\"$pattern\"):"; echo "$hits" | cut -c1-200 | head -5
    BAD=1
  fi
done < .public-export-blocklist
if [ "$BAD" = 1 ]; then
  echo "Stopped: fix the lines above (or allow them in this script), then run it again."
  exit 1
fi
echo "Checked: nothing private in $DEST."

cd "$DEST"
if [ ! -d .git ]; then
  # A fresh repository of its own, even though the folder may sit inside this one.
  git init -q -b main
  git add -A
  git commit -q -m "Orbit: first public release"
  echo "Made a fresh repository in $DEST with one commit."
else
  git add -A
  if git diff --cached --quiet; then
    echo "No changes since the last export."
  else
    git commit -q -m "Update from the main repository"
    echo "Committed the changes in $DEST."
  fi
fi
echo "Not pushed. To publish: create an empty GitHub repository, then in $DEST run"
echo "  git remote add origin <its URL> && git push -u origin main"
