#!/usr/bin/env bash
#
# Plain-bash tests: the drawer's state picker is locked while an agent works on
# the card (active, not stuck), like the tile drag.
# Usage: bash plugins/fleet-board/tests/test-board-drawer-lock.sh

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
  acceptance: [], blocked_by: [], state: "ready", known: true, ...extra});

let fails = 0;
async function test(name, fn) {
  try { await fn(); console.log("ok - " + name); }
  catch (e) { fails++; console.log("not ok - " + name + ": " + e.message); }
}
async function setup() {
  const cards = [
    mk(1, {active: true}),
    mk(2, {active: false}),
    mk(3, {active: true, stuck: {kind: "no_progress", detail: "x"}}),
  ];
  const calls = [];
  const h = loadBoard(JS, async (url, o) => {
    const method = (o && o.method) || "GET";
    calls.push(method + " " + url);
    let data = {}, m;
    if (url === "/api/board") data = {repo: "acme/toy", states, cards: cards.map(c => ({...c})), run: {state: "idle"}};
    else if (method === "GET" && (m = /^\/api\/cards\/(\d+)$/.exec(url))) data = {...cards.find(c => c.number === Number(m[1]))};
    else if (method === "PATCH" && (m = /^\/api\/cards\/(\d+)$/.exec(url))) Object.assign(cards.find(c => c.number === Number(m[1])), JSON.parse(o.body));
    return {ok: true, status: 200, json: async () => data};
  });
  await h.flush();
  return {h, cards, calls};
}

(async () => {
  await test("Opening the drawer for an active card that isn't stuck shows dr-state disabled", async () => {
    const {h} = await setup();
    await h.ctx.openDrawer(1);
    await h.flush();
    assert.equal(h.$("dr-state").disabled, true);
  });
  await test("Opening the drawer for a card that isn't active shows dr-state enabled", async () => {
    const {h} = await setup();
    await h.ctx.openDrawer(2);
    await h.flush();
    assert.equal(!!h.$("dr-state").disabled, false);
  });
  await test("Opening the drawer for an active card that is stuck shows dr-state enabled", async () => {
    const {h} = await setup();
    await h.ctx.openDrawer(3);
    await h.flush();
    assert.equal(!!h.$("dr-state").disabled, false);
  });
  await test("Saving the drawer for an active card that isn't stuck sends no /move request", async () => {
    const {h, calls} = await setup();
    await h.ctx.openDrawer(1);
    await h.flush();
    h.$("dr-state").value = "in_progress";
    h.$("dr-title").value = "Renamed";
    await h.$("dr-title").fire("input");
    await h.$("dr-save").fire("click");
    await h.flush();
    assert.ok(calls.includes("PATCH /api/cards/1"), "the title was saved");
    assert.equal(calls.filter(c => /\/move$/.test(c)).length, 0);
  });
  await test("When a poll shows the card is no longer active, dr-state becomes enabled without reopening the drawer", async () => {
    const {h, cards} = await setup();
    await h.ctx.openDrawer(1);
    await h.flush();
    assert.equal(h.$("dr-state").disabled, true);
    cards[0].active = false;
    await h.ctx.fetchBoard(true);
    await h.flush();
    assert.equal(!!h.$("dr-state").disabled, false);
  });
  console.log(fails + " failing");
  process.exitCode = fails ? 1 : 0;
})();
EOF
