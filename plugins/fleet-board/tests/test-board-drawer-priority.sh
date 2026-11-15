#!/usr/bin/env bash
#
# Plain-bash tests: the card drawer's priority up/down buttons.
# Usage: bash plugins/fleet-board/tests/test-board-drawer-priority.sh

set -uo pipefail
unset CDPATH
DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
command -v node >/dev/null 2>&1 || { echo "skipped: node not on PATH"; exit 0; }

DIR="$DIR" node - <<'JS'
"use strict";
const assert = require("node:assert/strict");
const path = require("node:path");
const loadBoard = require(path.join(process.env.DIR, "board-interaction-harness.js"));
const JS = path.join(process.env.DIR, "../scripts/board-web/static/board.js");

const states = [{key: "backlog", name: "Backlog"}, {key: "ready", name: "Ready"}];
const mk = (number, labels) => ({number, title: "Card " + number, body: "", labels, comments: [],
  acceptance: [], blocked_by: [], blocks: [], state: "ready", known: true});

let fails = 0;
async function test(name, fn) {
  try { await fn(); console.log("ok - " + name); }
  catch (e) { fails++; console.log("FAIL - " + name + ": " + e.message); }
}

function setup(labels) {
  const card = mk(1, labels);
  const patches = [];
  const h = loadBoard(JS, async (url, o) => {
    const method = (o && o.method) || "GET";
    let data = {}, m;
    if (url === "/api/board") data = {repo: "acme/toy", states, cards: [{...card}], run: {state: "idle"}};
    else if (method === "GET" && (m = /^\/api\/cards\/(\d+)$/.exec(url))) data = {...card};
    else if (method === "PATCH") { const b = JSON.parse(o.body); patches.push(b); Object.assign(card, b); }
    return {ok: true, status: 200, json: async () => data};
  });
  return {h, card, patches};
}
async function open(labels) {
  const s = setup(labels);
  await s.h.flush();
  await s.h.ctx.openDrawer(1);
  await s.h.flush();
  return s;
}
const allText = n => (n.textContent || "") + (n.children || []).map(allText).join("");
const up = h => h.$("dr-prio-high");
const down = h => h.$("dr-prio-low");
const press = async (b) => { await b.fire("click"); };
const save = async (h) => { await h.$("dr-save").fire("click"); };
const prio = ls => ls.filter(l => l.startsWith("fleet:priority:"));

(async () => {
  await test("Opening a card with no priority label shows ▲ and ▼ both aria-pressed false, and pressing ▲ then Save PATCHes labels containing fleet:priority:high and no other priority label", async () => {
    const {h, patches} = await open(["a"]);
    assert.equal(up(h).getAttribute("aria-pressed"), "false");
    assert.equal(down(h).getAttribute("aria-pressed"), "false");
    await press(up(h));
    assert.equal(up(h).getAttribute("aria-pressed"), "true");
    await save(h);
    assert.equal(patches.length, 1);
    assert.deepEqual(prio(patches[0].labels), ["fleet:priority:high"]);
  });

  await test("On a card labelled fleet:priority:high, pressing ▼ then Save PATCHes fleet:priority:low without high", async () => {
    const {h, patches} = await open(["fleet:priority:high"]);
    await press(down(h));
    await save(h);
    assert.deepEqual(prio(patches[0].labels), ["fleet:priority:low"]);
  });

  await test("Pressing the pressed button again and saving PATCHes labels with no fleet:priority label", async () => {
    const {h, patches} = await open(["x", "fleet:priority:high"]);
    assert.equal(up(h).getAttribute("aria-pressed"), "true");
    await press(up(h));
    await save(h);
    assert.deepEqual(patches[0].labels, ["x"]);
  });

  await test("Pressing ▲ removes fleet:priority:normal too", async () => {
    const {h, patches} = await open(["fleet:priority:normal"]);
    await press(up(h));
    await save(h);
    assert.deepEqual(patches[0].labels, ["fleet:priority:high"]);
  });

  await test("Each button's title contains same kind, 15 minutes and never skips dependencies, and its accessible name is High priority / Low priority", async () => {
    const {h} = await open([]);
    for (const [b, name] of [[up(h), "High priority"], [down(h), "Low priority"]]) {
      for (const t of ["same kind", "15 minutes", "never skips dependencies"]) assert.ok((b.title || "").includes(t), t + " in " + b.title);
      assert.equal(b.getAttribute("aria-label"), name);
    }
  });

  await test("Neither the drawer's label chips nor the tile's label list shows a fleet:priority label, and a high tile shows a ▲ marker while a normal tile shows none", async () => {
    const {h} = await open(["fleet:priority:high", "keep"]);
    const chips = allText(h.$("dr-labels"));
    assert.ok(!chips.includes("fleet:priority"), chips);
    assert.ok(chips.includes("keep"), chips);
    const hi = allText(h.ctx.renderCard(mk(1, ["fleet:priority:high", "keep"]), "acme/toy"));
    assert.ok(!hi.includes("fleet:priority"), hi);
    assert.ok(hi.includes("▲"), hi);
    assert.ok(hi.includes("keep"), hi);
    const lo = allText(h.ctx.renderCard(mk(2, ["fleet:priority:low"]), "acme/toy"));
    assert.ok(lo.includes("▼") && !lo.includes("fleet:priority"), lo);
    const no = allText(h.ctx.renderCard(mk(3, ["keep"]), "acme/toy"));
    assert.ok(!no.includes("▲") && !no.includes("▼"), no);
  });

  await test("A card with both priority labels opens with both buttons pressed and the two-labels warning visible; pressing ▲ and saving PATCHes only fleet:priority:high", async () => {
    const {h, patches} = await open(["fleet:priority:high", "fleet:priority:low"]);
    assert.equal(up(h).getAttribute("aria-pressed"), "true");
    assert.equal(down(h).getAttribute("aria-pressed"), "true");
    const w = h.$("dr-prio-warn");
    assert.ok(!w.hidden);
    assert.ok(allText(w).includes("Two priority labels"), allText(w));
    await press(up(h));
    await save(h);
    assert.deepEqual(prio(patches[0].labels), ["fleet:priority:high"]);
    assert.ok(h.$("dr-prio-warn").hidden);
  });

  await test("Labels other than priority labels are kept unchanged and in order by every button press", async () => {
    const {h, patches} = await open(["b", "fleet:priority:low", "a", "c"]);
    await press(up(h));
    await press(down(h));
    await press(down(h));
    await press(up(h));
    await save(h);
    assert.deepEqual(patches[0].labels.filter(l => !l.startsWith("fleet:priority:")), ["b", "a", "c"]);
    assert.deepEqual(prio(patches[0].labels), ["fleet:priority:high"]);
  });

  process.exit(fails ? 1 : 0);
})();
JS
