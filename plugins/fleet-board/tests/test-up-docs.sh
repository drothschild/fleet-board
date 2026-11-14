#!/usr/bin/env bash
#
# Plain-bash docs-claim test for `fleet-board up`: the usage text lists it and
# the README describes it, including that Ctrl-C drains the supervisor it started.
#
# Usage: bash plugins/fleet-board/tests/test-up-docs.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
README="$SCRIPT_DIR/../README.md"
LAUNCHER="$SCRIPT_DIR/../scripts/fleet-board"
SENTENCE="Ctrl-C drains the supervisor it started"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

# has_sentence FILE: true when FILE holds the claim sentence.
has_sentence() { grep -qF -- "$SENTENCE" "$1"; }

if bash "$LAUNCHER" --help 2>&1 | grep -q '^ *\(usage: \)\{0,1\}fleet-board up'; then
  pass "fleet-board --help lists up"
else
  fail "fleet-board --help lists up"
fi

if grep -qF 'fleet-board up' "$README"; then
  pass "README describes fleet-board up"
else
  fail "README describes fleet-board up"
fi

if has_sentence "$README"; then
  pass "README says Ctrl-C drains the supervisor it started"
else
  fail "README says Ctrl-C drains the supervisor it started (missing: $SENTENCE)"
fi

for sec in "## Running the supervisor" "## Local board" "## On a fresh repo"; do
  body="$(awk -v h="$sec" '$0==h{f=1;next} /^## /{f=0} f' "$README")"
  if printf '%s\n' "$body" | grep -qF 'fleet-board up'; then
    pass "README section '$sec' mentions fleet-board up"
  else
    fail "README section '$sec' mentions fleet-board up"
  fi
done

# The claim check fails when the sentence is removed.
TMP="$(mktemp)"
sed "s/$SENTENCE/Ctrl-C does something/" "$README" > "$TMP"
if has_sentence "$TMP"; then
  fail "claim check fails when the sentence is removed"
else
  pass "claim check fails when the sentence is removed"
fi
rm -f "$TMP"

# The `fleet-board up` section: the paragraph that starts with the up command.
UP_SECTION="$(awk '/^`fleet-board up \[--port N\]`/{f=1;print;next} f&&/^$/{f=0} f' "$README")"
LOG_CLAIM='the terminal shows `supervisor.log`'
BOARD_LOG_CLAIM='`<log dir>/board-web.log`'

if printf '%s\n' "$UP_SECTION" | grep -qF -- "$LOG_CLAIM"; then
  pass "up section says the terminal shows supervisor.log"
else
  fail "up section says the terminal shows supervisor.log (missing: $LOG_CLAIM)"
fi

if printf '%s\n' "$UP_SECTION" | grep -qF -- "$BOARD_LOG_CLAIM"; then
  pass "up section names <log dir>/board-web.log as where request lines go"
else
  fail "up section names <log dir>/board-web.log as where request lines go (missing: $BOARD_LOG_CLAIM)"
fi

# Each claim check fails when its statement is removed.
if printf '%s\n' "$UP_SECTION" | sed 's/supervisor\.log/gone/' | grep -qF -- "$LOG_CLAIM"; then
  fail "supervisor.log check fails when the statement is removed"
else
  pass "supervisor.log check fails when the statement is removed"
fi
if printf '%s\n' "$UP_SECTION" | sed 's/board-web\.log/gone/' | grep -qF -- "$BOARD_LOG_CLAIM"; then
  fail "board-web.log check fails when the statement is removed"
else
  pass "board-web.log check fails when the statement is removed"
fi

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
