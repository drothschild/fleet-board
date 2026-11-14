#!/usr/bin/env bash
# Wording contract for the reviewer's mutation step (agents/reviewer.md and the provider prompt
# scripts/providers/evidence-review-prompt.md). A reviewer re-ran every mapped test file after each
# restore and re-ran every touched suite per mutant, so a planner card's review took about an hour.
# These checks pin the instructions only; they are not a behavioral test of a reviewer session.
set -uo pipefail
unset CDPATH
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$HERE/.."
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

for f in agents/reviewer.md scripts/providers/evidence-review-prompt.md; do
  text="$(cat "$PLUGIN/$f")"
  case "$text" in
    *'Re-run the same test command and confirm it is green again'*|*'rerun to confirm green'*)
      fail "$f: no rerun of the test after a mutant is restored" ;;
    *) pass "$f: no rerun of the test after a mutant is restored" ;;
  esac
  case "$text" in
    *'git diff --quiet -- <file>'*) pass "$f: a restore is confirmed with git diff --quiet" ;;
    *) fail "$f: a restore is confirmed with git diff --quiet" ;;
  esac
  case "$text" in
    *'only the mapped test'*) pass "$f: a mutant runs only the mapped test" ;;
    *) fail "$f: a mutant runs only the mapped test" ;;
  esac
done

printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
