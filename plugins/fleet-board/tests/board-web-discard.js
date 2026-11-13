// Drives the real board.js Discard click / Escape handlers in a stubbed DOM
// against a live server. Usage: node board-web-discard.js <board.js> <base-url> <import-id> <click|escape>
// Prints "closed" once the import view is gone (S.imp is null) and exits 0.
"use strict";
const fs = require("fs");
const vm = require("vm");
const [, , boardJs, base, id, mode] = process.argv;

const handlers = {};      // "<element id>:<event>" -> listener
const docHandlers = {};   // event -> listener
function el(name) {
  const target = { name: name, dataset: {}, style: {}, classList: { add() {}, remove() {}, toggle() {}, contains() { return false; } },
    addEventListener(ev, fn) { handlers[name + ":" + ev] = fn; },
    contains() { return false; }, setAttribute() {}, focus() {}, remove() {}, appendChild() {}, hidden: false, textContent: "", value: "" };
  return new Proxy(target, { get(t, k) { return k in t ? t[k] : function () {}; }, set(t, k, v) { t[k] = v; return true; } });
}
const els = {};
const document = {
  getElementById(n) { return els[n] || (els[n] = el(n)); },
  addEventListener(ev, fn) { docHandlers[ev] = fn; },
  activeElement: null, body: {}, hidden: false,
  querySelector() { return el("q"); }, querySelectorAll() { return []; }, createElement() { return el("c"); },
};
const ctx = {
  document, console, setTimeout, clearTimeout, setInterval() { return 0; }, clearInterval() {},
  fetch: (p, o) => fetch(base + p, o), location: { pathname: "/", search: "" }, history: { replaceState() {} },
  URL, URLSearchParams, JSON, Promise, Date, Math, encodeURIComponent,
  window: {}, requestAnimationFrame() { return 0; }, matchMedia() { return { matches: false, addEventListener() {} }; },
};
ctx.window = ctx;
vm.createContext(ctx);
const src = fs.readFileSync(boardJs, "utf8").replace(/\ninit\(\);\s*$/, "\n");
vm.runInContext(src, ctx);
vm.runInContext("bindImport(); S.imp = { phase: 'running', id: " + JSON.stringify(id) + ", timer: null };", ctx);
if (mode === "click") handlers["imp-discard:click"]();
else docHandlers.keydown({ key: "Escape", preventDefault() {}, defaultPrevented: false });
const t0 = Date.now();
(function wait() {
  if (vm.runInContext("S.imp === null", ctx)) { console.log("closed"); process.exit(0); }
  if (Date.now() - t0 > 8000) { console.log("still open"); process.exit(1); }
  setTimeout(wait, 50);
})();
