#!/usr/bin/env bash
#
# Plain-bash tests: the new-card form has a Repo picker on a multi-repo board.
# Usage: bash plugins/fleet-board/tests/test-board-create-repo-picker.sh

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

let fails = 0;
async function test(name, fn) {
  try { await fn(); console.log("ok - " + name); }
  catch (e) { fails++; console.log("FAIL - " + name + ": " + e.message); }
}

function setup(repos) {
  const posts = [];
  const h = loadBoard(JS, async (url, opts) => {
    const method = (opts && opts.method) || "GET";
    let data = {};
    if (url === "/api/board") data = {repo: "acme/toy", repos, states, cards: [], run: {state: "idle"}};
    else if (method === "POST" && url === "/api/cards") {
      posts.push(JSON.parse(opts.body));
      data = {number: 9, title: "t", state: "backlog", labels: [], comments: [], acceptance: [], blocked_by: [], blocks: [], body: "", known: true};
    } else if (/^\/api\/cards\/9$/.test(url)) data = {number: 9, title: "t", state: "backlog", labels: [], comments: [], acceptance: [], blocked_by: [], blocks: [], body: "", known: true};
    return {ok: true, status: 200, json: async () => data};
  });
  h.posts = posts;
  return h;
}
async function openNew(repos) {
  const h = setup(repos);
  await h.flush();
  await h.ctx.openNewCard();
  await h.flush();
  return h;
}
const pickerOptions = h => h.$("dr-repo").children.map(o => ({value: o.value, text: o.textContent}));

(async () => {
  await test("With /api/board returning repos [acme/other] and repo acme/toy, the new-card form shows a Repo select whose options are acme/toy (selected) and acme/other", async () => {
    const h = await openNew(["acme/other"]);
    assert.equal(h.$("dr-repo").hidden, false);
    assert.deepEqual(pickerOptions(h).map(o => o.value), ["acme/toy", "acme/other"]);
    assert.equal(h.$("dr-repo").value, "acme/toy");
  });

  await test("With /api/board returning repos [], the new-card form has no Repo select, and the create request body has no repo key", async () => {
    const h = await openNew([]);
    assert.equal(h.$("dr-repo").hidden, true);
    h.$("dr-title").value = "Plain";
    await h.$("dr-save").fire("click");
    await h.flush();
    assert.equal(h.posts.length, 1);
    assert.equal("repo" in h.posts[0], false);
  });

  await test("Choosing acme/other and creating sends repo acme/other in the POST /api/cards body", async () => {
    const h = await openNew(["acme/other"]);
    h.$("dr-title").value = "Elsewhere";
    h.$("dr-repo").value = "acme/other";
    await h.$("dr-save").fire("click");
    await h.flush();
    assert.equal(h.posts.length, 1);
    assert.equal(h.posts[0].repo, "acme/other");
  });

  process.exit(fails ? 1 : 0);
})();
JS
