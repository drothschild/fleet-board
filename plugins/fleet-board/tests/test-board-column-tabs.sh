#!/usr/bin/env bash
#
# Plain-bash tests: the phone board has a tablist that switches the visible column.
# Usage: bash plugins/fleet-board/tests/test-board-column-tabs.sh

set -uo pipefail
unset CDPATH
DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
command -v node >/dev/null 2>&1 || { echo "skipped: node not on PATH"; exit 0; }

DIR="$DIR" node - <<'EOF'
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const loadBoard = require(path.join(process.env.DIR, "board-interaction-harness.js"));
const STATIC = path.join(process.env.DIR, "../scripts/board-web/static");
const JS = path.join(STATIC, "board.js");

const states = [{key: "backlog", name: "Backlog"}, {key: "ready", name: "Ready"}, {key: "in_progress", name: "In progress"}];
const mk = (number, state) => ({number, title: "Card " + number, body: "", labels: [], comments: [], state, known: true});
const cards = [mk(1, "backlog"), mk(2, "ready"), mk(3, "ready"), mk(4, "in_progress")];
let fails = 0;
async function test(name, fn) {
  try { await fn(); console.log("ok - " + name); }
  catch (e) { fails++; console.log("not ok - " + name + ": " + e.message); }
}
async function setup(hash) {
  const scrolls = [];
  const replaced = [];
  let fixed = false;
  const h = loadBoard(JS, async (url) => {
    const data = url === "/api/board"
      ? {repo: "acme/toy", states, cards: cards.map((c) => ({...c})), run: {state: "idle"}} : {};
    return {ok: true, status: 200, json: async () => data};
  });
  const proto = Object.getPrototypeOf(h.document.createElement("div"));
  proto.scrollIntoView = function (opts) { scrolls.push({node: this, opts}); };
  h.ctx.location.hash = hash || "";
  h.ctx.history.replaceState = (a, b, url) => { replaced.push(url); };
  await h.flush();
  const board = h.$("board");
  const tabs = () => h.$("col-tabs").all().filter((n) => n.attrs.role === "tab");
  const tab = (name) => tabs().find((t) => t.textContent.includes(name));
  const colOf = (key) => board.all().find((x) => x.tagName === "SECTION" && x.dataset.state === key);
  return {h, board, tabs, tab, colOf, scrolls, replaced};
}

(async () => {
  await test("The board renders a role=tablist with one tab per column, each showing the column name and its card count", async () => {
    const {h, tabs} = await setup();
    assert.equal(h.$("col-tabs").attrs.role, "tablist");
    assert.equal(tabs().length, 3);
    assert.match(tabs()[0].textContent, /Backlog\s*1/);
    assert.match(tabs()[1].textContent, /Ready\s*2/);
    assert.match(tabs()[2].textContent, /In progress\s*1/);
  });
  await test("Clicking a tab sets aria-selected true on it alone and scrolls that column into view", async () => {
    const {tab, tabs, colOf, scrolls} = await setup();
    await tab("Ready").fire("click");
    assert.equal(tab("Ready").attrs["aria-selected"], "true");
    assert.equal(tabs().filter((t) => t.attrs["aria-selected"] === "true").length, 1);
    const last = scrolls[scrolls.length - 1];
    assert.ok(last, "scrollIntoView was called");
    assert.equal(last.node, colOf("ready"));
    assert.equal(last.opts.container, "nearest");
  });
  await test("The selected column stays selected after a board poll re-renders", async () => {
    const {h, tab} = await setup();
    await tab("In progress").fire("click");
    h.ctx.__test.S.stateKeys = null; // a poll that rebuilds the columns
    await h.ctx.fetch("/api/board").then((r) => r.json()).then((b) => h.ctx.eval("renderBoard")(b, true));
    await h.flush();
    assert.equal(tab("In progress").attrs["aria-selected"], "true");
    assert.equal(tab("Ready").attrs["aria-selected"], "false");
  });
  await test("The selected column is restored from the URL hash on load", async () => {
    const {tab, colOf, scrolls} = await setup("#in_progress");
    assert.equal(tab("In progress").attrs["aria-selected"], "true");
    assert.equal(tab("Backlog").attrs["aria-selected"], "false");
    assert.ok(scrolls.some((s) => s.node === colOf("in_progress")), "the hash column was scrolled into view");
  });
  await test("Scrolling to a different column changes which tab is selected", async () => {
    const {board, tab, colOf, replaced} = await setup();
    colOf("backlog").offsetLeft = 0;
    colOf("ready").offsetLeft = 300;
    colOf("in_progress").offsetLeft = 600;
    board.clientWidth = 300;
    board.scrollLeft = 300;
    await board.fire("scroll");
    assert.equal(tab("Ready").attrs["aria-selected"], "true");
    assert.equal(tab("Backlog").attrs["aria-selected"], "false");
    assert.ok(replaced.some((u) => /#ready$/.test(String(u))), "the hash follows the selection");
  });
  await test("At a desktop width the tablist is not displayed and the tiles keep draggable true", async () => {
    const html = fs.readFileSync(path.join(STATIC, "index.html"), "utf8");
    const tag = /<[a-z]+[^>]*id="col-tabs"[^>]*>/.exec(html);
    assert.ok(tag, "index.html has the #col-tabs container");
    assert.match(tag[0], /role="tablist"/);
    assert.match(tag[0], /\bhidden\b/);
    const css = fs.readFileSync(path.join(STATIC, "board.css"), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
    const at = css.indexOf("@media (max-width: 720px)");
    assert.ok(at >= 0);
    assert.ok(!css.slice(0, at).includes("col-tabs"), "no tab rule outside the phone media query");
    assert.match(css.slice(at), /#col-tabs[^{]*\{[^}]*display:\s*flex/);
    const {h} = await setup();
    const tiles = h.$("board").all().filter((x) => x.classList.contains("card"));
    assert.ok(tiles.length >= 4);
    for (const t of tiles) assert.equal(t.draggable, true);
  });
  console.log(fails + " failing");
  process.exitCode = fails ? 1 : 0;
})();
EOF
