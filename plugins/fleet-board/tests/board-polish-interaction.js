"use strict";
const assert = require("node:assert/strict");
const path = require("node:path");
const loadBoard = require("./board-interaction-harness");
async function setup(overrides = {}, intercept = () => null) {
  const card = {number: 4, title: "Card", body: "", labels: [], comments: [], state: "backlog", ...overrides};
  const calls = [];
  const h = loadBoard(path.join(__dirname, "../scripts/board-web/static/board.js"), async (url, opts) => {
    const body = opts.body && JSON.parse(opts.body);
    calls.push({url, method: opts.method, body});
    const custom = await intercept(url, opts, body, card);
    if (custom) return custom;
    let data;
    if (url === "/api/board") data = {repo: "acme/toy", states: [{key: "backlog", name: "Backlog"}, {key: "ready", name: "Ready"}], cards: [{...card}], run: {state: "idle"}};
    else if (url === "/api/run") data = {state: "idle"};
    else if (url === "/api/cards/4" && opts.method === "GET") data = {...card};
    else if (url === "/api/cards/4" && opts.method === "PATCH") { Object.assign(card, body); data = {...card}; }
    else if (url === "/api/cards/4/move" && opts.method === "POST") { card.state = body.state; data = {...card}; }
    else throw new Error("Unexpected request " + opts.method + " " + url);
    return {ok: true, status: 200, json: async () => data};
  });
  await h.flush();
  assert.equal(h.ctx.__test.S.offline, false);
  h.card = card; h.calls = calls;
  h.open = async () => {
    const el = h.$("board").all().find(n => n.classList.contains("card"));
    await el.fire("click");
    assert.equal(h.$("drawer").hidden, false);
  };
  return h;
}
(async () => {
  const text = "same note";
  const h = await setup({manager_note: text, manager_note_id: 2, comments: [1, 2, 3].map(id => ({id, author: "tester", body: "<!-- fleet-board:manager-note -->\n" + text}))});
  await h.open();
  const toggles = h.$("dr-comments").all().filter(n => n.classList.contains("note-toggle"));
  assert.equal(toggles.length, 1);
  assert.equal(toggles[0].getAttribute("aria-controls"), "note-json-2");
  console.log("PASS identical comment bodies collapse only manager_note_id");

  h.$("dr-title").value = "Unsaved title";
  await h.$("dr-title").fire("input");
  let prompts = 0;
  h.ctx.confirm = () => { prompts++; return false; };
  await h.$("dr-close").fire("click");
  assert.equal(prompts, 1);
  assert.equal(h.$("drawer").hidden, false);
  assert.equal(h.$("dr-title").value, "Unsaved title");
  h.ctx.confirm = () => { prompts++; return true; };
  await h.$("dr-close").fire("click");
  assert.equal(prompts, 2);
  assert.equal(h.$("drawer").hidden, true);
  await h.open();
  assert.equal(h.$("dr-title").value, "Card");
  console.log("PASS cancelled close keeps edits; confirmed close discards them");

  let release;
  const pendingPatch = new Promise(resolve => { release = resolve; });
  const delayed = await setup({}, async (url, opts) => {
    if (opts.method === "PATCH") await pendingPatch;
    return null;
  });
  await delayed.open();
  delayed.$("dr-title").value = "Saved title";
  delayed.$("dr-state").value = "ready";
  await delayed.$("dr-title").fire("input");
  const saving = delayed.$("dr-save").fire("click");
  await delayed.flush();
  assert.ok(delayed.calls.some(c => c.method === "PATCH"));
  assert.ok(!delayed.calls.some(c => c.url.endsWith("/move")));
  await delayed.$("dr-close").fire("click");
  assert.equal(delayed.$("drawer").hidden, true);
  release(); await saving;
  assert.equal(delayed.card.title, "Saved title");
  assert.equal(delayed.card.state, "ready");
  const moved = delayed.$("board").all().find(n => n.classList.contains("card"));
  assert.equal(moved.closest("section").dataset.state, "ready");
  console.log("PASS closing during PATCH still completes move and refreshes board");

  const partial = await setup({}, async (url, opts) => {
    if (url === "/api/cards" && opts.method === "POST") return {ok: false, status: 409, json: async () => ({error: "created card #4; move to ready refused: missing Acceptance"})};
    return null;
  });
  await partial.$("new-card-btn").fire("click");
  partial.$("dr-title").value = "New card";
  partial.$("dr-state").value = "ready";
  await partial.$("dr-title").fire("input");
  await partial.$("dr-save").fire("click");
  assert.match(partial.$("toast").textContent, /^Created #4 in Backlog/);
  assert.match(partial.$("toast").textContent, /move to ready refused/);
  console.log("PASS partial-create toast names created card and refused move");

  let healthy = false;
  const polling = await setup({}, async url => {
    if (url === "/api/import/job") return {ok: healthy, status: healthy ? 200 : 503, json: async () => healthy ? {state: "running", elapsed_s: 2, last_text: "working"} : {error: "unavailable"}};
    return null;
  });
  polling.ctx.__test.S.imp = {id: "job", phase: "running", cards: []};
  for (let n = 1; n <= 3; n++) {
    await polling.ctx.__test.pollImport("job");
    assert.equal(polling.$("imp-status").textContent.includes("board server not answering"), n === 3);
  }
  healthy = true; await polling.ctx.__test.pollImport("job");
  assert.equal(polling.ctx.__test.S.imp.fails, 0);
  healthy = false; await polling.ctx.__test.pollImport("job");
  assert.equal(polling.ctx.__test.S.imp.fails, 1);
  console.log("PASS three consecutive failed polls warn; success resets the counter");
})().catch(e => { console.error(e); process.exitCode = 1; });
