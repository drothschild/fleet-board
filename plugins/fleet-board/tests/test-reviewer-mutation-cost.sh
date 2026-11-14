#!/usr/bin/env bash
# Wording contract for the reviewer's mutation step (agents/reviewer.md, its behavior spec, and the
# provider prompt scripts/providers/evidence-review-prompt.md). A reviewer re-ran every mapped test
# file after each restore and re-ran every touched suite per mutant, so a planner card's review took
# about an hour. These checks pin the instructions only; they are not a behavioral test of a session.
set -uo pipefail
unset CDPATH
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$HERE/.."
SPEC="$PLUGIN/../../docs/implementation-plans/2026-09-28-fleet-board/specs/reviewer.md"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

check() { # <label> <file>
  local label="$1" f="$2"
  # Any wording that has a mutant's test re-run after the restore, in either spelling
  if grep -qiE 'green again|re-?runs? (it|the same test command|the same test)[^.]*green|re-?run to confirm green' "$f"; then
    fail "$label: no re-run of the test after a mutant is restored"
  else
    pass "$label: no re-run of the test after a mutant is restored"
  fi
  # A restore is checked across the whole worktree, against a baseline saved before the first mutant
  if grep -qF 'prints exactly the baseline' "$f" && grep -qiE 'save[sd]? (the output of )?`git status --porcelain` as the baseline' "$f"; then
    pass "$label: the whole worktree is confirmed back at its baseline before the next mutant"
  else
    fail "$label: the whole worktree is confirmed back at its baseline before the next mutant"
  fi
  if grep -qF 'only the mapped test' "$f"; then
    pass "$label: a mutant runs only the mapped test"
  else
    fail "$label: a mutant runs only the mapped test"
  fi
  if grep -qF 'exactly one test ran' "$f"; then
    pass "$label: a single-case run counts only when exactly one test ran"
  else
    fail "$label: a single-case run counts only when exactly one test ran"
  fi
}

check "agents/reviewer.md" "$PLUGIN/agents/reviewer.md"
check "providers/evidence-review-prompt.md" "$PLUGIN/scripts/providers/evidence-review-prompt.md"
if [ -f "$SPEC" ]; then check "specs/reviewer.md" "$SPEC"; else echo "  skip specs/reviewer.md (specs directory absent)"; fi

printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
