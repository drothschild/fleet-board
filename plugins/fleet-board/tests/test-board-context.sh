#!/usr/bin/env bash
#
# Plain-bash tests for board_context() in board-web.py: the planner's board snapshot.
# Needs python3 and jq.
#
# Usage: bash plugins/fleet-board/tests/test-board-context.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPTS="$(cd "$SCRIPT_DIR/../scripts" && pwd)"
export SCRIPTS
unset FLEET_BOARD_CONFIG FLEET_BOARD_LOCK_WAIT || true
FLEET_BOARD_USER=tester
export FLEET_BOARD_USER

command -v python3 >/dev/null 2>&1 || { echo "skipped: python3 not on PATH"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skipped: jq not on PATH"; exit 0; }

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "ok - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "not ok - $1: ${2:-}"; }

REPO="$(mktemp -d "${TMPDIR:-/tmp}/tmp.XXXXXX")"
trap 'rm -rf "$REPO"' EXIT
git init -q "$REPO"
printf 'board:\n  backend: local\n  repo: acme/toy\n' > "$REPO/.fleet-board.yml"
mkdir -p "$REPO/.fleet-board/cards"
echo 4 > "$REPO/.fleet-board/next"

# seed <n> <state> <title> <body> <labels-json> <comments-json>
seed() {
  jq -n --argjson n "$1" --arg s "$2" --arg t "$3" --arg b "$4" --argjson l "$5" --argjson c "$6" \
    '{number: $n, title: $t, body: $b, state: $s, labels: $l, created_at: "2026-01-01T00:00:00Z",
      updated_at: "2026-01-01T00:00:00Z", next_comment_id: (($c | length) + 1), comments: $c}' \
    > "$REPO/.fleet-board/cards/$1.json"
}
NOTE="$(printf '<!-- fleet-board:manager-note -->\n```json\n{"pr":12,"pr_state":"draft","round":2}\n```\n')"
NOTES="$(jq -n --arg b "$NOTE" '[{id: 1, author: "tester", body: $b, created_at: "2026-01-01T00:00:00Z"}]')"
seed 1 backlog "First" "Do it." '["a"]' '[]'
seed 2 in_progress "Second" "Do more.

## Depends on
- #1
- #3
" '["b","c"]' "$NOTES"
seed 3 ready "Third" "Do last." '[]' '[]'

OUT="$(REPO="$REPO" python3 -I - <<'PYEOF'
import importlib.util, json, os
spec = importlib.util.spec_from_file_location("board_web", os.path.join(os.environ["SCRIPTS"], "board-web.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.APP.update(root=os.environ["REPO"], scripts=os.environ["SCRIPTS"])
calls = []
real = m.run_script
def counting(root, argv, stdin=None):
    if "board-list" in " ".join(argv):
        calls.append(argv)
    return real(root, argv, stdin)
m.run_script = counting
snap = m.board_context()
print(json.dumps({"snap": snap, "list_calls": len(calls)}))
PYEOF
)"

if [ "$(jq -r '.snap | length' <<<"$OUT" 2>/dev/null)" = 3 ]; then
  pass "board_context() on a 3 card board returns 3 entries"
else
  fail "board_context() on a 3 card board returns 3 entries" "$OUT"
fi
if [ "$(jq -r '.snap[0] | [.number, .title, .state, (.labels | join(","))] | join("|")' <<<"$OUT" 2>/dev/null)" = "1|First|backlog|a" ]; then
  pass "each entry has number, title, state and labels"
else
  fail "each entry has number, title, state and labels" "$OUT"
fi
if [ "$(jq -r '.snap[1].pr | "\(.number) \(.state)"' <<<"$OUT" 2>/dev/null)" = "12 draft" ] \
  && [ "$(jq -r '.snap[0].pr' <<<"$OUT" 2>/dev/null)" = null ]; then
  pass "a card with an open draft PR has pr.state draft and its number; a card without a PR has pr null"
else
  fail "a card with an open draft PR has pr.state draft and its number; a card without a PR has pr null" "$OUT"
fi
if [ "$(jq -c '[.snap[1].depends_on, .snap[0].depends_on]' <<<"$OUT" 2>/dev/null)" = "[[1,3],[]]" ]; then
  pass "a card with a Depends on section lists those numbers in depends_on"
else
  fail "a card with a Depends on section lists those numbers in depends_on" "$OUT"
fi
if [ "$(jq -r '.list_calls' <<<"$OUT" 2>/dev/null)" = 1 ]; then
  pass "building one snapshot spawns at most one board-list subprocess"
else
  fail "building one snapshot spawns at most one board-list subprocess" "$OUT"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
