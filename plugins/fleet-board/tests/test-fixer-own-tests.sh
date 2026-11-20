#!/usr/bin/env bash
#
# Plain-bash checks for the fixer-may-edit-its-own-PR's-tests card: the fixer brief,
# the fixer spec and plugins/fleet-board/CLAUDE.md state the same rule.
#
# Usage: bash plugins/fleet-board/tests/test-fixer-own-tests.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
AGENT="$ROOT/agents/fixer.md"
SPEC="$ROOT/../../docs/implementation-plans/2026-09-28-fleet-board/specs/fixer.md"
CLAUDE_MD="$ROOT/CLAUDE.md"
PASS=0
FAIL=0

ALLOW="may edit a test file that the PR adds or modifies against the merge base to resolve a finding"
DENY="still may not edit a test file unchanged relative to the base branch"
NOWEAK="no weakening of what the test checks"

check() { # <name> <file> <fixed string>
  if grep -qF -- "$3" "$2"; then PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s lacks: %s\n' "$2" "$3"; fi
}

echo "fixer own-test rule"

check "agent: the fixer may edit a test file the PR adds or modifies against the merge base" "$AGENT" "$ALLOW"
check "spec: the fixer may edit a test file the PR adds or modifies against the merge base" "$SPEC" "$ALLOW"
check "agent: it still may not edit a test file unchanged relative to the base branch" "$AGENT" "$DENY"
check "spec: it still may not edit a test file unchanged relative to the base branch" "$SPEC" "$DENY"
check "agent: the rule no weakening of what the test checks" "$AGENT" "$NOWEAK"
check "spec: the rule no weakening of what the test checks" "$SPEC" "$NOWEAK"
check "agent: the report names each test file it edited and why" "$AGENT" "name each test file you edited and why"
check "spec: the report names each test file it edited and why" "$SPEC" "names each test file it edited and why"
check "CLAUDE.md: states the allowance in the agent's terms" "$CLAUDE_MD" "$ALLOW"
check "CLAUDE.md: states the ban on unchanged test files in the agent's terms" "$CLAUDE_MD" "$DENY"
check "CLAUDE.md: states no weakening of what the test checks" "$CLAUDE_MD" "$NOWEAK"

# Mutant: removing the sentence that allows edits from the agent file must fail the check.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
grep -vF -- "$ALLOW" "$AGENT" >"$TMP/fixer.md"
if grep -qF -- "$ALLOW" "$TMP/fixer.md"; then
  FAIL=$((FAIL + 1)); printf '  FAIL mutant: the sentence was not removed\n'
elif ! grep -qF -- "$ALLOW" "$TMP/fixer.md" && [ -s "$TMP/fixer.md" ]; then
  # the check helper, run on the mutant, must report a failure
  OUT="$(check "mutant" "$TMP/fixer.md" "$ALLOW"; true)"
  if printf '%s' "$OUT" | grep -q 'FAIL mutant'; then
    PASS=$((PASS + 1)); printf '  ok   mutant: agent without the allowing sentence fails the check\n'
  else
    FAIL=$((FAIL + 1)); printf '  FAIL mutant: check passed on the mutated agent\n'
  fi
fi

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
