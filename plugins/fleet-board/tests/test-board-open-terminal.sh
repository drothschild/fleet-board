#!/usr/bin/env bash
#
# Plain-bash tests: the "Open terminal" link on the card tile and in the drawer.
# Usage: bash plugins/fleet-board/tests/test-board-open-terminal.sh

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

const states = [{key: "backlog", name: "Backlog"}, {key: "ready", name: "Ready"}];
const mk = (number, extra) => ({number, title: "Card " + number, body: "", labels: [], comments: [],
  acceptance: [], blocked_by: [], state: "ready", known: true, worktree: null, ...extra});

let fails = 0;
async function test(name, fn) {
  try { await fn(); console.log("ok - " + name); }
  catch (e) { fails++; console.log("FAIL - " + name + ": " + e.message); }
}

function setup(cards, terminal) {
  const calls = [];
  const h = loadBoard(JS, async (url, o) => {
    const method = (o && o.method) || "GET";
    calls.push(method + " " + url);
    let status = 200, data = {}, m;
    if (url === "/api/board") data = {repo: "acme/toy", states, cards: cards.map(c => ({...c})), run: {state: "idle"}};
    else if (method === "GET" && (m = /^\/api\/cards\/(\d+)$/.exec(url))) data = {...cards.find(c => c.number === Number(m[1]))};
    else if (method === "POST" && /\/terminal$/.test(url)) {
      if (terminal) { status = terminal.status; data = terminal.data; }
    }
    return {ok: status < 400, status, json: async () => data};
  });
  return {h, calls};
}
const tileOf = (h, n) => h.$("board").all().find(x => x.classList.contains("card") && x.dataset.n === String(n));
const linksIn = node => node.all().filter(x => x.classList.contains("open-terminal"));
const ev = {stopPropagation() {}};

(async () => {
  await test("A tile whose card has a worktree shows an Open terminal link", async () => {
    const {h} = setup([mk(1, {worktree: "/tmp/wt/1"})]);
    await h.flush();
    const links = linksIn(tileOf(h, 1));
    assert.equal(links.length, 1);
    assert.equal(links[0].textContent, "Open terminal");
  });

  await test("A tile whose card has worktree null shows no Open terminal link", async () => {
    const {h} = setup([mk(2, {worktree: null})]);
    await h.flush();
    assert.ok(tileOf(h, 2));
    assert.equal(linksIn(tileOf(h, 2)).length, 0);
  });

  await test("Clicking the link sends exactly one POST to /api/cards/<n>/terminal and does not open the drawer", async () => {
    const {h, calls} = setup([mk(3, {worktree: "/tmp/wt/3"})]);
    await h.flush();
    const link = linksIn(tileOf(h, 3))[0];
    assert.ok(link, "link exists");
    await link.fire("click", ev);
    const posts = calls.filter(c => c === "POST /api/cards/3/terminal");
    assert.equal(posts.length, 1);
    assert.equal(h.ctx.__test.S.drawer, null);
    assert.equal(calls.filter(c => c === "GET /api/cards/3").length, 0);
  });

  await test("If the POST fails, a toast shows the server's error message", async () => {
    const {h} = setup([mk(4, {worktree: "/tmp/wt/4"})], {status: 500, data: {error: "no terminal here"}});
    await h.flush();
    const link = linksIn(tileOf(h, 4))[0];
    assert.ok(link, "link exists");
    await link.fire("click", ev);
    assert.equal(h.$("toast").hidden, false);
    assert.match(h.$("toast").textContent, /no terminal here/);
  });

  await test("The card drawer shows the same Open terminal link when worktree is set", async () => {
    const {h} = setup([mk(5, {worktree: "/tmp/wt/5"}), mk(6, {worktree: null})]);
    await h.flush();
    await h.ctx.openDrawer(5);
    await h.flush();
    const links = linksIn(h.$("dr-meta"));
    assert.equal(links.length, 1);
    assert.equal(links[0].textContent, "Open terminal");
    await h.ctx.openDrawer(6);
    await h.flush();
    assert.equal(linksIn(h.$("dr-meta")).length, 0);
  });

  console.log(fails + " failing");
  process.exitCode = fails ? 1 : 0;
})();
EOF
