#!/usr/bin/env bash
#
# Plain-bash tests for the planner chat box on the board page: static markup
# checks on index.html plus a node DOM-harness run of board.js against a fake
# planner API. Needs node.
#
# Usage: bash plugins/fleet-board/tests/test-board-planner-chat-ui.sh

set -uo pipefail
unset CDPATH
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
STATIC="$(cd "$SCRIPT_DIR/../scripts/board-web/static" && pwd)"
command -v node >/dev/null 2>&1 || { echo "skipped: node not on PATH"; exit 0; }

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

echo "Case: index.html swaps the Import plan button for the planner chat panel"
if grep -q 'id="import-btn"' "$STATIC/index.html" || grep -q 'Import plan' "$STATIC/index.html"; then
  fail "index.html no longer contains the Import plan button" "found import-btn or the text Import plan"
else
  pass "index.html no longer contains the Import plan button"
fi
if grep -q 'id="plan-btn"' "$STATIC/index.html" && grep -q 'id="planner"' "$STATIC/index.html" \
  && grep -q 'id="pl-transcript"' "$STATIC/index.html" && grep -q 'id="pl-input"' "$STATIC/index.html" \
  && grep -q 'id="pl-draft"' "$STATIC/index.html"; then
  pass "index.html contains the Plan button and the planner chat panel"
else
  fail "index.html contains the Plan button and the planner chat panel" "plan-btn, planner, pl-transcript, pl-input or pl-draft missing"
fi

echo "Case: the chat box drives the planner API"
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
  const calls = [];
  let polls = 0, replyDone = false;
  const states = [{key: "backlog", name: "Backlog"}, {key: "ready", name: "Ready"}];
  const h = loadBoard(boardJs, async (url, opts) => {
    const body = opts.body && JSON.parse(opts.body);
    calls.push({url, method: opts.method, body});
    let data;
    if (url === "/api/board") data = {repo: "acme/toy", states, cards: [], run: {state: "idle"}};
    else if (url === "/api/run") data = {state: "idle"};
    else if (url === "/api/planner" && opts.method === "POST") data = {id: "c1"};
    else if (url === "/api/planner/c1/messages") data = {ok: true};
    else if (url === "/api/planner/c1/draft") data = {import_id: "imp7"};
    else if (url === "/api/planner/c1") {
      polls++;
      data = replyDone
        ? {running: false, turns: [{role: "user", text: "pasted plan"}, {role: "assistant", text: "reply one"}]}
        : {running: true, turns: [{role: "user", text: "pasted plan"}]};
    } else if (url === "/api/import/imp7") {
      data = {state: "ready", elapsed_s: 2, table: "t", cards: {cards: [{key: "a", title: "A"}, {key: "b", title: "B"}]}};
    } else throw new Error("Unexpected request: " + opts.method + " " + url);
    return {ok: true, status: 200, json: async () => data};
  });
  const runTimers = async () => { const t = h.timers.splice(0); for (const fn of t) { try { await fn(); } catch (e) {} } await h.flush(); };
  await h.flush();
  try {
    await h.$("plan-btn").fire("click");
    ok("Plan button opens the chat and starts a conversation", calls.some(c => c.url === "/api/planner" && c.method === "POST") && h.$("planner").hidden === false, JSON.stringify(calls));
    h.$("pl-input").value = "pasted plan";
    await h.$("pl-send").fire("click");
    ok("sending posts to /api/planner/<id>/messages", calls.some(c => c.url === "/api/planner/c1/messages" && c.method === "POST" && c.body && c.body.text === "pasted plan"), JSON.stringify(calls));
    ok("the input is disabled while a reply is running", h.$("pl-input").disabled === true, "disabled=" + h.$("pl-input").disabled);
    ok("a running indicator shows while the reply streams", calls.some(c => c.url === "/api/planner/c1/messages") && h.$("pl-running").hidden === false, "hidden=" + h.$("pl-running").hidden);
    await runTimers();
    ok("the reply is absent while GET reports running true", !/reply one/.test(h.$("pl-transcript").textContent) && h.$("pl-input").disabled === true, h.$("pl-transcript").textContent);
    replyDone = true;
    await runTimers();
    ok("the reply appears in the transcript once GET reports running false", /reply one/.test(h.$("pl-transcript").textContent), h.$("pl-transcript").textContent);
    ok("the input is enabled again after the reply", h.$("pl-input").disabled === false, "disabled=" + h.$("pl-input").disabled);
    await h.$("pl-draft").fire("click");
    ok("Draft cards posts to /api/planner/<id>/draft", calls.some(c => c.url === "/api/planner/c1/draft" && c.method === "POST"), JSON.stringify(calls));
    await runTimers();
    const imp = h.ctx.__test.S.imp;
    ok("Draft cards hands the import id to the existing preview", !!imp && imp.id === "imp7" && calls.some(c => c.url === "/api/import/imp7"), JSON.stringify(imp && imp.id));
    ok("the preview plays the split animation for the returned import", !!imp && (imp.phase === "splitting" || imp.phase === "ready") && h.$("import").hidden === false, JSON.stringify(imp && imp.phase));
  } catch (e) {
    ok("chat box interaction ran without an error", false, String(e && e.message || e));
  }
})();
JS
OUT="$(node "$DRIVER" "$SCRIPT_DIR" "$STATIC" 2>&1)"
while IFS= read -r line; do
  case "$line" in
    "ok   "*) pass "${line#ok   }" ;;
    "FAIL "*) fail "${line#FAIL }" "" ;;
  esac
done <<EOF
$OUT
EOF
case "$OUT" in *"ok   "*) ;; *) fail "driver produced results" "$OUT" ;; esac

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
