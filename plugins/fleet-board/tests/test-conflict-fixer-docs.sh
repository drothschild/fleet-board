#!/usr/bin/env bash
#
# Plain-bash checks for the conflict-via-the-fixer card: the fixer spec and agent
# carry the conflict-region exception, and docs/config.md says the fixer resolves
# a conflict in the update-branch section.
#
# Usage: bash plugins/fleet-board/tests/test-conflict-fixer-docs.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
SPEC="$ROOT/../../docs/implementation-plans/2026-09-28-fleet-board/specs/fixer.md"
PASS=0
FAIL=0

check() { # <name> <file> <fixed string>
  if grep -qF -- "$3" "$2"; then PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s lacks: %s\n' "$2" "$3"; fi
}

# The update-branch paragraph of docs/config.md (the "Conflicting PRs." paragraph)
section() { grep -F '**Conflicting PRs.**' "$ROOT/docs/config.md"; }
check_section() { # <name> <fixed string>
  if section | grep -qF -- "$2"; then PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       the Conflicting PRs paragraph lacks: %s\n' "$2"; fi
}

check "spec: fixer.md names the conflict region exception" "$SPEC" "conflict region"
check "agent: fixer.md names the conflict region exception" "$ROOT/agents/fixer.md" "conflict region"
check "agent: fixer re-runs the merge of the base" "$ROOT/agents/fixer.md" "merge commit"
check "agent: fixer keeps every test and assertion from both sides" "$ROOT/agents/fixer.md" "every test and assertion from both sides"
check_section "docs: the update-branch section says the fixer resolves a conflict" "fixer"
check_section "docs: the update-branch section names conflicted_files" "conflicted_files"

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
