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

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
