#!/usr/bin/env bash
#
# Offline checks for board-web.py: board_context() makes no gh call when every card's
# manager note records its PR state, and states() lists the configured board states.
# A logging fake gh sits first on PATH, so no test here reaches the network.
# Needs python3 and jq.
#
# Usage: bash plugins/fleet-board/tests/test-board-context-offline.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPTS="$(cd "$SCRIPT_DIR/../scripts" && pwd)"
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
BIN="$TMP/bin"
GHLOG="$TMP/gh.log"
export SCRIPTS REPO GHLOG
git init -q "$REPO"
printf 'board:\n  repo: acme/toy\n' > "$REPO/.fleet-board.yml"
mkdir -p "$REPO/.fleet-board/cards" "$BIN"
echo 3 > "$REPO/.fleet-board/next"
# fake gh: logs every call; reports PR 12 as merged so a stray call would also change the result
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$GHLOG"
echo '[{"number":12,"state":"MERGED","isDraft":false}]'
GH
chmod +x "$BIN/gh"

NOTE="$(printf '<!-- fleet-board:manager-note -->\n```json\n{"pr":12,"pr_state":"draft","round":2}\n```\n')"
NOTES="$(jq -n --arg b "$NOTE" '[{id: 1, author: "tester", body: $b, created_at: "2026-01-01T00:00:00Z"}]')"
seed() { # n state title comments-json
  jq -n --argjson n "$1" --arg s "$2" --arg t "$3" --argjson c "$4" \
    '{number: $n, title: $t, body: "x", state: $s, labels: [], created_at: "2026-01-01T00:00:00Z",
      updated_at: "2026-01-01T00:00:00Z", next_comment_id: (($c | length) + 1), comments: $c}' \
    > "$REPO/.fleet-board/cards/$1.json"
}
seed 1 backlog One '[]'
seed 2 in_progress Two "$NOTES"

OUT="$(PATH="$BIN:$PATH" python3 -I - <<'PYEOF'
import importlib.util, json, os
spec = importlib.util.spec_from_file_location("board_web", os.path.join(os.environ["SCRIPTS"], "board-web.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.APP.update(root=os.environ["REPO"], scripts=os.environ["SCRIPTS"])
snap = m.board_context()
try:
    cfg, _ = m.ctx()
    st = [s["key"] for s in m.states(cfg)]
    st_err = None
except Exception as e:
    st, st_err = [], "%s: %s" % (type(e).__name__, e)
print(json.dumps({"snap": snap, "states": st, "states_err": st_err}))
PYEOF
)"

if [ ! -s "$GHLOG" ]; then
  pass "board_context() makes no gh call when every manager note records pr_state"
else
  fail "board_context() makes no gh call when every manager note records pr_state" "$(cat "$GHLOG")"
fi
if [ "$(jq -r '.snap[1].pr | "\(.number) \(.state)"' <<<"$OUT" 2>/dev/null)" = "12 draft" ]; then
  pass "the recorded pr_state is reported for the card's PR"
else
  fail "the recorded pr_state is reported for the card's PR" "$OUT"
fi
if [ "$(jq -r '.states_err' <<<"$OUT" 2>/dev/null)" = null ] \
  && [ "$(jq -r '.states | index("backlog") != null and index("done") != null' <<<"$OUT" 2>/dev/null)" = true ]; then
  pass "states() lists the configured board states on an uncached call"
else
  fail "states() lists the configured board states on an uncached call" "$OUT"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
