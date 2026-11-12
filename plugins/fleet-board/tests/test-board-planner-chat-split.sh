#!/usr/bin/env bash
#
# Plain-bash test: Draft cards in the planner chat box plays the split
# animation (the sheet gets the "split" class) for the returned import.
# Needs node.
#
# Usage: bash plugins/fleet-board/tests/test-board-planner-chat-split.sh

set -uo pipefail
unset CDPATH
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
STATIC="$(cd "$SCRIPT_DIR/../scripts/board-web/static" && pwd)"
command -v node >/dev/null 2>&1 || { echo "skipped: node not on PATH"; exit 0; }

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

DRIVER="$(mktemp)"
trap 'rm -f "$DRIVER"' EXIT
cat > "$DRIVER" <<'JS'
"use strict";
const path = require("node:path");
const loadBoard = require(path.join(process.argv[2], "board-interaction-harness.js"));
const boardJs = path.join(process.argv[3], "board.js");
process.on("unhandledRejection", () => {});
const ok = (name, cond, info) => console.log((cond ? "ok   " : "FAIL ") + name + (cond ? "" : "\t" + info));
(async () => {
  const states = [{key: "backlog", name: "Backlog"}, {key: "ready", name: "Ready"}];
  const h = loadBoard(boardJs, async (url, opts) => {
    let data;
    if (url === "/api/board") data = {repo: "acme/toy", states, cards: [], run: {state: "idle"}};
    else if (url === "/api/planner" && opts.method === "POST") data = {id: "c1"};
    else if (url === "/api/planner/c1/draft") data = {import_id: "imp7"};
    else if (url === "/api/planner/c1/messages") data = {ok: true};
    else if (url === "/api/planner/c1") data = {running: false, turns: [{role: "user", text: "plan"}, {role: "assistant", text: "reply"}]};
    else if (url === "/api/import/imp7") data = {state: "ready", elapsed_s: 2, table: "t", cards: {cards: [{key: "a", title: "A"}, {key: "b", title: "B"}]}};
    else throw new Error("Unexpected request: " + opts.method + " " + url);
    return {ok: true, status: 200, json: async () => data};
  });
  const runTimers = async () => { const t = h.timers.splice(0); for (const fn of t) { try { await fn(); } catch (e) {} } await h.flush(); };
  // Reduced motion: playSplit goes straight to the end state, which the DOM
  // harness (no layout, so no getBoundingClientRect) can observe.
  h.ctx.matchMedia = () => ({matches: true});
  await h.flush();
  try {
    await h.$("plan-btn").fire("click");
    h.$("pl-input").value = "plan";
    await h.$("pl-send").fire("click");
    await runTimers();
    await h.$("pl-draft").fire("click");
    await runTimers();
    await runTimers();
    ok("the import sheet is split for the returned import", h.$("imp-sheet").classList.contains("split"), "className=" + h.$("imp-sheet").className);
  } catch (e) {
    ok("split animation run without an error", false, String(e && e.message || e));
  }
})();
JS
OUT="$(node "$DRIVER" "$SCRIPT_DIR" "$STATIC" 2>&1)"
while IFS= read -r line; do
  case "$line" in
    "ok   "*) pass "${line#ok   }" ;;
    "FAIL "*) fail "${line#FAIL }" "" ;;
  esac
done <<EOT
$OUT
EOT
case "$OUT" in *"ok   "*) ;; *) fail "driver produced results" "$OUT" ;; esac

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
