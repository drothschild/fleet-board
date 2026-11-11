#!/usr/bin/env bash
#
# Plain-bash test that the persistent-supervisor spec and plan describe the
# Merging column and the merger role (card 241).
#
# Usage: bash plugins/fleet-board/tests/test-spec-merging-column.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SPEC="$ROOT/docs/superpowers/specs/2026-11-07-persistent-supervisor-design.md"
PLAN="$ROOT/docs/superpowers/plans/2026-11-07-persistent-supervisor.md"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
has() { # name file pattern (extended regex)
  if grep -qE -- "$3" "$2"; then pass "$1"; else fail "$1 (missing: $3)"; fi
}

has "The spec lists merging as a board state after the review stages and human_qa, and before done" \
  "$SPEC" 'review stages.*`human_qa`.*`merging`.*`done`'
has "The spec defines a refused merge as --inspect showing the PR still open and unmerged at the same head" \
  "$SPEC" 'refused merge.*merge-reviewed\.sh --inspect.*open and unmerged at the same head'
has "A refused merge affects only that card" \
  "$SPEC" 'refused merge affects only that card'
has "An unclear merge result still stops new work on the whole board" \
  "$SPEC" 'unclear merge result.*stop new work on the whole board'
has "A failed main check still stops new work on the whole board" \
  "$SPEC" 'failed main check.*stop new work on the whole board'
has "The spec defines the merger report statuses retry, fix and attention" \
  "$SPEC" 'merger.*`retry`.*`fix`.*`attention`'
has "The merger persona cannot loosen any merge precondition" \
  "$SPEC" 'merger persona (can.t|cannot) loosen any merge precondition'
has "The plan has a new Phase 4 task listing M2 to M10" \
  "$PLAN" '^### Task 4\.4: .*M2.*M10'

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
