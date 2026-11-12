#!/usr/bin/env bash
#
# Plain-bash tests for scripts/pr-body-check.sh: a fleet PR body must not hold a
# GitHub closing keyword followed by an issue reference. Card numbers on the
# local board are not GitHub numbers, so "Closes #253" closes whatever GitHub
# issue or PR has number 253 when the fleet PR merges.
# Also pins that no shipped primitive tells a role to write one.
#
# Usage: bash plugins/fleet-board/tests/test-pr-body-check.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN="$SCRIPT_DIR/.."
CHECK="$PLUGIN/scripts/pr-body-check.sh"

PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  not ok %s\n' "$1"; printf '       %s\n' "$2"; }

# run_check TEXT -> RC, ERR (TEXT written to a file, checked by path)
run_check() {
  printf '%s\n' "$1" > "$TMP/body"
  ERR="$(/bin/bash "$CHECK" "$TMP/body" 2>&1 >/dev/null)"
  RC=$?
}

expect_reject() {
  run_check "$1"
  if [ "$RC" = 1 ] && [ -n "$ERR" ]; then pass "rejects: $1"
  else fail "rejects: $1" "rc=$RC err=$ERR"; fi
}

expect_accept() {
  run_check "$1"
  if [ "$RC" = 0 ]; then pass "accepts: $1"
  else fail "accepts: $1" "rc=$RC err=$ERR"; fi
}

echo "pr-body-check.sh"

for kw in close closes closed fix fixes fixed resolve resolves resolved; do
  expect_reject "$kw #253"
done
expect_reject "Closes #253"
expect_reject "CLOSES #253"
expect_reject "Fixes: #12"
expect_reject "Resolves:#12"
expect_reject "Some prose. Closes #7 and more."
expect_reject "- fixes owner/repo#45"
expect_reject "Closes https://github.com/owner/repo/issues/45"
expect_reject "resolves https://github.com/owner/repo/pull/46"
expect_reject "$(printf 'Summary line\n\nLocal board card 253\nCloses #253')"
expect_reject "Fixes GH-12"
expect_reject "closes gh-12"
expect_reject "**Closes** #1"
expect_reject "_Fixes_ #1"
expect_reject "Closes **#1**"
expect_reject "Closes : #1"
expect_reject "Resolves <https://github.com/owner/repo/issues/3>"

expect_accept "Local board card 253"
expect_accept "Card 253 (local board; not a GitHub issue)"
expect_accept "Closes the lock race; see card 253"
expect_accept "prefixes #12"
expect_accept "unfixed #12"
expect_accept "See #253 for context"
expect_accept ""

# Reads stdin with "-".
printf 'Fixes #9\n' | /bin/bash "$CHECK" - >/dev/null 2>&1; rc=$?
if [ "$rc" = 1 ]; then pass "reads stdin with -"; else fail "reads stdin with -" "rc=$rc"; fi

# Fails closed when grep itself fails (exit 2, not 0).
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nexit 2\n' > "$TMP/bin/grep"; chmod +x "$TMP/bin/grep"
printf 'Local board card 1\n' > "$TMP/body"
PATH="$TMP/bin:$PATH" /bin/bash "$CHECK" "$TMP/body" >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ]; then pass "grep failure exits 2"; else fail "grep failure exits 2" "rc=$rc"; fi

# Usage error.
/bin/bash "$CHECK" >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ]; then pass "no argument exits 2"; else fail "no argument exits 2" "rc=$rc"; fi
/bin/bash "$CHECK" "$TMP/missing" >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ]; then pass "missing file exits 2"; else fail "missing file exits 2" "rc=$rc"; fi

echo "shipped primitives"

# No agent, skill or script tells a role to put a closing keyword before a card
# number (e.g. "Closes #<card number>", "Fixes #$CARD").
hits="$(grep -rniE '(^|[^[:alnum:]_])(close[sd]?|fix(e[sd])?|resolve[sd]?):?[[:space:]]*#(<|\$|\{)' \
  "$PLUGIN/agents" "$PLUGIN/skills" "$PLUGIN/scripts" "$PLUGIN/hooks" "$PLUGIN/tests"/behavioral-*.sh 2>/dev/null)"
if [ -z "$hits" ]; then pass "no closing keyword before a card-number placeholder"
else fail "no closing keyword before a card-number placeholder" "$hits"; fi

# The implementor checks its PR body with pr-body-check.sh before gh pr create.
if grep -q 'pr-body-check.sh' "$PLUGIN/agents/implementor.md"; then pass "implementor runs pr-body-check.sh"
else fail "implementor runs pr-body-check.sh" "agents/implementor.md does not name pr-body-check.sh"; fi

# The PR is opened from the checked body file, never an inline --body.
if grep -q 'pr-body-check.sh <path> && gh pr create --draft' "$PLUGIN/agents/implementor.md" \
  && grep -q -- '--body-file <path>' "$PLUGIN/agents/implementor.md"; then pass "implementor chains the check with gh pr create --body-file"
else fail "implementor chains the check with gh pr create --body-file" "no 'pr-body-check.sh <path> && gh pr create --draft ... --body-file <path>'"; fi

# Commit messages are checked too: a squash merge copies them onto main.
if grep -q 'log --format=%B' "$PLUGIN/agents/implementor.md" && grep -q 'pr-body-check.sh -' "$PLUGIN/agents/implementor.md"; then pass "implementor checks commit messages"
else fail "implementor checks commit messages" "no git log --format=%B piped to pr-body-check.sh -"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
