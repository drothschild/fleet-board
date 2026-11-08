"use strict";
const fs = require("fs");
const vm = require("vm");
async function flush() { for (let i = 0; i < 12; i++) await new Promise(setImmediate); }
module.exports = function loadBoard(jsPath, fetch) {
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
    this.listeners = {};
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
  addEventListener(name, fn) { (this.listeners[name] ||= []).push(fn); }
  async fire(name, extra = {}) {
    if (this.disabled) throw new Error("event on disabled element: " + this.id);
    const event = {target: this, preventDefault() {}, ...extra};
    for (const fn of this.listeners[name] || []) await fn(event);
    await flush();
  }
  getAttribute(k) { return this.attrs[k]; }
  removeAttribute(k) { delete this.attrs[k]; }
  focus() {}
  contains(o) { for (let n = o; n; n = n.parent) if (n === this) return true; return false; }
  closest(sel) { for (let n = this; n; n = n.parent) if (sel.startsWith(".") ? n.classList.contains(sel.slice(1)) : n.tagName === sel.toUpperCase()) return n; return null; }
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

const timers = [];
const ctx = {document, location: {pathname: "/"}, history: {replaceState() {}},
  setTimeout(fn) { timers.push(fn); return timers.length; }, clearTimeout() {}, fetch, console,
  confirm() { return true; }};
ctx.window = ctx;
vm.createContext(ctx);
vm.runInContext(fs.readFileSync(jsPath, "utf8") + "\nthis.__test = {S, pollImport};", ctx);
return {document, ctx, timers, flush, $: id => document.getElementById(id)};
};
