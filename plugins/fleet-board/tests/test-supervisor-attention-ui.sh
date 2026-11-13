#!/usr/bin/env bash
# The board shows a card's attention and the supervisor's real status values (card 257).
set -euo pipefail
unset CDPATH
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v node >/dev/null 2>&1; then
  echo "not ok - Node.js is required for supervisor UI tests" >&2
  exit 1
fi
HERE="$HERE" node - <<'JS'
"use strict";
const assert = require("node:assert/strict");
const path = require("node:path");
const here = process.env.HERE;
const loadBoard = require(path.join(here, "supervisor-ui-harness"));
const boardPath = path.join(here, "../scripts/board-web/static/board.js");
const states = [{key:"ready",name:"Ready"},{key:"merging",name:"Merging"}];
const card = (extra) => ({number:4,title:"Deploy",body:"",labels:[],comments:[],state:"merging",known:true,stuck:null,activity:null,...(extra||{})});
const status = (extra) => ({schema_version:2,revision:3,run_id:"r",mode:"running",pause_reason:null,pid:1,root:"/repo",
  desired_mode:"running",phase:"running",ready:true,active:[],lane:null,provider_health:{},run_tokens:{},
  capacity:{slots:1,global_cap:20,per_provider:{claude:1}},queue:{ready:2,running:1,waiting:3,attention:1},...(extra||{})});
const json = v => JSON.parse(JSON.stringify(v));
const response = (code, data) => ({ok:code>=200&&code<300,status:code,json:async()=>data});
function fakeFetch(snapshot, cards) {
  return async function (url) {
    const u = url.split("?")[0];
    if (u === "/api/board") return response(200,{repo:"acme/toy",states,cards:json(cards),run:{state:"idle"}});
    if (u === "/api/supervisor") return response(200,{...json(snapshot),running:true,cards:undefined});
    if (u === "/api/usage") return response(200,{run:null,all_time:null,planner:null});
    if (u === "/api/run") return response(200,{state:"idle"});
    return response(404,{error:"unexpected fake route"});
  };
}
async function open(snapshot, cards) {
  const h = loadBoard(boardPath, fakeFetch(snapshot, cards));
  await h.flush(); await h.waitForRequests();
  return h;
}
const descendants = root => [root, ...root.all()];
const cardOf = (h, n) => h.$("board").all().find(x => x.classList.contains("card") && x.dataset.n === String(n));
const failures = [];
async function check(name, fn) {
  try { await fn(); console.log("ok - " + name); }
  catch (e) { failures.push(name); console.log("not ok - " + name + " - " + e.message); }
}
(async () => {
  await check("a card with attention renders an ATTENTION badge with the reason as text", async () => {
    const reason = "merge refused again after a retry: base branch policy";
    const h = await open(status(), [card({attention:{reason}}), card({number:5,title:"Fine"})]);
    const badge = cardOf(h, 4).all().find(n => n.classList.contains("card-attention-badge"));
    assert.ok(badge, "no ATTENTION badge on the card");
    assert.equal(badge.textContent.trim(), "ATTENTION");
    assert.ok(cardOf(h, 4).textContent.includes(reason), "the reason is not shown: " + cardOf(h, 4).textContent);
    assert.equal(cardOf(h, 5).all().some(n => n.classList.contains("card-attention-badge")), false);
  });
  await check("the status strip renders no unknown text when the supervisor reports global_cap, ready, waiting and attention", async () => {
    const h = await open(status(), [card()]);
    const strip = h.$("supervisor-status");
    assert.doesNotMatch(strip.textContent, /unknown/i, strip.textContent);
    const items = {};
    for (const n of descendants(strip).filter(x => x.classList.contains("sup-item"))) {
      const kids = n.children.map(c => c.textContent);
      if (kids.length >= 2) items[kids[0]] = kids.slice(1).join(" ");
    }
    assert.equal(items.slots, "1 / 20");
  });
  if (failures.length) process.exit(1);
})();
JS
