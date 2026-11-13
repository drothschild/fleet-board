#!/usr/bin/env bash
#
# Plain-bash tests: drawer and import-view polish (manager note by id, confirm on
# unsaved close, in-flight save survives close, partial-create toast, live
# region, poll failure). Usage: bash plugins/fleet-board/tests/test-board-drawer-polish.sh

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
const JS = path.join(process.env.DIR, "../scripts/board-web/static/board.js");
const HTML = path.join(process.env.DIR, "../scripts/board-web/static/index.html");

const states = [{key: "backlog", name: "Backlog"}, {key: "ready", name: "Ready"}];
const MARKER = "<!-- fleet-board:manager-note -->";
const NOTE = "```json\n{\"round\": 1}\n```";
const mk = (number, extra) => ({number, title: "Card " + number, body: "", labels: [], comments: [],
  acceptance: [], blocked_by: [], state: "backlog", known: true, ...extra});

let fails = 0;
async function test(name, fn) {
  try { await fn(); console.log("ok - " + name); }
  catch (e) { fails++; console.log("FAIL - " + name + ": " + e.message); }
}

// A fake board server. `hold` makes a route wait until released.
function setup(opts = {}) {
  const cards = (opts.cards || [mk(1)]).map(c => ({...c}));
  const held = [];
  const calls = [];
  const hold = opts.hold || (() => false);
  const h = loadBoard(JS, async (url, o) => {
    const method = (o && o.method) || "GET";
    calls.push(method + " " + url);
    if (hold(method, url)) await new Promise(r => held.push(r));
    let status = 200, data = {};
    let m;
    if (url === "/api/board") data = {repo: "acme/toy", states, cards: cards.map(c => ({...c})), run: {state: "idle"}};
    else if (method === "GET" && (m = /^\/api\/cards\/(\d+)$/.exec(url))) data = {...cards.find(c => c.number === Number(m[1]))};
    else if (method === "PATCH" && (m = /^\/api\/cards\/(\d+)$/.exec(url))) {
      Object.assign(cards.find(c => c.number === Number(m[1])), JSON.parse(o.body));
      data = {};
    } else if ((m = /^\/api\/cards\/(\d+)\/move$/.exec(url))) {
      cards.find(c => c.number === Number(m[1])).state = JSON.parse(o.body).state;
      data = {};
    } else if (opts.route) {
      const r = opts.route(method, url, o);
      if (r) { status = r.status; data = r.data; }
    }
    return {ok: status < 400, status, json: async () => data};
  });
  return {h, cards, held, calls};
}
const colOf = (h, n) => {
  const tile = h.$("board").all().find(x => x.classList.contains("card") && x.dataset.n === String(n));
  if (!tile) return null;
  for (let p = tile.parent; p; p = p.parent) if (p.dataset && p.dataset.state) return p.dataset.state;
  return null;
};

