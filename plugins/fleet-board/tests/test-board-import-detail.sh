#!/usr/bin/env bash
#
# Plain-bash test: clickable preview cards open an editable detail dialog on
# the import view (board.js, node DOM harness, fake import API). Needs node.
#
# Usage: bash plugins/fleet-board/tests/test-board-import-detail.sh

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
    // Acceptance 1: focusable (a real button) and opens on click and on Enter.
    {
      const {h} = await setup(true, () => ({status: 200, data: {}}));
      const btns = cardButtons(h);
      ok("each card in the ready grid is a focusable button", btns.length === 2 && btns.every((b) => b.attrs.tabindex !== "-1" && !b.disabled), "buttons=" + btns.length);
      ok("the detail dialog is closed until a card is activated", h.$("imp-detail").hidden === true, "hidden=" + h.$("imp-detail").hidden);
      await btns[0].fire("click");
      ok("click on a card opens the detail dialog", h.$("imp-detail").hidden === false, "hidden=" + h.$("imp-detail").hidden);
      // Enter: on a button it activates click natively; a keydown handler must not break that nor be required.
      h.$("imp-detail").hidden = true;
      await btns[1].fire("keydown", {key: "Enter"});
      await btns[1].fire("click");
      ok("Enter on a card (native button activation) opens the detail dialog", h.$("imp-detail").hidden === false && h.$("imp-d-title").value === "Beta", "title=" + h.$("imp-d-title").value);
    }
    // Acceptance 2: every field of the entry is shown.
    {
      const {h} = await setup(true, () => ({status: 200, data: {}}));
      await cardButtons(h)[0].fire("click");
      // The harness does not parse index.html, so read each dialog field by id.
      const ids = ["imp-d-key", "imp-d-title", "imp-d-labels", "imp-d-why", "imp-d-scope", "imp-d-acceptance", "imp-d-depends", "imp-d-repo", "imp-d-consumes", "imp-d-produces"];
      const text = ids.map((i) => h.$(i).textContent + " " + h.$(i).value).join(" ");
      const need = ["a", "Alpha", "acme/toy", "backend", "api", "Expose the thing.", "src/a.js", "src/b.js", "POST /a returns 201", "GET /a returns 200", "X", "POST /a"];
      const missing = need.filter((s) => !text.includes(s));
      ok("the dialog shows every field of the cards.json entry", missing.length === 0, "missing=" + missing.join("|"));
      ok("the dialog title field holds the card title", h.$("imp-d-title").value === "Alpha", h.$("imp-d-title").value);
    }
    // Acceptance 3: saving sends one PATCH and re-renders without replaying the split.
    {
      const {h, calls} = await setup(true, (body) => ({status: 200, data: {state: "ready", table: "t2", cards: {cards: [Object.assign({}, CARD_A, body), CARD_B]}}}));
      await cardButtons(h)[0].fire("click");
      h.$("imp-d-title").value = "Alpha renamed";
      const sheetBefore = h.$("imp-sheet").className;
      await h.$("imp-d-save").fire("click");
      const patches = calls.filter((c) => c.method === "PATCH");
      ok("saving an edited title sends exactly one PATCH to the card key", patches.length === 1 && patches[0].url === "/api/import/imp7/cards/a" && JSON.parse(patches[0].body).title === "Alpha renamed", JSON.stringify(patches));
      ok("the grid shows the new title after save", h.$("imp-grid").textContent.includes("Alpha renamed"), h.$("imp-grid").textContent);
      ok("the dialog closes after a successful save", h.$("imp-detail").hidden === true, "hidden=" + h.$("imp-detail").hidden);
      ok("saving does not replay the split", h.$("imp-sheet").className === sheetBefore && !h.$("imp-grid").all().some((n) => n.classList.contains("landing")), h.$("imp-sheet").className);
    }
    // Acceptance 4: a lint failure keeps the dialog open with the message, grid unchanged.
    {
      const {h} = await setup(true, () => ({status: 422, data: {error: "card a: acceptance is empty"}}));
      await cardButtons(h)[0].fire("click");
      h.$("imp-d-title").value = "Should not appear";
      const before = h.$("imp-grid").textContent;
      await h.$("imp-d-save").fire("click");
      ok("a lint failure keeps the dialog open", h.$("imp-detail").hidden === false, "hidden=" + h.$("imp-detail").hidden);
      ok("a lint failure shows the server's message in the dialog", h.$("imp-d-error").textContent.includes("card a: acceptance is empty") && h.$("imp-d-error").hidden === false, h.$("imp-d-error").textContent);
      ok("a lint failure leaves the grid unchanged", h.$("imp-grid").textContent === before, h.$("imp-grid").textContent);
    }
    // Acceptance 5: with reduced motion off, the split plays before the grid is clickable.
    {
      const {h} = await setup(false, () => ({status: 200, data: {}}), (hh) => {
        // The harness has no layout: give the sheet a rect so playSplit can start.
        hh.$("imp-sheet").getBoundingClientRect = () => ({left: 0, top: 0, width: 100, height: 100});
      });
      const btns = cardButtons(h);
      ok("with reduced motion off the split is playing and the cards are not clickable yet",
        h.$("import").dataset.phase === "splitting" && h.$("imp-sheet").classList.contains("split") && btns.length === 2 && btns.every((b) => b.disabled === true),
        "phase=" + h.$("import").dataset.phase + " buttons=" + btns.length + " disabled=" + btns.map((b) => b.disabled));
    }
  } catch (e) {
    ok("detail dialog run without an error", false, String(e && e.stack || e));
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
