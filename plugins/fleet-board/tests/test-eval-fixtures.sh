#!/usr/bin/env bash
#
# Plain-bash tests for the reviewer-eval fixtures (offline, no claude, no gh).
# Asserts: >= 3 fixture PRs whose suites pass unmodified; a catalogue with the six
# defect classes; every patch applies cleanly (git apply --check); and after each
# patch the fixture PR's suite still passes (the defect is one the tests miss).
#
# Usage: bash plugins/fleet-board/tests/test-eval-fixtures.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
EVAL="${SCRIPT_DIR}/eval"
FIX="${EVAL}/fixture"
CAT="${EVAL}/defects/catalogue.tsv"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fb-eval-fixtures.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# --- fixture PRs ---------------------------------------------------------
prs=()
if [ -d "$FIX" ]; then
  for d in "$FIX"/*/; do
    [ -f "${d}test.sh" ] && prs+=("$(basename "$d")")
  done
fi
if [ "${#prs[@]}" -ge 3 ]; then
  pass "at least 3 fixture PRs exist (${#prs[@]})"
else
  fail "at least 3 fixture PRs exist" "found ${#prs[@]} under $FIX"
fi

for pr in ${prs[@]+"${prs[@]}"}; do
  if [ ! -s "$FIX/$pr/card.md" ] || ! grep -q '^## Acceptance' "$FIX/$pr/card.md" \
     || ! grep -q '^- ' "$FIX/$pr/card.md"; then
    fail "$pr has a card.md with Acceptance bullets" "missing or empty"
  else
    pass "$pr has a card.md with Acceptance bullets"
  fi
  if out="$(bash "$FIX/$pr/test.sh" 2>&1)"; then
    pass "$pr: unmodified suite passes"
  else
    fail "$pr: unmodified suite passes" "$(printf '%s' "$out" | tail -5)"
  fi
done

# --- catalogue -----------------------------------------------------------
# Columns (tab-separated): id, class, pr, patch file, report pattern (ERE)
if [ ! -s "$CAT" ]; then
  fail "catalogue exists" "missing or empty: $CAT"
  printf '\npassed: %d   failed: %d\n' "$PASS" "$FAIL"
  exit 1
fi
pass "catalogue exists"

for class in off-by-one source-text-assertion weakened-assertion untested-bullet \
             mocked-dependency happy-path-only; do
  if awk -F'\t' -v c="$class" '$2 == c { f = 1 } END { exit !f }' "$CAT"; then
    pass "catalogue has class $class"
  else
    fail "catalogue has class $class" "no row with class $class"
  fi
done

while IFS="$(printf '\t')" read -r id class pr patch pattern; do
  [ -z "$id" ] && continue
  case "$id" in \#*) continue ;; esac
  work="$TMP/$id"
  mkdir -p "$work"
  if [ ! -d "$FIX/$pr" ] || [ ! -f "$EVAL/defects/$patch" ]; then
    fail "$id: fixture $pr and patch $patch exist" "missing"
    continue
  fi
  cp -R "$FIX/$pr/." "$work/"
  if (cd "$work" && git apply --check "$EVAL/defects/$patch") 2>"$TMP/err"; then
    pass "$id: patch applies cleanly to $pr (git apply --check)"
  else
    fail "$id: patch applies cleanly to $pr (git apply --check)" "$(cat "$TMP/err")"
    continue
  fi
  (cd "$work" && git apply "$EVAL/defects/$patch")
  if ! diff -rq "$FIX/$pr" "$work" >/dev/null 2>&1; then
    pass "$id: patch changes the fixture"
  else
    fail "$id: patch changes the fixture" "no difference after applying"
  fi
  if out="$(bash "$work/test.sh" 2>&1)"; then
    pass "$id: suite still passes after the defect"
  else
    fail "$id: suite still passes after the defect" "$(printf '%s' "$out" | tail -5)"
  fi
done < "$CAT"

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
