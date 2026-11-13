#!/usr/bin/env bash
#
# Plain-bash tests for the planner popup: the chat and Draft cards views open
# in a modal over the board instead of replacing it. Static markup/CSS checks
# plus a node DOM-harness run of board.js. Needs node.
#
# Usage: bash plugins/fleet-board/tests/test-board-planner-popup.sh

set -uo pipefail
unset CDPATH
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
STATIC="$(cd "$SCRIPT_DIR/../scripts/board-web/static" && pwd)"
command -v node >/dev/null 2>&1 || { echo "skipped: node not on PATH"; exit 0; }

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

echo "Case: markup and CSS"
MODAL_TAG="$(tr '\n' ' ' < "$STATIC/index.html" | grep -o '<[a-z]* [^>]*id="planner-modal"[^>]*>' | head -1)"
if printf '%s' "$MODAL_TAG" | grep -q 'role="dialog"' && printf '%s' "$MODAL_TAG" | grep -q 'aria-modal="true"'; then
  pass "The planner popup container has role=dialog and aria-modal=true"
else
  fail "The planner popup container has role=dialog and aria-modal=true" "tag: $MODAL_TAG"
fi
RULE="$(tr '\n' ' ' < "$STATIC/board.css" | grep -o '\.pl-panel *{[^}]*}' | head -1)"
if printf '%s' "$RULE" | grep -q 'position: *fixed' && printf '%s' "$RULE" | grep -Eq 'width: *[0-9]+(\.[0-9]+)?(vw|%)' \
  && printf '%s' "$RULE" | grep -Eo 'width: *[0-9.]+(vw|%)' | head -1 | grep -Eo '[0-9.]+' | awk '{exit !($1 > 0 && $1 < 100)}'; then
  pass "board.css gives the popup container position: fixed and a width below 100vw"
else
  fail "board.css gives the popup container position: fixed and a width below 100vw" "rule: $RULE"
fi
INSIDE="$(tr '\n' ' ' < "$STATIC/index.html" | grep -c 'id="planner-modal".*id="planner"')"
if [ "$INSIDE" -ge 1 ]; then pass "#planner sits inside the popup container"; else fail "#planner sits inside the popup container" "no planner-modal"; fi

