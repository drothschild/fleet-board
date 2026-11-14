#!/usr/bin/env bash
#
# Plain-bash tests: the card drawer shows a read-only Blocks list.
# Usage: bash plugins/fleet-board/tests/test-board-drawer-blocks.sh

set -uo pipefail
unset CDPATH
DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
command -v node >/dev/null 2>&1 || { echo "skipped: node not on PATH"; exit 0; }

DIR="$DIR" node - <<'JS'
"use strict";
const assert = require("node:assert/strict");
const path = require("node:path");
const fs = require("node:fs");
const HTML = path.join(process.env.DIR, "../scripts/board-web/static/index.html");
const loadBoard = require(path.join(process.env.DIR, "board-interaction-harness.js"));
const JS = path.join(process.env.DIR, "../scripts/board-web/static/board.js");

const states = [{key: "backlog", name: "Backlog"}, {key: "ready", name: "Ready"}, {key: "done", name: "Done"}];
const mk = (number, extra) => ({number, title: "Card " + number, body: "", labels: [], comments: [],
  acceptance: [], blocked_by: [], blocks: [], state: "backlog", known: true, ...extra});

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
const chips = h => h.$("dr-blocks").all().filter(n => n.classList.contains("blk-chip"));
const allText = n => (n.textContent || "") + (n.children || []).map(allText).join("");

(async () => {
  const cards = [mk(1, {blocks: [2, 3]}), mk(2, {title: "Second", state: "ready"}), mk(3, {title: "Third", state: "done"}), mk(4)];

  await test("Opening the drawer for a card whose detail has blocks: [2, 3] shows one chip each for #2 and #3, with their titles", async () => {
    const h = setup(cards);
    await h.flush();
    await h.ctx.openDrawer(1);
    await h.flush();
    const cs = chips(h);
    assert.equal(cs.length, 2);
    assert.ok(allText(cs[0]).includes("#2") && allText(cs[0]).includes("Second"));
    assert.ok(allText(cs[1]).includes("#3") && allText(cs[1]).includes("Third"));
  });

  await test("A chip for a blocked card that is not done gets the open class, and one that is done gets the done class", async () => {
    const h = setup(cards);
    await h.flush();
    await h.ctx.openDrawer(1);
    await h.flush();
    const cs = chips(h);
    assert.ok(cs[0].classList.contains("open") && !cs[0].classList.contains("done"));
    assert.ok(cs[1].classList.contains("done") && !cs[1].classList.contains("open"));
  });

  await test("The Blocks chips have no remove button", async () => {
    const h = setup(cards);
    await h.flush();
    await h.ctx.openDrawer(1);
    await h.flush();
    const cs = chips(h);
    assert.equal(cs.length, 2);
    for (const c of cs) {
      assert.equal(c.all().filter(n => n.classList.contains("label-x") || n.tagName === "BUTTON").length, 0);
    }
  });

  await test("When blocks is empty, the drawer shows the Blocks heading with Nothing under it", async () => {
    const h = setup(cards);
    await h.flush();
    await h.ctx.openDrawer(4);
    await h.flush();
    assert.equal(h.$("dr-blocks-field").hidden, false);
    assert.match(fs.readFileSync(HTML, "utf8"), /<h3 id="dr-blocks-h"[^>]*>Blocks<\/h3>/);
    assert.equal(chips(h).length, 0);
    assert.equal(h.$("dr-blocks-none").textContent, "Nothing");
    assert.equal(h.$("dr-blocks-none").hidden, false);
  });

  await test("The drawer for a new card (create mode) has no Blocks field", async () => {
    const h = setup(cards);
    await h.flush();
    await h.ctx.openDrawer(1);
    await h.flush();
    await h.ctx.openDrawer(null);
    await h.flush();
    assert.equal(h.$("dr-blocks-field").hidden, true);
    assert.equal(chips(h).length, 0);
  });

  await test("Card tiles on the board have no blocks text", async () => {
    const h = setup(cards);
    await h.flush();
    const tile = h.$("board").all().find(x => x.classList.contains("card") && x.dataset.n === "1");
    assert.ok(tile);
    assert.ok(!/blocks/i.test(allText(tile)));
  });

  process.exit(fails ? 1 : 0);
})();
JS
