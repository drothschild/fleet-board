#!/usr/bin/env bash
#
# Plain-bash tests: the card drawer shows a Held line from the card's hold.
# Usage: bash plugins/fleet-board/tests/test-board-drawer-hold.sh

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
const mk = (number, extra) => ({number, title: "Card " + number, body: "", labels: [], comments: [],
  acceptance: [], blocked_by: [], blocks: [], state: "ready", known: true, ...extra});

let fails = 0;
async function test(name, fn) {
  try { await fn(); console.log("ok - " + name); }
  catch (e) { fails++; console.log("FAIL - " + name + ": " + e.message); }
}

function setup(cards) {
  return loadBoard(JS, async (url) => {
    let data = {}, m;
    if (url === "/api/board") data = {repo: "acme/toy", states, cards: cards.map(c => ({...c})), run: {state: "idle"}};
    else if ((m = /^\/api\/cards\/(\d+)$/.exec(url))) data = {...cards.find(c => c.number === Number(m[1]))};
    return {ok: true, status: 200, json: async () => data};
  });
}
const allText = n => (n.textContent || "") + (n.children || []).map(allText).join("");
async function drawerText(cards, n) {
  const h = setup(cards);
  await h.flush();
  await h.ctx.openDrawer(n);
  await h.flush();
  const el = h.$("dr-hold");
  return el && !el.hidden ? allText(el) : "";
}

(async () => {
  const reason = "Scope overlaps #4 on scripts/x.sh";
  await test("A drawer for a card with hold.reason \"Scope overlaps #4 on scripts/x.sh\" contains the text Held: Scope overlaps #4 on scripts/x.sh", async () => {
    const t = await drawerText([mk(1, {hold: {reason, source: "scheduler", until: null}})], 1);
    assert.ok(t.includes("Held: " + reason), t);
  });

  await test("A hold with until set also shows that time", async () => {
    const until = "2026-11-13T12:00:00Z";
    const t = await drawerText([mk(1, {hold: {reason, source: "scheduler", until}})], 1);
    assert.ok(t.includes("Held: " + reason), t);
    assert.ok(t.includes(until), t);
  });

  await test("A drawer for a card with hold: null has no Held line", async () => {
    const t = await drawerText([mk(1, {hold: null})], 1);
    assert.ok(!t.includes("Held"), t);
  });

  process.exit(fails ? 1 : 0);
})();
JS
