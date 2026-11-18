#!/usr/bin/env bash
#
# Plain-bash tests for the board page's board.js: a node harness loads it with a
# DOM shim. Usage: bash plugins/fleet-board/tests/test-board-js.sh

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
JS="$DIR/../scripts/board-web/static/board.js"
CSS="$DIR/../scripts/board-web/static/board.css"
command -v node >/dev/null 2>&1 || { echo "skipped: node not on PATH"; exit 0; }

FAIL=0
check() { # check <name> <command...>
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "ok - $name"; else echo "not ok - $name"; FAIL=$((FAIL + 1)); fi
}

check "board.js has no regex lookbehind" bash -c "! grep -q '(?<' '$JS'"
check "node --check passes on board.js" node --check "$JS"
check "board.css has no card-now rule" bash -c "! grep -q 'card-now' '$CSS'"

check "index.html has a labelled Stacked on drawer field with a parent link" bash -c "grep -q 'id=\"dr-stack-h\" class=\"dr-h\">Stacked on<' '$DIR/../scripts/board-web/static/index.html' && grep -q 'id=\"dr-stack-link\"' '$DIR/../scripts/board-web/static/index.html'"

node "$DIR/board-js-harness.js" "$JS" || FAIL=$((FAIL + 1))

# Column header reviewer line: a second node script with its own small DOM shim.
HDR_JS="$(mktemp)"
cat >"$HDR_JS" <<'NODE'
"use strict";
const fs = require("fs");
const vm = require("vm");
class N {
  constructor(tag) { this.tagName = tag; this.children = []; this.dataset = {}; this.attrs = {}; this.classes = new Set(); this._text = ""; this.hidden = false; this.scrollTop = 0; const self = this;
    this.classList = { add(c) { self.classes.add(c); }, remove(c) { self.classes.delete(c); }, contains(c) { return self.classes.has(c); }, toggle(c, on) { if (on === undefined ? !self.classes.has(c) : on) self.classes.add(c); else self.classes.delete(c); } }; }
  set className(v) { this.classes = new Set(String(v).split(/\s+/).filter(Boolean)); }
  get className() { return Array.from(this.classes).join(" "); }
  set textContent(v) { this._text = String(v); this.children = []; }
  get textContent() { return this._text + this.children.map(function (c) { return c.textContent; }).join(""); }
  appendChild(c) { if (c.tagName === "#frag") { for (const k of c.children) this.children.push(k); c.children = []; } else this.children.push(c); return c; }
  replaceChildren() { this.children = []; for (const c of arguments) this.appendChild(c); }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  getAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attrs, k) ? this.attrs[k] : null; }
  hasAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attrs, k); }
  addEventListener() {}
  querySelector() { return null; }
  all(pred) { let out = []; for (const c of this.children) { if (pred(c)) out.push(c); out = out.concat(c.all(pred)); } return out; }
}
const ids = {};
const document = { createElement(t) { return new N(t); }, createDocumentFragment() { return new N("#frag"); }, createTextNode(t) { const n = new N("#text"); n._text = String(t); return n; },
  getElementById(id) { return ids[id] || (ids[id] = new N("div")); }, querySelector() { return null; }, addEventListener() {}, contains() { return true; }, activeElement: null, body: {} };
