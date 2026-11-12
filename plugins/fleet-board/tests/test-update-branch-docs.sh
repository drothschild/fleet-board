#!/usr/bin/env bash
#
# Plain-bash checks for the update_branch card: the role agents keep their
# never-rebase / never-force-push rules and
# docs/config.md documents it.
#
# Usage: bash plugins/fleet-board/tests/test-update-branch-docs.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
PASS=0
FAIL=0

check() { # <name> <file> <fixed string>
  if grep -qF -- "$3" "$2"; then PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s lacks: %s\n' "$2" "$3"; fi
}

check "fixer: never force-push or rebase" "$ROOT/agents/fixer.md" "Never force-push, rebase and rewrite published commits"
check "fixer: plain git push" "$ROOT/agents/fixer.md" "plain \`git push\` (never forced)"
check "implementor: push never with force" "$ROOT/agents/implementor.md" "never with force"
check "implementor: no force-push or rewrite" "$ROOT/agents/implementor.md" "Force-push, amend or rewrite commits already on the branch"
# The two manager.md checks went with the tick system: driver_cases.py test_update_branch_runs_worktree_then_script
# pins that the supervisor's driver runs update-branch.sh for update_branch.
check "docs/config.md documents update_branch" "$ROOT/docs/config.md" "the action \`update_branch\`"
check "docs/config.md names update-branch.sh" "$ROOT/docs/config.md" "scripts/update-branch.sh"
check "docs/config.md: never force-pushes" "$ROOT/docs/config.md" "never force-pushes"

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
