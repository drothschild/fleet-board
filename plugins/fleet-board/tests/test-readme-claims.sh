#!/usr/bin/env bash
#
# Plain-bash test: the README's card-writing section states that a whole
# dependency chain can be moved to Ready, and that nothing promotes a Backlog card.
#
# Usage: bash plugins/fleet-board/tests/test-readme-claims.sh
# README_FILE overrides the file checked (used to prove the test can fail).

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
README="${README_FILE:-${SCRIPT_DIR}/../README.md}"

PASS=0
FAIL=0

check() {
  if [ "$2" = "ok" ]; then
    PASS=$((PASS + 1)); echo "ok - $1"
  else
    FAIL=$((FAIL + 1)); echo "not ok - $1"
  fi
}

# The "### Writing a card" section: up to the next heading.
section="$(awk '/^### Writing a card/{f=1;next} f && /^##/{exit} f' "$README")"

r=bad
printf '%s\n' "$section" | grep -qF "Move the whole chain to Ready; each card starts on the first tick after its dependencies are Done." && r=ok
check "card-writing section says to move the whole chain to Ready" "$r"

r=bad
printf '%s\n' "$section" | grep -E "Backlog.*promotes|promotes.*Backlog" | grep -qi "nothing" && r=ok
check "card-writing section says nothing promotes a Backlog card" "$r"

# --- settle.sh docs claims (it runs outside the gate, so these are safety claims) ---
DOCS_DIR="${SCRIPT_DIR}/../docs"
GATES="${DOCS_DIR}/gates.md"
OVERNIGHT="${DOCS_DIR}/overnight.md"

gsec="$(awk '/^## settle\.sh runs outside the gate$/{f=1;next} f && /^## /{exit} f' "$GATES")"
r=bad
[ -n "$gsec" ] && r=ok
check "gates.md has the heading '## settle.sh runs outside the gate'" "$r"

r=bad
printf '%s\n' "$gsec" | grep -qi "never merges" && r=ok
check "gates.md settle.sh section says settle.sh never merges" "$r"

r=bad
printf '%s\n' "$gsec" | grep -qi "never moves a card out of human_qa" && r=ok
check "gates.md settle.sh section says it never moves a card out of human_qa" "$r"

settle_lines() { grep -F 'scripts/settle.sh' "$1"; }
for pair in "README:$README" "overnight.md:$OVERNIGHT"; do
  name="${pair%%:*}"; file="${pair#*:}"
  lines="$(settle_lines "$file")"
  r=bad; [ -n "$lines" ] && r=ok
  check "$name mentions scripts/settle.sh" "$r"
  r=bad; printf '%s\n' "$lines" | grep -qi "never merges" && r=ok
  check "$name says settle.sh never merges" "$r"
  r=bad; printf '%s\n' "$lines" | grep -qF 'interactive `/fleet-board:tick` does not run it' && r=ok
  check "$name says an interactive /fleet-board:tick does not run settle.sh" "$r"
done

# The overrides must work: a copy with the "never merges" sentence removed must fail.
if [ -z "${README_CLAIMS_NESTED:-}" ]; then
  tmp="$(mktemp -d)"
  for var in README_FILE GATES_FILE OVERNIGHT_FILE; do
    case "$var" in
      README_FILE) src="$README" ;;
      GATES_FILE) src="$GATES" ;;
      OVERNIGHT_FILE) src="$OVERNIGHT" ;;
    esac
    sed 's/never merges/may merge/g' "$src" > "$tmp/$var.md"
    r=bad
    if ! env README_CLAIMS_NESTED=1 "$var=$tmp/$var.md" bash "${BASH_SOURCE[0]:-$0}" >/dev/null 2>&1; then r=ok; fi
    check "$var pointing at a copy without 'never merges' makes the test fail" "$r"
  done
  rm -rf "$tmp"
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
