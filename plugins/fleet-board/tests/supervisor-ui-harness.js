"use strict";
const loadBoard = require("./board-interaction-harness");

// Add capabilities locally without changing the shared interaction harness.
module.exports = function loadSupervisorBoard(jsPath, fetch, options = {}) {
  const clock = {now: options.now || Date.parse("2026-11-10T18:00:00Z")};
  const h = loadBoard(jsPath, fetch);
  const document = h.document;
  document.listeners = {};
  const add = document.addEventListener;
  document.addEventListener = function (name, fn) { (document.listeners[name] ||= []).push(fn); add.call(document, name, fn); };
  const clockNow = clock.now;
  class FakeDate extends Date { constructor(...args) { super(...(args.length ? args : [clock.now])); } static now() { return clock.now; } }
  h.ctx.Date = FakeDate;
  h.ctx.__advanceClock = milliseconds => { clock.now += milliseconds; };
  // The shared harness fabricates a DIV for every id and never parses index.html. Teach this
  // wrapper the real tag of each id declared in the page, and make focus() observable.
  const fs = require("fs");
  const path = require("path");
  const html = fs.readFileSync(path.join(path.dirname(jsPath), "index.html"), "utf8");
  const tags = {};
  for (const m of html.matchAll(/<([a-zA-Z0-9]+)\b[^>]*?\sid="([^"]+)"/g)) tags[m[2]] = m[1].toUpperCase();
  const originalGet = document.getElementById;
  document.getElementById = function (id) {
    const node = originalGet.call(document, id);
    if (node && !node.__supervisorPatched) {
      node.__supervisorPatched = true;
      if (tags[id] && node.tagName === "DIV") node.tagName = tags[id];
      if (!Object.prototype.hasOwnProperty.call(node, "focus") || node.focus.__fake !== true) {
        const focus = function () { document.activeElement = node; };
        focus.__fake = true;
        node.focus = focus;
      }
    }
    return node;
  };
  h.$ = id => document.getElementById(id);
  h.pageHtml = html;
  const timers = h.timers;
  h.clock = clock;
  h.fireTimers = async function () {
    const pending = timers.splice(0);
    for (const callback of pending) await callback();
    await h.flush();
  };
  h.setHidden = async function (hidden) {
    h.document.hidden = Boolean(hidden);
    const listeners = h.document.listeners && h.document.listeners.visibilitychange || [];
    for (const listener of listeners) await listener({type: "visibilitychange"});
    await h.flush();
  };
  h.waitForRequests = async function () { await h.flush(); await h.flush(); };
  h.key = async function (node, key) {
    const event = {target: node, key, preventDefault() { this.defaultPrevented = true; }, stopPropagation() {}};
    for (const listener of node.listeners.keydown || []) await listener(event);
    await h.flush();
    return event;
  };
  return h;
};
