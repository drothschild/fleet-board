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
