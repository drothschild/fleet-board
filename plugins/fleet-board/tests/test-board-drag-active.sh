#!/usr/bin/env bash
#
# Plain-bash tests: a card an agent is working on (active, not stuck) can't be
# dragged. Usage: bash plugins/fleet-board/tests/test-board-drag-active.sh

set -uo pipefail
unset CDPATH
DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
command -v node >/dev/null 2>&1 || { echo "skipped: node not on PATH"; exit 0; }

DIR="$DIR" node - <<'EOF'
"use strict";
const assert = require("node:assert/strict");
const path = require("node:path");
const loadBoard = require(path.join(process.env.DIR, "board-interaction-harness.js"));
const JS = path.join(process.env.DIR, "../scripts/board-web/static/board.js");

const states = [{key: "ready", name: "Ready"}, {key: "in_progress", name: "In progress"}];
const mk = (number, extra) => ({number, title: "Card " + number, body: "", labels: [], comments: [],
  state: "ready", known: true, ...extra});
const cards = [
  mk(1, {active: true}),
  mk(2, {active: false}),
  mk(3, {active: true, stuck: {reason: "no progress"}}),
];
let fails = 0;
async function test(name, fn) {
  try { await fn(); console.log("ok - " + name); }
  catch (e) { fails++; console.log("not ok - " + name + ": " + e.message); }
}
async function setup() {
  const moves = [];
  const h = loadBoard(JS, async (url, opts) => {
    let data;
    if (url === "/api/board") data = {repo: "acme/toy", states, cards: cards.map(c => ({...c})), run: {state: "idle"}};
    else if (/\/move$/.test(url)) { moves.push(url); data = {...cards[0]}; }
    else data = {};
    return {ok: true, status: 200, json: async () => data};
  });
  await h.flush();
  const tile = n => h.$("board").all().find(x => x.classList.contains("card") && x.dataset.n === String(n));
  return {h, moves, tile};
}
const dt = () => ({dataTransfer: {setData() {}, effectAllowed: ""}});

(async () => {
  await test("A card rendered with active true and no stuck has draggable set to false", async () => {
    const {tile} = await setup();
    assert.equal(tile(1).draggable, false);
  });
  await test("A card rendered with active false has draggable set to true", async () => {
    const {tile} = await setup();
    assert.equal(tile(2).draggable, true);
  });
  await test("A card rendered with active true and a stuck object has draggable set to true", async () => {
    const {tile} = await setup();
    assert.equal(tile(3).draggable, true);
  });
  await test("A dragstart on an active card that isn't stuck leaves S.dragging as null", async () => {
    const {h, tile} = await setup();
    await tile(1).fire("dragstart", dt());
    assert.equal(h.ctx.__test.S.dragging, null);
  });
  await test("Dropping onto a column while an active card that isn't stuck is the drag source never calls /move", async () => {
    const {h, moves, tile} = await setup();
    await tile(1).fire("dragstart", dt());
    const col = h.$("board").all().find(x => x.listeners.drop && x.dataset.state === "in_progress");
    assert.ok(col, "found a drop column");
    await col.fire("drop", dt());
    assert.equal(moves.length, 0);
  });
  await test("An active tile that isn't stuck has a tooltip saying it can't be moved while an agent is working", async () => {
    const {tile} = await setup();
    const t = tile(1);
    const tip = t.title || (t.attrs && t.attrs.title) || "";
    assert.match(tip, /can't be moved while an agent is working/i);
    const other = tile(2).title || (tile(2).attrs && tile(2).attrs.title) || "";
    assert.equal(other, "");
  });
  console.log(fails + " failing");
  process.exitCode = fails ? 1 : 0;
})();
EOF