const ctx = { location: { pathname: "/", search: "", href: "http://x/" }, history: { replaceState() {}, pushState() {} }, document, console, setTimeout() { return 0; }, clearTimeout() {}, fetch() { return Promise.reject(new Error("no fetch")); } };
vm.createContext(ctx);
vm.runInContext(fs.readFileSync(process.argv[2], "utf8"), ctx, { filename: process.argv[2] });
let fail = 0;
function test(name, fn) { try { fn(); console.log("ok - " + name); } catch (e) { fail++; console.log("FAIL - " + name + ": " + e.message); } }
function eq(a, b, w) { if (a !== b) throw new Error(w + ": expected " + JSON.stringify(b) + ", got " + JSON.stringify(a)); }
function board(reviewer, escalation) {
  return { repo: "r", cards: [], escalation: escalation, states: [{ key: "ready", name: "Ready" }, { key: "in_review", name: "In review", reviewer: reviewer }] };
}
function header(key) {
  const col = ids.board.all(function (n) { return n.dataset && n.dataset.state === key; })[0];
  return col.all(function (n) { return n.classes.has("col-head"); })[0];
}
function line(h) { return h.all(function (n) { return n.classes.has("col-reviewer"); })[0]; }
setTimeout = undefined;
setImmediate(function () {
  vm.runInContext("S.offline = false", ctx);
  test("header shows codex · gpt-6-astra for an in_review reviewer", function () {
    ctx.renderBoard(board({ provider: "codex", model: "gpt-6-astra" }, null), true);
    eq(header("in_review").textContent.indexOf("codex · gpt-6-astra") >= 0, true, "header text has reviewer");
  });
  test("a state with no reviewer has no reviewer line in its header", function () {
    ctx.renderBoard(board({ provider: "codex", model: "gpt-6-astra" }, null), true);
    eq(line(header("ready")), undefined, "ready reviewer line");
    ctx.renderBoard(board(undefined, null), true);
    eq(line(header("in_review")), undefined, "in_review reviewer line");
  });
  test("escalation {model: opus, after_rounds: 2} titles the reviewer line", function () {
    ctx.renderBoard(board({ provider: "codex", model: "gpt-6-astra" }, { model: "opus", after_rounds: 2 }), true);
    eq(line(header("in_review")).getAttribute("title"), "From round 2, implementor and fixer use opus", "title");
  });
  test("escalation null leaves the reviewer line with no title attribute", function () {
    ctx.renderBoard(board({ provider: "codex", model: "gpt-6-astra" }, null), true);
    eq(line(header("in_review")).hasAttribute("title"), false, "title attribute");
  });
  test("same state keys with a different reviewer model changes the header text", function () {
    ctx.renderBoard(board({ provider: "codex", model: "gpt-6-astra" }, null), true);
    ctx.renderBoard(board({ provider: "codex", model: "gpt-7" }, null));
    eq(header("in_review").textContent.indexOf("gpt-7") >= 0, true, "new model in header");
    eq(header("in_review").textContent.indexOf("gpt-6-astra") >= 0, false, "old model gone");
  });
  process.exit(fail ? 1 : 0);
});
NODE
node "$HDR_JS" "$JS" || FAIL=$((FAIL + 1))
rm -f "$HDR_JS"

# Drawer: stacked on #<parent>, and the attention text.
STK_JS="$(mktemp)"
cat >"$STK_JS" <<'NODE'
"use strict";
const assert = require("node:assert/strict");
const path = require("node:path");
const loadBoard = require(path.join(process.env.DIR, "board-interaction-harness.js"));
const JS = path.join(process.env.DIR, "../scripts/board-web/static/board.js");
const states = [{key: "backlog", name: "Backlog"}, {key: "ready", name: "Ready"}];
const mk = (number, extra) => ({number, title: "Card " + number, body: "", labels: [], comments: [],
  acceptance: [], blocked_by: [], blocks: [], state: "ready", known: true, ...extra});
