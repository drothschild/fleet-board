#!/usr/bin/env bash
# Checks docs/design.md: nine decision headings, Alternative + Because/Reason per
# section, 1500-2500 words, one mermaid block, card 393 example, README links.
# Usage: test-design-doc.sh [doc]   (defaults to docs/design.md in the repo root)
unset CDPATH
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="${1:-$ROOT/docs/design.md}"
fail=0
bad() { echo "FAIL: $1"; fail=1; }

# keyword regex per decision heading (matched against "## " lines, case-insensitive)
KEYS=(
  "one step per card"
  "never move cards"
  "manager note"
  "fail closed"
  "text check"
  "evidence-based review"
  "escalation"
  "human qa"
  "clean-room"
)

[ -f "$DOC" ] || { echo "FAIL: $DOC does not exist"; exit 1; }

section() { # print the body of the section whose "## " heading matches $1
  awk -v k="$1" 'BEGIN{IGNORECASE=1}
    /^## /{on=(tolower($0) ~ k); if(on)print; next} on{print}' "$DOC"
}

for k in "${KEYS[@]}"; do
  n=$(grep -ci "^## .*$k" "$DOC")
  if [ "$n" -ne 1 ]; then bad "expected exactly one heading matching '$k', found $n"; continue; fi
  body="$(section "$k")"
  echo "$body" | grep -Eq 'Alternative[^[:space:]]*[[:space:]]+[^[:space:]]' \
    || bad "section '$k' lacks 'Alternative' followed by text"
  echo "$body" | grep -Eiq '(Because|Reason)' \
    || bad "section '$k' lacks 'Because' or 'Reason'"
done

words=$(wc -w < "$DOC" | tr -d ' ')
{ [ "$words" -ge 1500 ] && [ "$words" -le 2500 ]; } || bad "word count $words not in 1500-2500"

m=$(grep -c '^```mermaid' "$DOC")
[ "$m" -eq 1 ] || bad "expected one mermaid block, found $m"

section "evidence-based review" | grep -q '393' || bad "evidence section lacks card 393 example"
section "evidence-based review" | grep -qi 'survivor' || bad "evidence section lacks mutation survivor"

for r in "$ROOT/README.md" "$ROOT/plugins/fleet-board/README.md"; do
  grep -q 'docs/design.md' "$r" || bad "$r does not link docs/design.md"
done

# self-check: removing any one heading must make the heading check fail
if [ -z "${DESIGN_DOC_INNER:-}" ] && [ "$fail" -eq 0 ]; then
  for k in "${KEYS[@]}"; do
    t="$(mktemp)"
    awk -v k="$k" 'BEGIN{IGNORECASE=1} /^## /&&tolower($0)~k{next}{print}' "$DOC" > "$t"
    if DESIGN_DOC_INNER=1 bash "$0" "$t" >/dev/null 2>&1; then
      bad "removing heading '$k' did not fail the test"
    fi
    rm -f "$t"
  done
fi

[ "$fail" -eq 0 ] && echo "PASS: design doc ok ($words words)"
exit "$fail"
