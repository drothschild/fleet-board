// Minimal fake DOM that loads static/board.js and renders a /api/board reply.
// Usage: node board-dom-harness.js <board.js> <board.json> <drawer-state>
// Prints JSON: {groups: [{heading, cards: [text]}], options: [{value, text}], selected}
"use strict";
const fs = require("fs");
const vm = require("vm");

class Node_ {
  constructor(tag) {
    this.tagName = String(tag).toUpperCase();
    this.children = [];
    this.parent = null;
    this.own = "";
    this.className = "";
    this.dataset = {};
    this.attrs = {};
    this.style = {};
    this.hidden = false;
    this.value = "";
    this.id = "";
    this.scrollTop = 0;
    const self = this;
    this.classList = {
      add: function (c) { const s = new Set(self.className.split(/\s+/).filter(Boolean)); s.add(c); self.className = [...s].join(" "); },
      remove: function (c) { self.className = self.className.split(/\s+/).filter(function (x) { return x && x !== c; }).join(" "); },
      toggle: function (c, on) { if (on) this.add(c); else this.remove(c); },
      contains: function (c) { return self.className.split(/\s+/).includes(c); },
    };
  }
  get textContent() { return this.own + this.children.map(function (c) { return c.textContent; }).join(" "); }
  set textContent(t) { this.children = []; this.own = String(t); }
  get firstChild() { return this.children[0] || null; }
  appendChild(c) {
    if (c.isFragment) { for (const k of c.children.slice()) this.appendChild(k); return c; }
    c.parent = this; this.children.push(c); return c;
  }
  replaceChildren(...cs) { this.children = []; this.own = ""; for (const c of cs) this.appendChild(c); }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  addEventListener() {}
  focus() {}
  contains(o) { for (let n = o; n; n = n.parent) if (n === this) return true; return false; }
  closest() { return null; }
  all() { let out = []; for (const c of this.children) { out.push(c); out = out.concat(c.all()); } return out; }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
  querySelectorAll(sel) {
    const cls = sel.startsWith(".") ? sel.slice(1) : null;
    return this.all().filter(function (n) { return cls ? n.classList.contains(cls) : false; });
  }
}

const byId = {};
const document = {
  title: "",
  activeElement: null,
  body: new Node_("body"),
  createElement: function (t) { return new Node_(t); },
  createElementNS: function (ns, t) { return new Node_(t); },
  createTextNode: function (t) { const n = new Node_("#text"); n.own = String(t); return n; },
  createDocumentFragment: function () { const n = new Node_("#frag"); n.isFragment = true; return n; },
  getElementById: function (id) { return byId[id] || (byId[id] = Object.assign(new Node_("div"), { id: id })); },
  addEventListener: function () {},
  contains: function () { return false; },
  querySelector: function () { return null; },
};

const ctx = { document: document, window: {}, location: { pathname: "/" }, history: { replaceState: function () {} },
  setTimeout: function () { return 0; }, clearTimeout: function () {}, fetch: function () { return new Promise(function () {}); },
  console: console };
ctx.window = ctx;
vm.createContext(ctx);
const [, , jsPath, boardPath, drawerState] = process.argv;
vm.runInContext(fs.readFileSync(jsPath, "utf8") + "\nthis.__t = { S: S, renderBoard: renderBoard, fillStateSelect: fillStateSelect };", ctx);
const t = ctx.__t;
const board = JSON.parse(fs.readFileSync(boardPath, "utf8"));
t.S.board = board;
t.renderBoard(board, true);
const groups = document.getElementById("board").all()
  .filter(function (n) { return n.tagName === "SECTION"; })
  .map(function (sec) {
    const head = sec.all().find(function (n) { return /^H\d$/.test(n.tagName) || n.classList.contains("col-toggle"); });
    return { heading: head ? head.textContent : "",
      cards: sec.all().filter(function (n) { return n.classList.contains("card"); }).map(function (c) { return c.textContent; }) };
  });
t.fillStateSelect(drawerState);
const sel = document.getElementById("dr-state");
console.log(JSON.stringify({ groups: groups,
  options: sel.children.map(function (o) { return { value: o.value, text: o.textContent }; }), selected: sel.value }));