const allText = n => (n.textContent || "") + (n.children || []).map(allText).join("");
let fails = 0;
async function test(name, fn) { try { await fn(); console.log("ok - " + name); } catch (e) { fails++; console.log("FAIL - " + name + ": " + e.message); } }
async function drawerText(card) {
  const h = loadBoard(JS, async (url) => {
    let data = {}, m;
    if (url === "/api/board") data = {repo: "acme/toy", states, cards: [{...card}], run: {state: "idle"}};
    else if ((m = /^\/api\/cards\/(\d+)$/.exec(url))) data = {...card};
    return {ok: true, status: 200, json: async () => data};
  });
  await h.flush();
  await h.ctx.openDrawer(card.number);
  await h.flush();
  const el = h.$("dr-stack");
  // the harness's getElementById nodes are detached, so read the field's parts by id
  return el && !el.hidden ? ["Stacked on", h.$("dr-stack-link"), h.$("dr-stack-attn")].map(n => typeof n === "string" ? n : (n.hidden ? "" : allText(n))).join(" ") : "";
}
(async () => {
  await test("In the drawer, the stacked line is a labelled Stacked on field with the parent as a link", async () => {
    const t = await drawerText(mk(1, {stacked_on: 11, stack_attention: null}));
    assert.ok(t.includes("Stacked on"), t);
    assert.ok(t.includes("#11"), t);
  });
  await test("the drawer Stacked on link opens the parent's drawer", async () => {
    const urls = [];
    const card = mk(1, {stacked_on: 11, stack_attention: null});
    const h = loadBoard(JS, async (url) => {
      urls.push(url);
      let data = {}, m;
      if (url === "/api/board") data = {repo: "acme/toy", states, cards: [{...card}, mk(11, {})], run: {state: "idle"}};
      else if ((m = /^\/api\/cards\/(\d+)$/.exec(url))) data = m[1] === "11" ? mk(11, {}) : {...card};
      return {ok: true, status: 200, json: async () => data};
    });
    await h.flush();
    await h.ctx.openDrawer(1);
    await h.flush();
    const link = h.$("dr-stack-link");
    assert.equal(link.textContent.trim(), "#11");
    const before = urls.filter(u => u === "/api/cards/11").length;
    for (const fn of link.listeners.click || []) fn({preventDefault() {}, stopPropagation() {}, currentTarget: link, target: link});
    await h.flush();
    assert.ok(urls.filter(u => u === "/api/cards/11").length > before, urls.join(","));
  });
  await test("the drawer shows nothing for stacked_on null", async () => {
    const t = await drawerText(mk(1, {stacked_on: null, stack_attention: null}));
    assert.equal(t, "");
  });
  await test("the drawer shows the attention text when stack_attention is set", async () => {
    const t = await drawerText(mk(1, {stacked_on: 11, stack_attention: "parent closed unmerged"}));
    assert.ok(t.includes("parent closed unmerged"), t);
  });
  const tile = (extra) => {
    const h = loadBoard(JS, async () => ({ok: true, status: 200, json: async () => ({})}));
    return h.ctx.renderCard(mk(2, {blocked: true, blocked_by: [11], open_blockers: [11], ...extra}), "acme/toy");
  };
  const lines = li => li.all().filter(n => n.classList.contains("card-meta"));
  await test("A card tile for a card with stacked_on set shows a stacked on #N line, same class as blocked by, not the amber one", async () => {
    const li = tile({stacked_on: 11, stack_attention: null});
    const l = lines(li).filter(n => n.textContent.trim() === "stacked on #11");
    assert.equal(l.length, 1, lines(li).map(n => n.textContent).join("|"));
    assert.ok(l[0].classList.contains("stacked-on"));
    assert.ok(!l[0].classList.contains("blocked-by"));
  });
  await test("A stacked card's tile also has a left-edge marker class, stacked", async () => {
    assert.ok(tile({stacked_on: 11}).classList.contains("stacked"));
  });
  await test("When stack_attention is set, the tile shows landing needs attention: <reason> in the amber attention style", async () => {
    const li = tile({stacked_on: 11, stack_attention: "parent closed unmerged"});
    const l = lines(li).filter(n => n.textContent.trim() === "landing needs attention: parent closed unmerged");
    assert.equal(l.length, 1, lines(li).map(n => n.textContent).join("|"));
    assert.ok(l[0].classList.contains("stack-attention"));
  });
  await test("A card with stacked_on null shows none of this on its tile", async () => {
    const li = tile({stacked_on: null, stack_attention: null});
    assert.ok(!li.classList.contains("stacked"));
    assert.ok(!lines(li).some(n => /stacked on|landing needs/.test(n.textContent)));
  });
  await test("The tile's blocked by line is not shown when the only open blocker is the stack parent", async () => {
    const li = tile({stacked_on: 11});
    assert.ok(!lines(li).some(n => n.classList.contains("blocked-by")));
    assert.ok(!li.classList.contains("blocked"));
  });
  await test("The tile's blocked by line is still shown for any other open blocker", async () => {
    const li = tile({stacked_on: 11, blocked_by: [11, 12], open_blockers: [11, 12]});
    const l = lines(li).filter(n => n.classList.contains("blocked-by"));
    assert.equal(l.length, 1);
    assert.equal(l[0].textContent.trim(), "blocked by #12");
  });
  process.exit(fails ? 1 : 0);
})();
NODE
DIR="$DIR" node "$STK_JS" || FAIL=$((FAIL + 1))
rm -f "$STK_JS"

echo "$FAIL failing groups"
[ "$FAIL" -eq 0 ]