echo "Case: popup behavior"
DRIVER="$(mktemp)"
PATCHED="$(mktemp)"
trap 'rm -f "$DRIVER" "$PATCHED"' EXIT
# The stock harness drops document listeners; record them so Escape can be fired.
node -e '
const fs = require("fs");
const src = fs.readFileSync(process.argv[1], "utf8");
const from = "addEventListener: function () {},";
if (!src.includes(from)) throw new Error("harness changed");
fs.writeFileSync(process.argv[2], src.replace(from, "addEventListener: function (n, f) { const L = (globalThis.__docL = globalThis.__docL || {}); L[n] = (L[n] || []).concat(f); },"));
' "$SCRIPT_DIR/board-interaction-harness.js" "$PATCHED"
cat > "$DRIVER" <<'JS'
"use strict";
const path = require("node:path");
const loadBoard = require(process.argv[2]);
const boardJs = path.join(process.argv[3], "board.js");
process.on("unhandledRejection", () => {});
const ok = (name, cond, info) => console.log((cond ? "ok   " : "FAIL ") + name + (cond ? "" : "\t" + info));
(async () => {
  const states = [{key: "backlog", name: "Backlog"}, {key: "ready", name: "Ready"}];
  const h = loadBoard(boardJs, async (url, opts) => {
    let data;
    if (url === "/api/board") data = {repo: "acme/toy", states, cards: [], run: {state: "idle"}};
    else if (url === "/api/run") data = {state: "idle"};
    else if (url === "/api/planner" && opts.method === "POST") data = {id: "c1"};
    else if (url === "/api/planner/c1/messages") data = {ok: true};
    else if (url === "/api/planner/c1/draft") data = {import_id: "imp7"};
    else if (url === "/api/planner/c1") data = {running: false, turns: [{role: "user", text: "p"}, {role: "assistant", text: "r"}]};
    else if (url === "/api/import/imp7") data = {state: "ready", elapsed_s: 1, table: "t", cards: {cards: [{key: "a", title: "A"}]}};
    else throw new Error("Unexpected request: " + opts.method + " " + url);
    return {ok: true, status: 200, json: async () => data};
  });
  const runTimers = async () => { const t = h.timers.splice(0); for (const fn of t) { try { await fn(); } catch (e) {} } await h.flush(); };
  const pressEscape = async (target) => {
    const e = {key: "Escape", target, defaultPrevented: false, preventDefault() { this.defaultPrevented = true; }};
    for (const fn of target.listeners.keydown || []) await fn(e);
    for (const fn of (globalThis.__docL || {}).keydown || []) await fn(e);
    await h.flush();
  };
  h.ctx.matchMedia = () => ({matches: true});
  await h.flush();
  try {
    const S = h.ctx.__test.S;
    await h.$("plan-btn").fire("click");
    ok("After clicking Plan, #board is not hidden", h.$("planner").hidden === false && h.$("board").hidden === false, "board.hidden=" + h.$("board").hidden);
    h.$("pl-input").value = "a plan";
    await h.$("pl-send").fire("click");
    await runTimers();
    await runTimers();
    await h.$("pl-draft").fire("click");
    await runTimers();
    ok("After moving from the chat to Draft cards, #board is not hidden", !!S.imp && h.$("import").hidden === false && h.$("board").hidden === false, "imp=" + !!S.imp + " board.hidden=" + h.$("board").hidden);
    // card detail Escape
    for (let i = 0; i < 5 && !(S.imp && S.imp.phase === "ready"); i++) await runTimers();
    const card = S.imp && S.imp.cards && S.imp.cards[0];
    if (!card) { ok("Pressing Escape while the card detail form is open closes only that form", false, "no previewed card; phase=" + (S.imp && S.imp.phase)); }
    else {
      h.ctx.openImportDetail(card);
      const open = h.$("imp-detail").hidden === false;
      await pressEscape(h.$("imp-detail"));
      ok("Pressing Escape while the card detail form is open closes only that form; Draft cards stays open", open && h.$("imp-detail").hidden === true && !!S.imp && h.$("import").hidden === false && h.$("planner-modal").hidden === false, "open=" + open + " detail.hidden=" + h.$("imp-detail").hidden + " imp=" + !!S.imp);
    }
    h.$("imp-fly").remove = () => {};
    await h.$("imp-discard").fire("click");
    const plan = h.$("plan-btn");
    let focused = false;
    plan.focus = () => { focused = true; };
    h.document.activeElement = h.document.body;
    await pressEscape(h.document.body);
    ok("Pressing Escape while the chat is open closes the popup and focuses the Plan button", !S.pl && h.$("planner").hidden === true && focused && h.$("planner-modal").hidden === true, "pl=" + !!S.pl + " focused=" + focused + " modal.hidden=" + h.$("planner-modal").hidden);
    await plan.fire("click");
    await h.$("planner-backdrop").fire("click");
    await h.$("planner-modal").fire("click");
    ok("Clicking the backdrop does not close the popup", !!S.pl && h.$("planner").hidden === false, "pl=" + !!S.pl);
  } catch (e) {
    ok("popup interaction ran without an error", false, String(e && e.message || e));
  }
})();
JS
OUT="$(node "$DRIVER" "$PATCHED" "$STATIC" 2>&1)"
while IFS= read -r line; do
  case "$line" in
    "ok   "*) pass "${line#ok   }" ;;
    "FAIL "*) fail "${line#FAIL }" "" ;;
  esac
done <<EOF2
$OUT
EOF2
case "$OUT" in *"ok   "*|*"FAIL "*) ;; *) fail "driver produced results" "$OUT" ;; esac

