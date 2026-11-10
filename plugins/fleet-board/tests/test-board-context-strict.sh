#!/usr/bin/env bash
#
# Stricter checks for board_context(): every entry's labels, real board-list.sh process
# count, and PR state taken from the PR itself (fake gh). Needs python3 and jq.
#
# Usage: bash plugins/fleet-board/tests/test-board-context-strict.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/../scripts" && pwd)"
unset FLEET_BOARD_CONFIG FLEET_BOARD_LOCK_WAIT || true
FLEET_BOARD_USER=tester
export FLEET_BOARD_USER

command -v python3 >/dev/null 2>&1 || { echo "skipped: python3 not on PATH"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skipped: jq not on PATH"; exit 0; }

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "ok - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "not ok - $1: ${2:-}"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/tmp.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"
SCRIPTS="$TMP/scripts"
BIN="$TMP/bin"
LOG="$TMP/list.log"
export SCRIPTS LOG REPO
git init -q "$REPO"
printf 'board:\n  repo: acme/toy\n' > "$REPO/.fleet-board.yml"
mkdir -p "$REPO/.fleet-board/cards" "$BIN"
echo 4 > "$REPO/.fleet-board/next"
cp -R "$SRC" "$SCRIPTS"
# log every real board-list.sh process
sed -i.bak '2i\
echo run >> "$LOG"' "$SCRIPTS/board-list.sh"
# fake gh: PR 12 draft, 13 merged, 14 closed, 15 open
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
echo '[{"number":12,"state":"OPEN","isDraft":true},{"number":13,"state":"MERGED","isDraft":false},{"number":14,"state":"CLOSED","isDraft":false},{"number":15,"state":"OPEN","isDraft":false}]'
GH
chmod +x "$BIN/gh"

seed() { # n state title labels-json pr
  local notes='[]'
  if [ -n "${5:-}" ]; then
    local note
    note="$(printf '<!-- fleet-board:manager-note -->\n```json\n{"pr":%s,"round":1}\n```\n' "$5")"
    notes="$(jq -n --arg b "$note" '[{id: 1, author: "tester", body: $b, created_at: "2026-01-01T00:00:00Z"}]')"
  fi
  jq -n --argjson n "$1" --arg s "$2" --arg t "$3" --argjson l "$4" --argjson c "$notes" \
    '{number: $n, title: $t, body: "x", state: $s, labels: $l, created_at: "2026-01-01T00:00:00Z",
      updated_at: "2026-01-01T00:00:00Z", next_comment_id: 2, comments: $c}' \
    > "$REPO/.fleet-board/cards/$1.json"
}
seed 1 backlog One '["a"]' ""
seed 2 in_progress Two '["b","c"]' 12
seed 3 ready Three '["d"]' 13
seed 4 done Four '[]' 14
seed 5 ready Five '[]' 15

OUT="$(PATH="$BIN:$PATH" python3 -I - <<'PYEOF'
import importlib.util, json, os
spec = importlib.util.spec_from_file_location("board_web", os.path.join(os.environ["SCRIPTS"], "board-web.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.APP.update(root=os.environ["REPO"], scripts=os.environ["SCRIPTS"])
cache = {}
snap = m.board_context(cache)
again = m.board_context(cache)
print(json.dumps({"snap": snap, "same": snap is again}))
PYEOF
)"

if [ "$(jq -c '[.snap[] | .labels]' <<<"$OUT" 2>/dev/null)" = '[["a"],["b","c"],["d"],[],[]]' ]; then
  pass "every entry carries its own labels"
else
  fail "every entry carries its own labels" "$OUT"
fi
if [ "$(wc -l < "$LOG" | tr -d ' ')" = 1 ]; then
  pass "one snapshot (and its cached reuse) launches exactly one board-list.sh process"
else
  fail "one snapshot launches exactly one board-list.sh process" "$(cat "$LOG" 2>/dev/null)"
fi
if [ "$(jq -c '[.snap[] | .pr.state]' <<<"$OUT" 2>/dev/null)" = '[null,"draft","merged","closed","open"]' ]; then
  pass "PR state comes from the PR: draft, merged, closed and open"
else
  fail "PR state comes from the PR" "$OUT"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
