#!/bin/zsh
# Smoke test: checks the parts of Orbit that unit tests can't reach.
#   1. Unit tests (swift test)
#   2. Every notch screen renders (preview mode, no permissions needed)
#   3. The orbit CLI talks to the running app: status, send, ls, rm, run, ask, Claude hooks
# Run from the project folder:  scripts/smoke-test.sh
# Step 3 needs Orbit running (open /Applications/Orbit.app). Anything shown in the notch
# is cleaned up again within a few seconds.

set -u
cd "${0:A:h}/.."
pass=0; fail=0
ok()   { print -P "  %F{green}✓%f $1"; pass=$((pass + 1)); }
bad()  { print -P "  %F{red}✗ $1%f"; fail=$((fail + 1)); }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi }

print "1. Unit tests"
if swift test 2>&1 | tee /tmp/orbit-tests.log | grep -q "Test run with .* passed"; then
  ok "$(grep -E 'Test run with' /tmp/orbit-tests.log | sed -E 's/.*Test run with ([0-9]+) tests.*/\1/' | paste -sd+ - | bc) tests passed"
else
  bad "unit tests failed (see /tmp/orbit-tests.log)"
fi

print "2. Screens render"
shots=$(mktemp -d /tmp/orbit-shots.XXXX)
swift build --product Orbit >/dev/null 2>&1 || bad "app builds"
ORBIT_PREVIEW=1 perl -e 'alarm 60; exec @ARGV' .build/debug/Orbit --snapshot "$shots" >/dev/null 2>&1
for name in peek alert drop open-home open-music open-meetings open-tasks open-focus open-notes open-shelf; do
  check "$name" "[[ -s $shots/$name.png ]]"
done
others=$(ls "$shots" | grep -c '^open-')
ok "$others open screens rendered in total (only enabled features render) → $shots"

print "3. CLI ↔ running app"
cli=.build/debug/orbit-cli
swift build --product orbit-cli >/dev/null 2>&1
if ! $cli status >/dev/null 2>&1; then
  bad "Orbit isn't running, so the CLI checks were skipped (open /Applications/Orbit.app)"
else
  ok "status: app answers"
  id="smoke-$$"
  check "send an item" "$cli send --id $id --title 'Smoke test' --progress 0.5 --ttl 10"
  check "ls shows it" "$cli ls --json | grep -q $id"
  check "update it" "$cli send --id $id --title 'Smoke test' --status success --ttl 10"
  check "rm removes it" "$cli rm $id && ! $cli ls --json | grep -q $id"
  check "run reports success" "$cli run --title 'Smoke run' -- true"
  check "run passes on failure" "! $cli run --title 'Smoke run' -- false"
  check "unanswered ask times out" "! $cli ask 'Smoke test, ignore me' --actions OK --timeout 2"
  sid="smoke-$$"
  check "Claude hook event accepted" "print '{\"session_id\":\"$sid\",\"hook_event_name\":\"SessionStart\",\"cwd\":\"/tmp/smoke\"}' | $cli hook claude"
  check "Claude session ends" "print '{\"session_id\":\"$sid\",\"hook_event_name\":\"SessionEnd\",\"cwd\":\"/tmp/smoke\"}' | $cli hook claude"
  tmp=$(mktemp -d /tmp/orbit-hooks.XXXX)
  check "hook install (temp settings)" "$cli hook install claude --settings $tmp/settings.json && grep -q 'hook claude' $tmp/settings.json"
  check "hook uninstall (temp settings)" "$cli hook uninstall claude --settings $tmp/settings.json && ! grep -q 'hook claude' $tmp/settings.json"
  check "wrong token is refused" "curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer nope' http://127.0.0.1:47900/v1/status | grep -q 401"
fi

print
if (( fail == 0 )); then print -P "%F{green}All $pass checks passed.%f"; else print -P "%F{red}$fail of $((pass + fail)) checks failed.%f"; fi
exit $(( fail > 0 ))