echo "Case: closing while a reply is running asks first"
DRIVER2="$(mktemp)"
trap 'rm -f "$DRIVER" "$PATCHED" "$DRIVER2"' EXIT
cat > "$DRIVER2" <<'JS'
"use strict";
const path = require("node:path");
const loadBoard = require(process.argv[2]);
const boardJs = path.join(process.argv[3], "board.js");
process.on("unhandledRejection", () => {});
const ok = (name, cond, info) => console.log((cond ? "ok   " : "FAIL ") + name + (cond ? "" : "\t" + info));
const states = [{key: "backlog", name: "Backlog"}, {key: "ready", name: "Ready"}];
async function boot(failStart) {
  const h = loadBoard(boardJs, async (url, opts) => {
    let data;
    if (url === "/api/board") data = {repo: "acme/toy", states, cards: [], run: {state: "idle"}};
    else if (url === "/api/run") data = {state: "idle"};
    else if (url === "/api/planner" && opts.method === "POST") {
      if (failStart) return {ok: false, status: 500, json: async () => ({error: "boom"})};
      data = {id: "c1"};
    }
    else if (url === "/api/planner/c1/messages") data = {ok: true};
    else if (url === "/api/planner/c1") data = {running: true, turns: []};
    else throw new Error("Unexpected request: " + opts.method + " " + url);
    return {ok: true, status: 200, json: async () => data};
  });
  h.ctx.matchMedia = () => ({matches: true});
  h.calls = [];
  h.answer = false;
  h.ctx.confirm = (msg) => { h.calls.push(String(msg)); return h.answer; };
  await h.flush();
  return h;
}
const pressEscape = async (h, target) => {
  const e = {key: "Escape", target, defaultPrevented: false, preventDefault() { this.defaultPrevented = true; }};
  for (const fn of target.listeners.keydown || []) await fn(e);
  for (const fn of (globalThis.__docL || {}).keydown || []) await fn(e);
  await h.flush();
};
async function running(h) {
  await h.$("plan-btn").fire("click");
  h.$("pl-input").value = "a plan";
  await h.$("pl-send").fire("click");
  await h.flush();
}
(async () => {
  try {
    let h = await boot(false);
    let S = h.ctx.__test.S;
    await running(h);
    const before = S.pl;
    await h.$("pl-close").fire("click");
    ok("Clicking pl-close while a planner reply is running calls confirm() once with a message saying the reply will be lost",
      !!before && before.busy === true && h.calls.length === 1 && /lost/i.test(h.calls[0]), "busy=" + (before && before.busy) + " calls=" + JSON.stringify(h.calls));
    ok("When confirm() returns false, the planner stays open and S.pl is unchanged",
      S.pl === before && h.$("planner-modal").hidden === false, "same=" + (S.pl === before) + " modal.hidden=" + h.$("planner-modal").hidden);
    h.answer = true;
    await h.$("pl-close").fire("click");
    ok("When confirm() returns true, S.pl is null and the popup is hidden",
      S.pl === null && h.$("planner-modal").hidden === true && h.$("planner").hidden === true, "pl=" + !!S.pl + " modal.hidden=" + h.$("planner-modal").hidden);

    h = await boot(false);
    S = h.ctx.__test.S;
    await running(h);
    await pressEscape(h, h.document.body);
    ok("Pressing Escape while a planner reply is running calls confirm() once", h.calls.length === 1 && !!S.pl, "calls=" + h.calls.length + " pl=" + !!S.pl);

    h = await boot(false);
    S = h.ctx.__test.S;
    await h.$("plan-btn").fire("click");
    await h.$("pl-close").fire("click");
    ok("Clicking pl-close on a chat with no messages closes the planner without calling confirm()", h.calls.length === 0 && S.pl === null && h.$("planner-modal").hidden === true, "calls=" + h.calls.length + " pl=" + !!S.pl);

    h = await boot(true);
    S = h.ctx.__test.S;
    await h.$("plan-btn").fire("click");
    await h.flush();
    ok("When POST /api/planner fails, the planner closes without calling confirm()", h.calls.length === 0 && S.pl === null && h.$("planner-modal").hidden === true, "calls=" + h.calls.length + " pl=" + !!S.pl);
  } catch (e) {
    ok("close confirmation ran without an error", false, String(e && e.message || e));
  }
})();
JS
OUT2="$(node "$DRIVER2" "$PATCHED" "$STATIC" 2>&1)"
while IFS= read -r line; do
  case "$line" in
    "ok   "*) pass "${line#ok   }" ;;
    "FAIL "*) fail "${line#FAIL }" "" ;;
  esac
done <<EOF3
$OUT2
EOF3
case "$OUT2" in *"ok   "*|*"FAIL "*) ;; *) fail "close driver produced results" "$OUT2" ;; esac

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