(async () => {
  await test("Two comments with an identical body where only one id equals manager_note_id: the drawer collapses exactly that one", async () => {
    const body = MARKER + "\n" + NOTE;
    const {h} = setup({cards: [mk(1, {
      manager_note: NOTE, manager_note_id: 11,
      comments: [{id: 11, author: "a", body, created_at: ""}, {id: 12, author: "a", body, created_at: ""}],
    })]});
    await h.flush();
    await h.ctx.openDrawer(1);
    await h.flush();
    const toggles = h.$("dr-comments").all().filter(n => n.classList.contains("note-toggle"));
    assert.equal(toggles.length, 1);
    assert.equal(toggles[0].getAttribute("aria-controls"), "note-json-11");
  });

  await test("Closing the drawer with unsaved edits calls confirm; on cancel the drawer stays open with the edits", async () => {
    const {h} = setup();
    await h.flush();
    let asked = 0;
    h.ctx.confirm = () => { asked++; return false; };
    await h.ctx.openDrawer(1);
    await h.flush();
    h.$("dr-title").value = "edited title";
    await h.$("dr-title").fire("input");
    await h.$("dr-close").fire("click");
    assert.equal(asked, 1);
    assert.equal(h.$("drawer").hidden, false);
    assert.ok(h.ctx.__test.S.drawer);
    assert.equal(h.$("dr-title").value, "edited title");
  });

  await test("Closing the drawer with unsaved edits calls confirm; on confirm it closes", async () => {
    const {h} = setup();
    await h.flush();
    let asked = 0;
    h.ctx.confirm = () => { asked++; return true; };
    await h.ctx.openDrawer(1);
    await h.flush();
    h.$("dr-title").value = "edited title";
    await h.$("dr-title").fire("input");
    await h.$("dr-close").fire("click");
    assert.equal(asked, 1);
    assert.equal(h.$("drawer").hidden, true);
    assert.equal(h.ctx.__test.S.drawer, null);
  });

  await test("Closing a drawer with no edits never calls confirm", async () => {
    const {h} = setup();
    await h.flush();
    let asked = 0;
    h.ctx.confirm = () => { asked++; return false; };
    await h.ctx.openDrawer(1);
    await h.flush();
    await h.$("dr-close").fire("click");
    assert.equal(asked, 0);
    assert.equal(h.$("drawer").hidden, true);
  });

  await test("Closing the drawer before a state-changing PATCH resolves: the board shows the card in the new column after the next poll", async () => {
    const {h, held} = setup({hold: (m) => m === "PATCH"});
    await h.flush();
    await h.ctx.openDrawer(1);
    await h.flush();
    h.$("dr-title").value = "renamed";
    h.$("dr-state").value = "ready";
    await h.$("dr-title").fire("input");
    h.$("dr-save").listeners.click[0]();      // not awaited: the PATCH is held
    await h.flush();
    assert.equal(held.length, 1, "PATCH is in flight");
    await h.$("dr-close").fire("click");
    held.splice(0).forEach(r => r());
    await h.flush();
    assert.equal(h.ctx.__test.S.drawer, null);
    assert.equal(colOf(h, 1), "ready");
  });

  await test("Create answering 409 with a partial create: the toast begins Created #<n> in Backlog and names the refused move", async () => {
    const {h} = setup({route: (m, url) => m === "POST" && url === "/api/cards"
      ? {status: 409, data: {error: "created card #7 in backlog, but the move to ready failed: blocked by #3"}} : null});
    await h.flush();
    await h.ctx.openDrawer(null);
    await h.flush();
    h.$("dr-title").value = "New thing";
    h.$("dr-state").value = "ready";
    await h.$("dr-title").fire("input");
    await h.$("dr-save").fire("click");
    await h.flush();
    const t = h.$("toast").textContent;
    assert.ok(t.startsWith("Created #7 in Backlog"), "toast was: " + t);
    assert.match(t, /move to Ready/);
    assert.doesNotMatch(t, /Card not created/);
  });

  await test("#imp-progress in index.html has no role=status and only #imp-last carries aria-live=polite", async () => {
    const html = fs.readFileSync(HTML, "utf8");
    const tag = id => (new RegExp("<[a-z]+ [^>]*id=\"" + id + "\"[^>]*>").exec(html) || [""])[0];
    assert.ok(tag("imp-progress"), "found #imp-progress");
    assert.doesNotMatch(tag("imp-progress"), /role="status"/);
    assert.doesNotMatch(tag("imp-progress"), /aria-live/);
    assert.match(tag("imp-last"), /aria-live="polite"/);
    for (const id of ["imp-elapsed", "imp-status", "imp-grid"]) assert.doesNotMatch(tag(id), /aria-live/);
  });

  await test("Three polls of GET /api/import/<id> fail: the status line reads board server not answering", async () => {
    const {h} = setup({route: (m, url) => /^\/api\/import\//.test(url) ? {status: 503, data: {}} : null});
    await h.flush();
    h.ctx.openDraft("abc", "plan text");
    for (let i = 0; i < 3; i++) {
      const fn = h.timers.pop();
      assert.ok(fn, "a poll is scheduled (round " + (i + 1) + ")");
      await fn();
      await h.flush();
    }
    assert.match(h.$("imp-status").textContent, /board server not answering/);
  });

  console.log(fails + " failing");
  process.exitCode = fails ? 1 : 0;
})();
EOF
