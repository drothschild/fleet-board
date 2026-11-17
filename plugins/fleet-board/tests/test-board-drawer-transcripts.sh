#!/usr/bin/env bash
#
# Plain-bash tests: the card drawer lists a card's transcripts as links that open in a new tab.
# Usage: bash plugins/fleet-board/tests/test-board-drawer-transcripts.sh

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

const states = [{key: "backlog", name: "Backlog"}];
const card = {number: 7, title: "Card 7", body: "", labels: [], comments: [], acceptance: [],
  blocked_by: [], state: "backlog", known: true};
const USAGE = {totals: {}, columns: [{column: "ready", totals: {}, actions: [
  {action: "start", role: "implementor", model: "sonnet", input: 1, output: 2, cache_read: 0, cache_write: 0,
   log: "/x/sessions/card-7-start-1.log"}]}]};

let fails = 0;
async function test(name, fn) {
  try { await fn(); console.log("ok - " + name); }
  catch (e) { fails++; console.log("FAIL - " + name + ": " + e.message); }
}

async function open(list) {
  const h = loadBoard(JS, async (url) => {
    let data = {};
    if (url === "/api/board") data = {repo: "a/b", states, cards: [{...card}], run: {state: "idle"}};
    else if (url === "/api/cards/7") data = {...card};
    else if (url === "/api/cards/7/usage") data = USAGE;
    else if (url === "/api/cards/7/transcripts") data = list;
    return {ok: true, status: 200, json: async () => data};
  });
  await h.flush();
  await h.ctx.openDrawer(7);
  await h.flush();
  return h;
}
const SESSIONS = [
  {id: "card-7-review-3000-2", action: "review", role: "reviewer", attempt: 2, ended_at: null, running: true},
  {id: "card-7-start-1000-1", action: "start", role: "implementor", attempt: 1, ended_at: "2026-01-01T00:00:00Z", running: false},
];
const links = h => h.$("dr-transcripts").all().filter(n => n.tagName === "A");

(async () => {
  await test("Each session from /api/cards/<n>/transcripts shows in the drawer as a link to its /api/cards/<n>/transcripts/<id> URL", async () => {
    const h = await open(SESSIONS);
    assert.deepEqual(links(h).map(a => a.getAttribute("href")),
      ["/api/cards/7/transcripts/card-7-review-3000-2", "/api/cards/7/transcripts/card-7-start-1000-1"]);
  });

  await test("Each transcript link has target=\"_blank\" so it opens in a new tab", async () => {
    const h = await open(SESSIONS);
    assert.equal(links(h).length, 2);
    for (const a of links(h)) assert.equal(a.getAttribute("target"), "_blank");
  });

  await test("A running session's link shows \"running\" next to it", async () => {
    const h = await open(SESSIONS);
    const items = h.$("dr-transcripts").all().filter(n => n.tagName === "LI");
    assert.equal(items.length, 2);
    assert.match(items[0].textContent, /running/);
    assert.doesNotMatch(items[1].textContent, /running/);
  });

  await test("A card with no sessions shows \"No transcripts yet.\"", async () => {
    const h = await open([]);
    assert.match(h.$("dr-transcripts").textContent, /No transcripts yet\./);
    assert.equal(links(h).length, 0);
  });

  await test("The drawer no longer shows the plain-text \"log <path>\" line", async () => {
    const h = await open(SESSIONS);
    assert.doesNotMatch(h.$("dr-usage-cols").textContent, /log \/x\/sessions/);
    assert.equal(h.$("dr-usage-cols").all().filter(n => n.classList.contains("dr-usage-log")).length, 0);
  });

  console.log(fails + " failing");
  process.exitCode = fails ? 1 : 0;
})();
EOF
