#!/usr/bin/env bash
#
# Plain-bash tests: the card drawer has an Accept button for Blocked cards.
# Usage: bash plugins/fleet-board/tests/test-board-drawer-accept.sh

set -uo pipefail
unset CDPATH
DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
command -v node >/dev/null 2>&1 || { echo "skipped: node not on PATH"; exit 0; }

DIR="$DIR" node - <<'JS'
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const loadBoard = require(path.join(process.env.DIR, "board-interaction-harness.js"));
const JS = path.join(process.env.DIR, "../scripts/board-web/static/board.js");
const HTML = fs.readFileSync(path.join(process.env.DIR, "../scripts/board-web/static/index.html"), "utf8");

const states = [{key: "ready", name: "Ready"}, {key: "in_review", name: "In review"}, {key: "blocked", name: "Blocked"}];
const mk = (number, extra) => ({number, title: "Card " + number, body: "", labels: [], comments: [],
  acceptance: [], blocked_by: [], blocks: [], state: "ready", known: true, ...extra});

let fails = 0;
async function test(name, fn) {
  try { await fn(); console.log("ok - " + name); }
  catch (e) { fails++; console.log("FAIL - " + name + ": " + e.message); }
}

// acceptReply(url) -> {status, data} for POST /accept
function setup(cards, acceptReply) {
  const calls = [];
  const h = loadBoard(JS, async (url, opts) => {
    calls.push({url, method: (opts && opts.method) || "GET"});
    let data = {}, m, status = 200;
    if (url === "/api/board") data = {repo: "acme/toy", states, cards: cards.map(c => ({...c})), run: {state: "idle"}};
    else if ((m = /^\/api\/cards\/(\d+)\/accept$/.exec(url))) {
      const r = await acceptReply(Number(m[1]));
      status = r.status; data = r.data;
    } else if ((m = /^\/api\/cards\/(\d+)$/.exec(url))) data = {...cards.find(c => c.number === Number(m[1]))};
    return {ok: status < 400, status, json: async () => data};
  });
  h.calls = calls;
  h.accepts = () => calls.filter(c => c.url.endsWith("/accept"));
  return h;
}
async function open(cards, n, acceptReply) {
  const h = setup(cards, acceptReply || (async () => ({status: 200, data: {}})));
  await h.flush();
  await h.ctx.openDrawer(n);
  await h.flush();
  return h;
}
const allText = n => (n.textContent || "") + (n.children || []).map(allText).join("");

(async () => {
  await test("index.html has a dr-accept button in the drawer header", async () => {
    assert.ok(/<button[^>]*id="dr-accept"/.test(HTML), "no #dr-accept button");
  });

  await test("The drawer for a card in blocked shows an Accept button", async () => {
    const h = setup([mk(1, {state: "blocked"})], async () => ({status: 200, data: {}}));
    await h.flush();
    h.$("dr-accept").hidden = true; // as index.html ships it
    await h.ctx.openDrawer(1);
    await h.flush();
    assert.equal(h.$("dr-accept").hidden, false);
  });

  await test("The drawer for a card in any other state has no Accept button", async () => {
    for (const s of ["ready", "in_review"]) {
      const h = await open([mk(1, {state: s})], 1);
      assert.equal(h.$("dr-accept").hidden, true, s);
    }
  });

  await test("Clicking Accept and confirming the dialog sends POST /api/cards/<n>/accept and the state picker shows the returned state", async () => {
    const h = await open([mk(7, {state: "blocked"})], 7, async () => ({status: 200, data: mk(7, {state: "in_review"})}));
    h.ctx.confirm = () => true;
    await h.$("dr-accept").fire("click");
    const a = h.accepts();
    assert.equal(a.length, 1);
    assert.equal(a[0].url, "/api/cards/7/accept");
    assert.equal(a[0].method, "POST");
    assert.equal(h.$("dr-state").value, "in_review");
  });

  await test("Dismissing the confirmation dialog sends no request", async () => {
    const h = await open([mk(7, {state: "blocked"})], 7);
    let asked = 0;
    h.ctx.confirm = () => { asked++; return false; };
    await h.$("dr-accept").fire("click");
    assert.equal(asked, 1, "the dialog was not shown");
    assert.equal(h.accepts().length, 0);
  });

  await test("A 409 response shows the server's message in the drawer and the state picker still shows blocked", async () => {
    const msg = "card 7 names no PR";
    const h = await open([mk(7, {state: "blocked"})], 7, async () => ({status: 409, data: {error: msg}}));
    h.ctx.confirm = () => true;
    await h.$("dr-accept").fire("click");
    assert.ok(allText(h.$("dr-accept-err")).includes(msg), allText(h.$("dr-accept-err")));
    assert.equal(h.$("dr-accept-err").hidden, false);
    assert.equal(h.$("dr-state").value, "blocked");
  });

  await test("The Accept button is disabled while its request is in flight", async () => {
    let release;
    const gate = new Promise(r => { release = r; });
    const h = await open([mk(7, {state: "blocked"})], 7, async () => { await gate; return {status: 200, data: mk(7, {state: "in_review"})}; });
    h.ctx.confirm = () => true;
    const click = h.$("dr-accept").fire("click");
    await h.flush();
    assert.equal(h.$("dr-accept").disabled, true);
    release();
    await click;
    await h.flush();
    assert.equal(h.$("dr-accept").disabled, false);
  });

  process.exit(fails ? 1 : 0);
})();
JS
