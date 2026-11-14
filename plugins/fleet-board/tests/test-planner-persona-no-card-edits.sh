#!/usr/bin/env bash
# The shipped planner persona must say the planner never creates, moves or
# edits cards, and must point the user at the Draft cards button.
# Usage: bash plugins/fleet-board/tests/test-planner-persona-no-card-edits.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PERSONA="${SCRIPT_DIR}/../skills/planner/references/persona.md"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

# Working rules section only.
rules="$(awk '/^## /{s=($0=="## Working rules")} s' "$PERSONA" 2>/dev/null)"

t1="the shipped persona has a working rule saying the planner never creates, moves or edits cards"
if printf '%s\n' "$rules" | grep -Eiq '^- .*never creates?, moves? or edits? cards'; then pass "$t1"
else fail "$t1" "no working rule matching 'never create, move or edit cards'"; fi

t2="the shipped persona tells the user to press Draft cards to turn the conversation into cards"
if grep -Eiq 'press[^.]*Draft cards[^.]*(conversation|into cards)|(conversation|into cards)[^.]*press[^.]*Draft cards' "$PERSONA"; then pass "$t2"
else fail "$t2" "no instruction to press Draft cards"; fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
