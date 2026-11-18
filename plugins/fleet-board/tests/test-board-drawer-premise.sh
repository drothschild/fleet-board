#!/usr/bin/env bash
#
# Plain-bash tests: the card drawer shows a premise proposal with its buttons, and the tile names it.
# Usage: bash plugins/fleet-board/tests/test-board-drawer-premise.sh

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

const states = [{key: "ready", name: "Ready"}, {key: "blocked", name: "Blocked"}, {key: "done", name: "Done"}];
const HEAD = "0123456789abcdef0123456789abcdef01234567";
const rewrite = {kind: "rewrite", summary: "Narrow the scope to one script", scope: "- plugins/x/new-scope.sh",
  acceptance: ["proposed acceptance one"], head: HEAD, at: "2026-01-01T00:00:00Z"};
const close = {kind: "close", head: HEAD, at: "2026-01-01T00:00:00Z",
  evidence: [{item: 1, command: "ls plugins/x", output: "built-output-text"}, {item: 2, command: "grep -c y z", output: "3"}]};
const mk = (number, extra) => ({number, title: "Card " + number, body: "## Scope\n- plugins/x/old-scope.sh\n", labels: [], comments: [],
  acceptance: ["current acceptance one", "second item"], blocked_by: [], blocks: [], state: "blocked", known: true,
  proposal: null, premise: null, ...extra});

let fails = 0;
async function test(name, fn) {
  try { await fn(); console.log("ok - " + name); }
  catch (e) { fails++; console.log("FAIL - " + name + ": " + e.message); }
}

function setup(cards, reply) {
  const calls = [];
  const h = loadBoard(JS, async (url, opts) => {
    const method = (opts && opts.method) || "GET";
    calls.push({url, method});
    let data = {}, m, status = 200;
    if (url === "/api/board") data = {repo: "acme/toy", states,
      cards: cards.map(c => ({...c, proposal_kind: c.proposal ? c.proposal.kind : null})), run: {state: "idle"}};
    else if (method === "POST" && (m = /^\/api\/cards\/(\d+)\/(premise\/\w+|move)$/.exec(url))) {
      const r = await reply(url);
      status = r.status; data = r.data;
    } else if ((m = /^\/api\/cards\/(\d+)$/.exec(url))) data = {...cards.find(c => c.number === Number(m[1]))};
    return {ok: status < 400, status, json: async () => data};
  });
  h.calls = calls;
  h.posts = () => calls.filter(c => c.method === "POST");
  return h;
}
async function open(cards, n, reply) {
  const h = setup(cards, reply || (async () => ({status: 200, data: {}})));
  await h.flush();
  await h.ctx.openDrawer(n);
  await h.flush();
  return h;
}
const allText = n => (n.textContent || "") + (n.children || []).map(allText).join("");
const buttons = h => h.$("dr-premise").all().filter(n => n.tagName === "BUTTON");
const labels = h => buttons(h).map(b => b.textContent.trim());
const button = (h, label) => buttons(h).find(b => b.textContent.trim() === label);

(async () => {
  await test("A Blocked card with a rewrite proposal renders the summary, the current and proposed Scope and acceptance", async () => {
    const h = await open([mk(1, {proposal: rewrite})], 1);
    const t = allText(h.$("dr-premise"));
    for (const s of [rewrite.summary, "old-scope.sh", "new-scope.sh", "current acceptance one", "proposed acceptance one"])
      assert.ok(t.includes(s), "missing: " + s);
    assert.equal(h.$("dr-premise").hidden, false);
  });

  await test("A rewrite proposal has buttons labelled Approve rewrite and Reject", async () => {
    const h = await open([mk(1, {proposal: rewrite})], 1);
    assert.deepEqual(labels(h), ["Approve rewrite", "Reject"]);
  });

  await test("A rewrite proposal's tile shows Rewrite proposed", async () => {
    const h = setup([mk(1, {proposal: rewrite})], async () => ({status: 200, data: {}}));
    await h.flush();
    const li = h.ctx.renderCard({...mk(1, {proposal: rewrite}), proposal_kind: "rewrite"}, "acme/toy");
    assert.ok(allText(li).includes("Rewrite proposed"), allText(li));
  });

  await test("A close proposal renders each acceptance item with its command and output", async () => {
    const h = await open([mk(2, {proposal: close})], 2);
    const t = allText(h.$("dr-premise"));
    for (const s of ["current acceptance one", "second item", "ls plugins/x", "built-output-text", "grep -c y z"])
      assert.ok(t.includes(s), "missing: " + s);
  });

  await test("A close proposal has buttons labelled Close as built and Build it anyway", async () => {
    const h = await open([mk(2, {proposal: close})], 2);
    assert.deepEqual(labels(h), ["Close as built", "Build it anyway"]);
  });

  await test("A close proposal's tile shows Already built?", async () => {
    const h = setup([], async () => ({status: 200, data: {}}));
    await h.flush();
    const li = h.ctx.renderCard({...mk(2, {proposal: close}), proposal_kind: "close"}, "acme/toy");
    assert.ok(allText(li).includes("Already built?"), allText(li));
  });

  await test("A card with no proposal renders none of those buttons and no tile badge", async () => {
    const h = await open([mk(3)], 3);
    assert.deepEqual(labels(h), []);
    assert.equal(h.$("dr-premise").hidden, true);
    const li = h.ctx.renderCard({...mk(3), proposal_kind: null}, "acme/toy");
    assert.ok(!/Rewrite proposed|Already built\?/.test(allText(li)));
  });

  await test("Pressing a button posts to its route once and disables it while the request is open", async () => {
    for (const [card, label, url] of [
      [mk(1, {proposal: rewrite}), "Approve rewrite", "/api/cards/1/premise/approve"],
      [mk(1, {proposal: rewrite}), "Reject", "/api/cards/1/premise/reject"],
      [mk(2, {proposal: close}), "Close as built", "/api/cards/2/premise/confirm"],
      [mk(2, {proposal: close}), "Build it anyway", "/api/cards/2/move"],
    ]) {
      let release;
      const gate = new Promise(r => { release = r; });
      const h = await open([card], card.number, async () => { await gate; return {status: 200, data: {...card, proposal: null, state: "ready"}}; });
      const click = button(h, label).fire("click");
      await h.flush();
      assert.equal(button(h, label).disabled, true, label + " enabled while open");
      release();
      await click;
      await h.flush();
      const p = h.posts();
      assert.equal(p.length, 1, label + " posted " + p.length);
      assert.equal(p[0].url, url);
    }
  });

  process.exit(fails ? 1 : 0);
})();
JS
