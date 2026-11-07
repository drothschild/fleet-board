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

# The key table has rows for the providers map and a stage's provider key.
r=bad
grep -qE '^\| `providers` \|' "$README" && r=ok
check "key table has a providers row" "$r"

r=bad
grep -qF '| `review.stages[].provider` |' "$README" && r=ok
check "key table has a review.stages[].provider row" "$r"

# The Config section's key table has a row for the review stages list.
r=bad
awk '/^## Config/{f=1;next} f && /^## /{exit} f' "$README" | grep -qF '| `review.stages` |' && r=ok
check "config table has a review.stages row" "$r"

# --- settle.sh docs claims (it runs outside the gate, so these are safety claims) ---
DOCS_DIR="${SCRIPT_DIR}/../docs"
GATES="${GATES_FILE:-${DOCS_DIR}/gates.md}"
OVERNIGHT="${OVERNIGHT_FILE:-${DOCS_DIR}/overnight.md}"

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

# --- docs sync (card 196) ---
ROOT="${SCRIPT_DIR}/../../.."
PLUGIN_CLAUDE="${SCRIPT_DIR}/../CLAUDE.md"
SPEC="${ROOT}/docs/superpowers/specs/2026-11-06-local-board-design.md"
CONFIG_MD="${DOCS_DIR}/config.md"

for pair in "plugin CLAUDE.md:$PLUGIN_CLAUDE" "overnight.md:$OVERNIGHT" "spec:$SPEC"; do
  name="${pair%%:*}"; file="${pair#*:}"
  r=bad; grep -q 'claim-run-lock' "$file" && r=ok
  check "$name names claim-run-lock" "$r"
done

r=bad; grep -F '`.lock.guard`' "$PLUGIN_CLAUDE" "$SPEC" | wc -l | grep -qv '^ *[01]$' && r=ok
check "plugin CLAUDE.md and spec both name .lock.guard" "$r"

r=bad; grep -i 'python3' "$PLUGIN_CLAUDE" | grep -qi 'every backend' && r=ok
check "plugin CLAUDE.md says the wrapper requires python3 on every backend" "$r"

r=bad; grep -F '| 1 |' "$OVERNIGHT" | grep -q 'python3' && r=ok
check "overnight.md exit-1 row names python3" "$r"

r=bad; grep -F 'launchd starts a job' "$OVERNIGHT" | grep -q 'python3' && r=ok
check "overnight.md launchd PATH paragraph names python3" "$r"

r=bad; grep -F '| `comment <n> <body-file>` |' "$SPEC" | grep -qi 'only.*accepted role report' && r=ok
check "spec comment row says the marker is removed only for an accepted role report" "$r"

r=bad; grep -F '`edit <n>' "$SPEC" | grep -q . && sed -n '/^- `edit <n>/,/^- `label/p' "$SPEC" | grep -qi 'empty' && sed -n '/^- `edit <n>/,/^- `label/p' "$SPEC" | grep -qi 'null' && r=ok
check "spec edit row states the empty-argument and null-labels contract" "$r"

r=bad; sed -n '/^## `board.dir` and `board.port`/,/^## Finding/p' "$CONFIG_MD" | grep -qi 'every backend' && r=ok
check "config.md says board.dir and board.port are checked on every backend" "$r"

r=bad; sed -n '/^## `board.dir` and `board.port`/,/^## Finding/p' "$CONFIG_MD" | grep -q 'apply only when' && r=bad || r=ok
check "config.md no longer says they apply only on local" "$r"

r=bad
grep -q 'local board' "${ROOT}/.claude-plugin/marketplace.json" && grep -q 'local board' "${SCRIPT_DIR}/../.claude-plugin/plugin.json" && r=ok
check "both manifests mention the local board" "$r"

r=bad; grep -qF 'Dependencies in the preview show as `owner/repo#n`' "$README" && r=ok
check "README says dependencies show as owner/repo#n in the preview" "$r"

r=bad; sed -n '/^## Local board/,/^## [^L]/p' "$README" | grep -q 'board.dir' && r=ok
check "README Local board section names board.dir" "$r"

r=bad; grep -A1 'Headless wrapper' "$PLUGIN_CLAUDE" | grep -qF 'overnight.md' && r=ok
check "plugin CLAUDE.md points at overnight.md" "$r"

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
