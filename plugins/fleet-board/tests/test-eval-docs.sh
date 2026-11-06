#!/usr/bin/env bash
#
# Plain-bash tests for docs/reviewer-eval.md and its link from the README.
#
# Usage: bash plugins/fleet-board/tests/test-eval-docs.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOC="${PLUGIN}/docs/reviewer-eval.md"
README="${PLUGIN}/README.md"
CAT="${SCRIPT_DIR}/eval/defects/catalogue.tsv"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }
has() { grep -qE -- "$2" "$DOC" && pass "$1" || fail "$1" "pattern not found in docs/reviewer-eval.md: $2"; }

if [ -f "$DOC" ]; then pass "docs/reviewer-eval.md exists"; else fail "docs/reviewer-eval.md exists" "missing"; fi

# results-table template: header row plus a row for every defect class, with and without mutation
has "results table has a header with catch rate and cost columns" '^\| Class \|.*Catch rate.*Cost'
while IFS="$(printf '\t')" read -r id class _rest; do
  [ -z "$id" ] && continue
  case "$id" in \#*) continue ;; esac
  for m in on off; do
    if grep -qE "^\| ${id} \|.*\| ${m} \|" "$DOC" || grep -qE "^\| ${class} \|.*\| ${m} \|" "$DOC"; then
      pass "results table has a row for $id with mutation $m"
    else
      fail "results table has a row for $id with mutation $m" "row absent"
    fi
  done
done < "$CAT"

# exact commands
has "documents the dry-run command" 'run\.sh --dry-run'
has "documents a paid run with --runs, --mutation and --model" 'run\.sh --runs 3 --mutation (on|off) +--model'
has "documents the offline fixture test command" 'bash .*test-eval-fixtures\.sh'
has "documents the offline run test command" 'bash .*test-eval-run\.sh'

# cost line per run
has "has a cost-per-run section" '^### Cost per run'
has "cost line template records runs, total and mean" 'total \$.*mean \$'

# README link
if grep -qF '](docs/reviewer-eval.md)' "$README"; then
  pass "README links to docs/reviewer-eval.md"
else
  fail "README links to docs/reviewer-eval.md" "no link in README.md"
fi
if [ -f "${PLUGIN}/docs/reviewer-eval.md" ]; then pass "README link target resolves"; else fail "README link target resolves" "missing"; fi

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
