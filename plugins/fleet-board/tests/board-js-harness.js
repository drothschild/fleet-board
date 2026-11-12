// Loads board.js into a vm context with a tiny DOM shim and runs checks.
// Usage: node board-js-harness.js <path to board.js>
"use strict";
const fs = require("fs");
const vm = require("vm");

const file = process.argv[2];
const src = fs.readFileSync(file, "utf8");

class Node_ {
  constructor(tag) {
    this.tagName = tag;
    this.children = [];
    this.dataset = {};
    this.attrs = {};
    this.classes = new Set();
    this._text = "";
    const self = this;
    this.classList = {
      add(c) { self.classes.add(c); },
      remove(c) { self.classes.delete(c); },
      contains(c) { return self.classes.has(c); },
      toggle(c, on) { if (on === undefined ? !self.classes.has(c) : on) self.classes.add(c); else self.classes.delete(c); },
    };
  }
  set className(v) { this.classes = new Set(String(v).split(/\s+/).filter(Boolean)); }
  get className() { return Array.from(this.classes).join(" "); }
  set textContent(v) { this._text = String(v); this.children = []; }
  get textContent() { return this._text + this.children.map(function (c) { return c.textContent; }).join(""); }
  appendChild(c) {
    if (c.tagName === "#frag") { for (const k of c.children) this.children.push(k); c.children = []; }
    else this.children.push(c);
    return c;
  }
  setAttribute(k, v) { this.attrs[k] = v; }
  addEventListener() {}
  find(tag) {
    let out = [];
    for (const c of this.children) {
      if (c.tagName === tag) out.push(c);
      if (c.find) out = out.concat(c.find(tag));
    }
    return out;
  }
}
class Text_ extends Node_ {
  constructor(t) { super("#text"); this._text = String(t); }
}

const ids = {};
const live = {}; // card number -> li currently on screen
const document = {
  createElement(tag) { return new Node_(tag); },
  createDocumentFragment() { return new Node_("#frag"); },
  createTextNode(t) { return new Text_(t); },
  getElementById(id) { return ids[id] || (ids[id] = new Node_("div")); },
  querySelector(sel) {
    const m = /data-n="(\d+)"/.exec(sel);
    return m ? live[m[1]] || null : null;
  },
  addEventListener() {},
  contains() { return true; },
  activeElement: null,
  body: {},
};

const ctx = { location: { pathname: "/", search: "", href: "http://x/" }, history: { replaceState() {}, pushState() {} }, document, console, setTimeout() { return 0; }, clearTimeout() {}, fetch() { return Promise.reject(new Error("no fetch")); } };
vm.createContext(ctx);
vm.runInContext(src, ctx, { filename: file });
const run = function (code) { return vm.runInContext(code, ctx); };

let pass = 0;
let fail = 0;
async function test(name, fn) {
  try {
    await fn();
    pass++;
    console.log("ok - " + name);
  } catch (e) {
    fail++;
    console.log("not ok - " + name + ": " + e.message);
  }
}
function eq(a, b, what) {
  if (a !== b) throw new Error((what || "value") + ": expected " + JSON.stringify(b) + ", got " + JSON.stringify(a));
}

(async function () {
  await new Promise(function (r) { setImmediate(r); }); // let init's failed fetch settle
  run("S.offline = false; S.board = null; S.run = null");
  await test("md: an unclosed comment renders the text before it", function () {
    const f = ctx.md("a <!-- b");
    eq(f.textContent.trim(), "a");
  });
  await test("md: a comment inside a code fence stays in the code block", function () {
    const f = ctx.md("```\n<!-- x -->\n```");
    const code = f.find("code");
    eq(code.length, 1, "code blocks");
    eq(code[0].textContent, "<!-- x -->");
  });
  await test("md: a complete comment is dropped outside code", function () {
    eq(ctx.md("a <!-- b --> c").textContent.replace(/\s+/g, " ").trim(), "a c");
  });
  await test("md: a link url containing a closing paren is one link", function () {
    const f = ctx.md("[t](https://x.test/a_(b))");
    const a = f.find("a");
    eq(a.length, 1, "links");
    eq(a[0].href, "https://x.test/a_(b)");
  });
  await test("md: underscore emphasis still works without lookbehind", function () {
    eq(ctx.md("x _y_ z").find("em").length, 1, "em");
    eq(ctx.md("snake_case_word").find("em").length, 0, "em in word");
  });
  await test("run: only the second stop reason shows after a new run", function () {
    ctx.renderHeader({ state: "stopped", stop_reason: "stop-file", hours: 2 });
    ctx.renderHeader({ state: "running", tick: 1 });
    ctx.renderHeader({ state: "stopped", stop_reason: "nothing-dispatchable" });
    eq(ids["run-pill-text"].textContent, "stopped: nothing-dispatchable");
    eq(ids["run-hours"].textContent, "", "stale hours");
  });
  await test("move: a re-rendered poll leaves no pending class", async function () {
    // a screen that rebuilds cards only on a forced render, as the columns do
    run("S.board = {states: [], cards: [{number: 7, state: 'a'}]}");
    run("renderBoard = function (b, force) { if (force) for (const c of b.cards) globalThis.__live[c.number] = renderCard(c, 'r'); }");
    ctx.__live = live;
    const gates = [];
    let postGate = null;
    ctx.fetch = function (path, opts) {
      if (opts.method === "POST") return new Promise(function (res) { postGate = function () { res({ ok: true, status: 200, json: async function () { return {}; } }); }; });
      return new Promise(function (res) {
        gates.push(function () { res({ ok: true, status: 200, json: async function () { return { cards: [{ number: 7, state: "b" }], states: [], run: null }; } }); });
      });
    };
    run("renderHeader = function () {}; syncDrawer = function () {}; setOffline = function () {};");
    const moving = ctx.moveCard(7, "b");
    await new Promise(function (r) { setImmediate(r); });
    eq(live[7].classList.contains("pending"), true, "pending while in flight");
    postGate();
    await new Promise(function (r) { setImmediate(r); });
    const poll = ctx.fetchBoard(); // a poll supersedes the forced refresh
    await new Promise(function (r) { setImmediate(r); });
    gates.forEach(function (g) { g(); });
    await moving;
    await poll;
    eq(live[7].classList.contains("pending"), false, "pending class");
  });
  await test("move: a failed network call snaps the card back", async function () {
    run("S.board = {states: [], cards: [{number: 9, state: 'a'}]}");
    ctx.fetch = function () { return Promise.reject(new Error("down")); };
    await ctx.moveCard(9, "b");
    eq(run("S.board.cards[0].state"), "a", "card state");
  });
  await test("drop: dropping a card on its own column keeps the held poll", function () {
    run("S.board = {states: [], cards: [{number: 5, state: 'a'}]}");
    const handlers = {};
    const col = { addEventListener(n, f) { handlers[n] = f; }, contains() { return false; }, classList: { add() {}, remove() {} } };
    ctx.bindDrop(col, "a");
    run("S.dragging = 5; S.pendingBoard = {held: true}; renderBoard = function (b) { globalThis.__rendered = b; };");
    handlers.drop({ preventDefault() {} });
    eq(!!ctx.__rendered && ctx.__rendered.held, true, "held poll rendered");
  });
  console.log(pass + " passed, " + fail + " failed");
  process.exit(fail ? 1 : 0);
})();
