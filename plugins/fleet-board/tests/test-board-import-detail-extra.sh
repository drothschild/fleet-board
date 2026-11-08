#!/usr/bin/env bash
#
# Plain-bash test: extra Acceptance checks for the import card detail dialog (Enter
# activation, depends_on, split completion) (board.js, node DOM harness, fake import API). Needs node.
#
# Usage: bash plugins/fleet-board/tests/test-board-import-detail-extra.sh

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

const CARD_A = {key: "a", title: "Alpha", repo: "acme/toy", labels: ["backend", "api"], why: "Expose the thing.",
  scope: ["src/a.js", "src/b.js"], acceptance: ["POST /a returns 201", "GET /a returns 200"],
  consumes: ["X"], produces: ["POST /a"], depends_on: []};
const CARD_B = {key: "b", title: "Beta", repo: "acme/toy", labels: ["frontend"], why: "Show it.",
  scope: ["src/c.js"], acceptance: ["GET /b returns 200"], consumes: ["POST /a"], produces: [], depends_on: ["a"]};

async function setup(reduceMotion, patchReply, beforeDraft) {
  const calls = [];
  let cards = [CARD_A, CARD_B];
  const states = [{key: "backlog", name: "Backlog"}, {key: "ready", name: "Ready"}];
  const h = loadBoard(boardJs, async (url, opts) => {
    calls.push({url, method: opts.method, body: opts.body});
    let data, status = 200;
    if (url === "/api/board") data = {repo: "acme/toy", states, cards: [], run: {state: "idle"}};
    else if (url === "/api/run") data = {state: "idle"};
    else if (url === "/api/planner" && opts.method === "POST") data = {id: "c1"};
    else if (url === "/api/planner/c1/draft") data = {import_id: "imp7"};
    else if (url === "/api/planner/c1/messages") data = {ok: true};
    else if (url === "/api/planner/c1") data = {running: false, turns: [{role: "user", text: "plan"}, {role: "assistant", text: "reply"}]};
    else if (url === "/api/import/imp7") data = {state: "ready", elapsed_s: 2, table: "t", cards: {cards}};
    else if (url === "/api/import/imp7/cards/a" && opts.method === "PATCH") {
      const r = patchReply(JSON.parse(opts.body));
      status = r.status; data = r.data;
    } else throw new Error("Unexpected request: " + opts.method + " " + url);
    return {ok: status < 400, status, json: async () => data};
  });
  const runTimers = async () => { const t = h.timers.splice(0); for (const fn of t) { try { await fn(); } catch (e) {} } await h.flush(); };
  h.ctx.matchMedia = () => ({matches: reduceMotion});
  await h.flush();
  await h.$("plan-btn").fire("click");
  h.$("pl-input").value = "plan";
  await h.$("pl-send").fire("click");
  await runTimers();
  if (beforeDraft) beforeDraft(h);
  await h.$("pl-draft").fire("click");
  await runTimers();
  await runTimers();
  return {h, calls, runTimers};
}
const cardButtons = (h) => h.$("imp-grid").all().filter((n) => n.tagName === "BUTTON");

(async () => {
  try {
    // Acceptance 1: Enter must stay a native button activation (keydown not prevented).
    {
      const {h} = await setup(true, () => ({status: 200, data: {}}));
      const btn = cardButtons(h)[1];
      let prevented = false;
      await btn.fire("keydown", {key: "Enter", preventDefault() { prevented = true; }});
      if (!prevented) await btn.fire("click"); // the browser clicks a button on an unprevented Enter
      ok("Enter keydown on a card is not prevented, so native activation opens the dialog", !prevented && h.$("imp-detail").hidden === false && h.$("imp-d-title").value === "Beta", "prevented=" + prevented + " hidden=" + h.$("imp-detail").hidden);
    }
    // Acceptance 2: a card with dependencies shows them in the dialog.
    {
      const {h} = await setup(true, () => ({status: 200, data: {}}));
      await cardButtons(h)[1].fire("click");
      ok("the dialog shows the depends_on of a card that has dependencies", h.$("imp-d-depends").value.split("\n").includes("a"), JSON.stringify(h.$("imp-d-depends").value));
      await h.$("imp-d-cancel").fire("click");
      await cardButtons(h)[0].fire("click");
      ok("the dialog shows an empty depends_on for a card without dependencies", h.$("imp-d-depends").value === "", JSON.stringify(h.$("imp-d-depends").value));
    }
    // Acceptance 5: after the split finishes the grid becomes clickable.
    {
      const {h, runTimers} = await setup(false, () => ({status: 200, data: {}}), (hh) => {
        const proto = Object.getPrototypeOf(hh.$("imp-sheet"));
        const rect = () => ({left: 0, top: 0, width: 100, height: 100});
        proto.getBoundingClientRect = rect;
        proto.cloneNode = function () { return hh.document.createElement("div"); };
        proto.remove = function () {};
      });
      for (let i = 0; i < 6 && h.$("import").dataset.phase !== "ready"; i++) await runTimers();
      const btns = cardButtons(h);
      ok("after the split completes the phase is ready and the cards are enabled", h.$("import").dataset.phase === "ready" && btns.length === 2 && btns.every((b) => b.disabled === false), "phase=" + h.$("import").dataset.phase + " disabled=" + btns.map((b) => b.disabled));
      await btns[0].fire("click");
      ok("a card opens the dialog once the split has completed", h.$("imp-detail").hidden === false, "hidden=" + h.$("imp-detail").hidden);
    }
  } catch (e) {
    ok("extra detail run without an error", false, String(e && e.stack || e));
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
