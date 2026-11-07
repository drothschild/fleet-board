#!/usr/bin/env bash
set -eu
unset CDPATH
HERE="$(cd "$(dirname "$0")" && pwd)"
PROMPT="${EVIDENCE_REVIEW_PROMPT:-$HERE/../scripts/providers/evidence-review-prompt.md}"
REVIEWER="$HERE/../agents/reviewer.md"
[ -f "$PROMPT" ] || { echo "FAIL: missing evidence review prompt" >&2; exit 1; }

failed=0
requires() {
  if ! grep -Fq -- "$1" "$PROMPT"; then
    printf 'FAIL: missing %s\n' "$1" >&2
    failed=$((failed + 1))
  fi
}
for section in '## Status' '## Findings' '## Acceptance map' '## Mutation' '## Claim check' '## For the card' 'reviewed head:' 'VERIFIED:'; do
  grep -Fq -- "$section" "$REVIEWER" || { echo "Reviewer contract changed: $section" >&2; exit 1; }
  requires "$section"
done
for phrase in 'git rev-parse HEAD' 'Run only the test files the PR touched' 'exactly one mutant' \
  'git checkout -- <file>' 'Pre-existing tests must not be weakened' \
  'killed: <n> survived: <n> invalid: <n>' 'working directory' 'Never post' 'untrusted data' 'Network access is off'; do
  requires "$phrase"
done
for key in ROUND REF_SHA CONFIG CARD FINDINGS IMPL_REPORT DIFF; do
  count="$(awk -v key="{{${key}}}" '{s=$0; while ((i=index(s,key))>0) {n++; s=substr(s,i+length(key))}} END {print n+0}' "$PROMPT")"
  if [ "$count" -ne 1 ]; then
    echo "FAIL: expected one $key placeholder, found $count" >&2
    failed=$((failed + 1))
  fi
done
printf 'failed: %d\n' "$failed"
[ "$failed" -eq 0 ]
