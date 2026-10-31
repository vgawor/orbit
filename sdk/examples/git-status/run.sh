#!/bin/zsh
# Orbit widget: branch and changed files for the repo given as the first argument.
repo=${1/#\~/$HOME}
cd "$repo" 2>/dev/null || { echo "{\"title\":\"Git status\",\"value\":\"Repo not found\",\"subtitle\":\"Edit args in widget.json\"}"; exit 0; }
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
changed=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
ahead=$(git rev-list --count @{u}..HEAD 2>/dev/null || echo 0)
name=$(basename "$repo")
printf '{"title":"%s","value":"%s","subtitle":"%s changed · %s to push","chip":"%s · %s","tint":"%s"}\n' \
  "$name" "$branch" "$changed" "$ahead" "$branch" "$changed" "$([[ $changed -gt 0 ]] && echo '#FFB020' || echo '#34C759')"
