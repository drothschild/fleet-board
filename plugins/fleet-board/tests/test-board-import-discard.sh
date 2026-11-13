#!/usr/bin/env bash
#
# Plain-bash test: Discard while grouping sends exactly one cancel request, and
# the board view returns only after it settles (board.js, node DOM harness,
# fake import API). Needs node.
#
# Usage: bash plugins/fleet-board/tests/test-board-import-discard.sh

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

async function setup() {
  const calls = [];
  const gate = {release: null};
  const states = [{key: "backlog", name: "Backlog"}, {key: "ready", name: "Ready"}];
  const h = loadBoard(boardJs, async (url, opts) => {
    calls.push({url, method: opts.method});
    let data = {}, status = 200;
    if (url === "/api/board") data = {repo: "acme/toy", states, cards: [], run: {state: "idle"}};
    else if (url === "/api/planner" && opts.method === "POST") data = {id: "c1"};
    else if (url === "/api/planner/c1/draft") data = {import_id: "imp7"};
    else if (url === "/api/planner/c1/messages") data = {ok: true};
    else if (url === "/api/planner/c1") data = {running: false, turns: [{role: "user", text: "plan"}, {role: "assistant", text: "reply"}]};
    else if (url === "/api/import/imp7") data = {state: "running", elapsed_s: 1};
    else if (url === "/api/import/imp7/cancel") {
      await new Promise((res) => { gate.release = res; });
      data = {state: "cancelled"};
    } else throw new Error("Unexpected request: " + opts.method + " " + url);
    return {ok: status < 400, status, json: async () => data};
  });
  const runTimers = async () => { const t = h.timers.splice(0); for (const fn of t) { try { await fn(); } catch (e) {} } await h.flush(); };
  h.$("imp-fly").remove = function () {};
  await h.flush();
  await h.$("plan-btn").fire("click");
  h.$("pl-input").value = "plan";
  await h.$("pl-send").fire("click");
  await runTimers();
  await h.$("pl-draft").fire("click");
  await runTimers();
  return {h, calls, gate};
}
const cancels = (calls) => calls.filter((c) => c.method === "POST" && c.url === "/api/import/imp7/cancel");

(async () => {
  try {
    const {h, calls, gate} = await setup();
    ok("the import view is open and grouping before Discard", h.$("import").hidden === false && h.$("import").dataset.phase === "running", "hidden=" + h.$("import").hidden + " phase=" + h.$("import").dataset.phase);
    // Call the listener directly: fire() would wait for the held cancel reply.
    const pending = h.$("imp-discard").listeners.click[0]({target: h.$("imp-discard"), preventDefault() {}});
    await h.flush();
    ok("Discard sends exactly one cancel request", cancels(calls).length === 1, JSON.stringify(calls));
    ok("the board view has not returned while the cancel request is pending", h.$("import").hidden === false, "hidden=" + h.$("import").hidden);
    gate.release();
    await pending;
    await h.flush();
    ok("the board view returns after the cancel request settles", h.$("import").hidden === true, "hidden=" + h.$("import").hidden);
    ok("still exactly one cancel request after the view closed", cancels(calls).length === 1, JSON.stringify(calls));
    const lastCancel = calls.map((c) => c.url).lastIndexOf("/api/import/imp7/cancel");
    ok("no poll follows the cancel request", lastCancel === calls.length - 1, JSON.stringify(calls));
  } catch (e) {
    ok("discard run without an error", false, String(e && e.stack || e));
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
