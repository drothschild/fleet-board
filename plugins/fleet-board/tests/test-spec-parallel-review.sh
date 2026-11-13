#!/usr/bin/env bash
#
# Plain-bash test that the review-stages design spec states the parallel review
# model: same-head parallel reviewers, the leave-In-Review rule, one fixer
# dispatch per round, and the default / required_passes / enabled keys with the
# built-in stages.
#
# Usage: bash plugins/fleet-board/tests/test-spec-parallel-review.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DOC="$SCRIPT_DIR/../../../docs/specs/2026-11-06-review-stages-design.md"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

doc_has() {
  if grep -qiF -- "$2" "$DOC"; then pass "$1"; else fail "$1 (missing: $2)"; fi
}

echo "the spec states that the evidence reviewer and every routed stage review the same head in parallel while the card stays in in_review"
doc_has "parallel: evidence reviewer and routed stages run in parallel" "evidence reviewer and every routed stage review the same head in parallel"
doc_has "parallel: card stays in in_review" "while the card stays in \`in_review\`"

echo "the spec states that a card leaves In Review only when every routed reviewer has met its required passes at the current head"
doc_has "leave: only when every routed reviewer met required passes" "leaves In Review only when every routed reviewer has met its required passes at the current head"

echo "the spec states that all reviewers' findings go to one fixer dispatch and the next round re-runs every reviewer"
doc_has "fixer: one dispatch for all findings" "all reviewers' findings go to one fixer dispatch"
doc_has "fixer: next round re-runs every reviewer" "the next round re-runs every reviewer"

echo "the spec defines default, required_passes, enabled, and the built-in stages documentation and blast_radius, including that existing projects get the built-ins"
doc_has "keys: default defined" "\`default\`:"
doc_has "keys: required_passes defined" "\`required_passes\`:"
doc_has "keys: enabled defined" "\`enabled\`:"
doc_has "built-in: documentation" "\`documentation\`"
doc_has "built-in: blast_radius" "\`blast_radius\`"
doc_has "built-in: existing projects get the built-ins" "existing projects get the built-in stages"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
