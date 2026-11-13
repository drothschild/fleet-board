#!/usr/bin/env bash
#
# Plain-bash tests: the draft preview footer has a "Create in" select, Backlog
# by default. Needs node.
# Usage: bash plugins/fleet-board/tests/test-board-draft-create-in.sh

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

let fails = 0;
async function test(name, fn) {
  try { await fn(); console.log("ok - " + name); }
  catch (e) { fails++; console.log("FAIL - " + name + ": " + e.message); }
}

function setup() {
  const posts = [];
  const h = loadBoard(JS, async (url, o) => {
    const method = (o && o.method) || "GET";
    let data = {};
    if (url === "/api/board") data = {repo: "acme/toy", states, cards: [], run: {state: "idle"}};
    else if (method === "POST" && /\/create$/.test(url)) { posts.push({url, body: JSON.parse(o.body)}); data = {error: "x"}; }
    return {ok: !data.error, status: data.error ? 409 : 200, json: async () => data};
  });
  return {h, posts};
}

(async () => {
  await test("When the import preview is ready, the footer shows a select labelled Create in with the options Backlog and Ready", async () => {
    const html = fs.readFileSync(HTML, "utf8");
    const foot = html.slice(html.indexOf('class="imp-foot"'));
    assert.ok(/<label[^>]*>[^<]*Create in[^<]*<select[^>]*id="imp-status-select"/.test(foot), "footer markup: " + /<label[^>]*>[^<]*Create in[^<]*<select[^>]*id="imp-status-select"/);
    assert.ok(/<option value="backlog"[^>]*>Backlog<\/option>/.test(foot), "footer markup: " + /<option value="backlog"[^>]*>Backlog<\/option>/);
    assert.ok(/<option value="ready"[^>]*>Ready<\/option>/.test(foot), "footer markup: " + /<option value="ready"[^>]*>Ready<\/option>/);
    const {h} = setup();
    await h.flush();
    h.ctx.openDraft("abc", "plan");
    assert.equal(h.$("imp-status-row").hidden, true, "hidden while running");
    h.ctx.setImportPhase("ready");
    assert.equal(h.$("imp-status-row").hidden, false, "shown when ready");
  });

  await test("Each new import preview has Backlog selected, even when the previous import used Ready", async () => {
    const {h} = setup();
    await h.flush();
    h.ctx.openDraft("abc", "plan");
    h.ctx.setImportPhase("ready");
    assert.equal(h.$("imp-status-select").value, "backlog");
    h.$("imp-status-select").value = "ready";
    h.ctx.closeImport();
    h.ctx.openDraft("def", "plan");
    assert.equal(h.$("imp-status-select").value, "backlog");
  });

  await test("Clicking Create cards sends the selected value as status in the POST /api/import/<id>/create body", async () => {
    const {h, posts} = setup();
    await h.flush();
    h.ctx.openDraft("abc", "plan");
    h.ctx.setImportPhase("ready");
    h.$("imp-status-select").value = "ready";
    await h.ctx.createImport("abc");
    await h.flush();
    assert.equal(posts.length, 1);
    assert.equal(posts[0].body.status, "ready");
  });

  await test("The select is hidden while the draft is running and disabled while cards are being created", async () => {
    const {h} = setup();
    await h.flush();
    h.ctx.openDraft("abc", "plan");
    assert.equal(h.$("imp-status-row").hidden, true);
    h.ctx.setImportPhase("ready");
    assert.equal(h.$("imp-status-select").disabled, false);
    h.ctx.setImportPhase("creating");
    assert.equal(h.$("imp-status-select").disabled, true);
    assert.equal(h.$("imp-status-row").hidden, false);
  });

  console.log(fails + " failing");
  process.exitCode = fails ? 1 : 0;
})();
EOF
