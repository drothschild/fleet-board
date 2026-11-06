// fleet-board local board page. Plain functions, no framework, no build step.
// Card text only ever reaches the page through textContent / createTextNode.
"use strict";

const BOARD_POLL_MS = 3000;
const RUN_FAST_MS = 3000;   // while a run is running or stopping
const RUN_SLOW_MS = 15000;  // otherwise
const TOAST_MS = 8000;
const COLLAPSIBLE = { done: true, wont_do: true };
const SVG_NS = "http://www.w3.org/2000/svg";

const S = {
  board: null,        // the last /api/board reply
  run: null,          // the last run dict (log_tail kept from /api/run)
  stateKeys: "",      // the column list the board was built for
  cols: {},           // state key -> {el, list, count, sig}
  open: {},           // collapsible state key -> expanded
  dragging: null,     // number of the card being dragged
  pendingBoard: null, // a board that arrived mid-drag, rendered on dragend
  pendingMove: null,  // number of the card whose move is in flight
  logOpen: false,
  busy: false,        // a start/stop request is in flight
  offline: false,
  boardSeq: 0,
  runSeq: 0,
  runFast: false,
  boardTimer: null,
  runTimer: null,
  toastTimer: null,
};

// --- small helpers -----------------------------------------------------------

function el(tag, cls, text) {
  const node = document.createElement(tag);
  if (cls) node.className = cls;
  if (text !== undefined && text !== null) node.textContent = String(text);
  return node;
}

function $(id) {
  return document.getElementById(id);
}

async function api(method, path, body) {
  const opts = { method: method, headers: {} };
  if (method !== "GET") opts.headers["X-Fleet-Board"] = "1";
  if (body !== undefined) {
    opts.headers["Content-Type"] = "application/json";
    opts.body = JSON.stringify(body);
  }
  const res = await fetch(path, opts);
  let data = {};
  try {
    data = await res.json();
  } catch (e) {
    data = {};
  }
  return { ok: res.ok, status: res.status, data: data || {} };
}

function errorText(r) {
  return (r.data && r.data.error) || "the server answered HTTP " + r.status;
}

function isAlive(run) {
  return !!run && (run.state === "running" || run.state === "stopping");
}

function stateName(key) {
  const states = (S.board && S.board.states) || [];
  for (const s of states) if (s.key === key) return s.name;
  return key;
}

function chevron() {
  const svg = document.createElementNS(SVG_NS, "svg");
  svg.setAttribute("viewBox", "0 0 12 12");
  svg.setAttribute("class", "chevron");
  svg.setAttribute("aria-hidden", "true");
  const path = document.createElementNS(SVG_NS, "path");
  path.setAttribute("d", "M4.5 2.5 8 6l-3.5 3.5");
  path.setAttribute("fill", "none");
  path.setAttribute("stroke", "currentColor");
  path.setAttribute("stroke-width", "1.5");
  path.setAttribute("stroke-linecap", "round");
  path.setAttribute("stroke-linejoin", "round");
  svg.appendChild(path);
  return svg;
}

function formatModels(models) {
  if (!models || typeof models !== "object") return null;
  const roles = ["implementor", "reviewer", "fixer"].filter(function (r) {
    return typeof models[r] === "string" && models[r] !== "";
  });
  if (!roles.length) return null;
  const values = roles.map(function (r) { return models[r]; });
  const same = values.every(function (v) { return v === values[0]; });
  return {
    text: same ? values[0] : values.join(" / "),
    title: roles.map(function (r) { return r + ": " + models[r]; }).join(", "),
  };
}

function formatHours(h) {
  return (h < 1 ? h.toFixed(2) : h.toFixed(1)) + " h";
}

// --- markdown ----------------------------------------------------------------

// md(text) -> DocumentFragment. Headings, paragraphs, bullet and numbered
// lists, fenced code, inline code, emphasis and links; HTML comments dropped;
// any other HTML stays literal text.
function md(text) {
  const frag = document.createDocumentFragment();
  const lines = String(text == null ? "" : text)
    .replace(/<!--[\s\S]*?(-->|$)/g, "")
    .replace(/\r\n?/g, "\n")
    .split("\n");
  let para = [];
  let i = 0;

  function flush() {
    if (!para.length) return;
    const p = el("p");
    mdInline(para.join(" "), p);
    frag.appendChild(p);
    para = [];
  }

  while (i < lines.length) {
    const line = lines[i];
    let m;
    if ((m = /^\s*(`{3,}|~{3,})\s*([\w+.-]*)\s*$/.exec(line))) {
      flush();
      const fence = m[1];
      const body = [];
      i++;
      while (i < lines.length) {
        const t = lines[i].trim();
        if (t.indexOf(fence) === 0 && /^(`+|~+)$/.test(t)) break;
        body.push(lines[i]);
        i++;
      }
      i++;
      const pre = el("pre");
      const code = el("code", null, body.join("\n"));
      if (m[2]) code.dataset.lang = m[2];
      pre.appendChild(code);
      frag.appendChild(pre);
      continue;
    }
    if ((m = /^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$/.exec(line))) {
      flush();
      const h = el("h" + m[1].length);
      mdInline(m[2], h);
      frag.appendChild(h);
      i++;
      continue;
    }
    if (/^\s*([-*+]|\d+[.)])\s+/.test(line)) {
      flush();
      const ordered = /^\s*\d+[.)]\s+/.test(line);
      const item = ordered ? /^\s*(\d+)[.)]\s+(.*)$/ : /^\s*()[-*+]\s+(.*)$/;
      const list = el(ordered ? "ol" : "ul");
      const items = [];
      while (i < lines.length) {
        const lm = item.exec(lines[i]);
        if (lm) {
          if (ordered && !items.length && lm[1] !== "1") list.setAttribute("start", lm[1]);
          items.push([lm[2]]);
        } else if (items.length && /^\s{2,}\S/.test(lines[i]) && !/^\s*([-*+]|\d+[.)])\s+/.test(lines[i])) {
          items[items.length - 1].push(lines[i].trim());
        } else {
          break;
        }
        i++;
      }
      for (const parts of items) {
        const li = el("li");
        mdInline(parts.join(" "), li);
        list.appendChild(li);
      }
      frag.appendChild(list);
      continue;
    }
    if (/^\s*$/.test(line)) {
      flush();
      i++;
      continue;
    }
    if (/^\s{0,3}([-*_])(\s*\1){2,}\s*$/.test(line)) {
      flush();
      frag.appendChild(el("hr"));
      i++;
      continue;
    }
    para.push(line.trim());
    i++;
  }
  flush();
  return frag;
}

const MD_INLINE = /`([^`]+)`|\[([^\]]+)\]\(([^)\s]+)\)|\*\*(.+?)\*\*|__(.+?)__|\*(?!\s)(.+?)\*|(?<!\w)_(?!\s)(.+?)_(?!\w)/;

// mdInline(text, parent): appends text's inline markdown to parent.
function mdInline(text, parent) {
  let rest = text;
  while (rest) {
    const m = MD_INLINE.exec(rest);
    if (!m) {
      parent.appendChild(document.createTextNode(rest));
      break;
    }
    if (m.index) parent.appendChild(document.createTextNode(rest.slice(0, m.index)));
    if (m[1] !== undefined) {
      parent.appendChild(el("code", null, m[1]));
    } else if (m[2] !== undefined) {
      const url = m[3];
      let link;
      if (/^https?:\/\//i.test(url) || url.charAt(0) === "#") {
        link = el("a");
        link.href = url;
        if (url.charAt(0) !== "#") {
          link.target = "_blank";
          link.rel = "noopener noreferrer";
        }
      } else {
        link = el("span");
      }
      mdInline(m[2], link);
      parent.appendChild(link);
    } else if (m[4] !== undefined || m[5] !== undefined) {
      const strong = el("strong");
      mdInline(m[4] !== undefined ? m[4] : m[5], strong);
      parent.appendChild(strong);
    } else {
      const em = el("em");
      mdInline(m[6] !== undefined ? m[6] : m[7], em);
      parent.appendChild(em);
    }
    rest = rest.slice(m.index + m[0].length);
  }
}

// --- board -------------------------------------------------------------------

async function fetchBoard(force) {
  clearTimeout(S.boardTimer);
  const my = ++S.boardSeq;
  try {
    const r = await api("GET", "/api/board");
    if (my !== S.boardSeq) return;
    if (!r.ok) throw new Error(errorText(r));
    setOffline(false);
    S.board = r.data;
    renderBoard(r.data, force);
    renderHeader(r.data.run);
    if (isAlive(r.data.run) && !S.runFast) pollRun();
  } catch (e) {
    if (my !== S.boardSeq) return;
    setOffline(true, e.message);
  }
  S.boardTimer = setTimeout(fetchBoard, BOARD_POLL_MS);
}

// renderBoard(board, force): builds the columns when the state list changes,
// then re-renders only the columns whose cards changed (all with force).
function renderBoard(board, force) {
  if (S.dragging !== null) {
    S.pendingBoard = board;
    return;
  }
  const repo = board.repo || "fleet-board";
  $("repo").textContent = repo;
  document.title = repo + " board";

  const keys = board.states.map(function (s) { return s.key; }).join(" ");
  if (keys !== S.stateKeys) {
    buildColumns(board.states);
    S.stateKeys = keys;
    force = true;
  }

  const byState = {};
  for (const s of board.states) byState[s.key] = [];
  for (const c of board.cards) if (byState[c.state]) byState[c.state].push(c);

  const focus = focusedCard();
  for (const s of board.states) {
    const cards = byState[s.key].sort(function (a, b) { return a.number - b.number; });
    renderColumn(s, cards, board.repo, force);
  }
  restoreFocus(focus);
}

function buildColumns(states) {
  const root = $("board");
  root.replaceChildren();
  S.cols = {};
  let stack = null;
  for (const s of states) {
    const collapsible = !!COLLAPSIBLE[s.key];
    const col = el("section", "col");
    col.dataset.state = s.key;
    col.setAttribute("aria-label", s.name);
    const list = el("ol", "cards");
    list.id = "cards-" + s.key;
    const count = el("span", "col-count", "0");

    if (collapsible) {
      const open = !!S.open[s.key];
      const toggle = el("button", "col-toggle");
      toggle.type = "button";
      toggle.setAttribute("aria-expanded", String(open));
      toggle.setAttribute("aria-controls", list.id);
      toggle.appendChild(el("span", null, s.name));
      toggle.appendChild(count);
      toggle.appendChild(chevron());
      toggle.addEventListener("click", function () { toggleColumn(s.key); });
      col.appendChild(toggle);
      list.hidden = !open;
      col.classList.toggle("open", open);
    } else {
      const head = el("h2", "col-head");
      head.appendChild(el("span", null, s.name));
      head.appendChild(count);
      col.appendChild(head);
    }
    col.appendChild(list);
    bindDrop(col, s.key);

    if (collapsible) {
      if (!stack) {
        stack = el("div", "stack");
        root.appendChild(stack);
      }
      stack.appendChild(col);
    } else {
      stack = null;
      root.appendChild(col);
    }
    S.cols[s.key] = { el: col, list: list, count: count, toggle: col.querySelector(".col-toggle"), sig: null };
  }
}

function toggleColumn(key) {
  const col = S.cols[key];
  const open = !S.open[key];
  S.open[key] = open;
  col.toggle.setAttribute("aria-expanded", String(open));
  col.list.hidden = !open;
  col.el.classList.toggle("open", open);
}

function renderColumn(state, cards, repo, force) {
  const col = S.cols[state.key];
  col.count.textContent = String(cards.length);
  const sig = JSON.stringify([repo, cards]);
  if (!force && sig === col.sig) return;
  // A native select that is open would close under a re-render: wait for the next poll.
  const active = document.activeElement;
  if (!force && active && active.tagName === "SELECT" && col.list.contains(active)) return;
  const top = col.list.scrollTop;
  const frag = document.createDocumentFragment();
  if (!cards.length) frag.appendChild(el("li", "col-empty", "Drop a card here"));
  for (const c of cards) frag.appendChild(renderCard(c, repo));
  col.list.replaceChildren(frag);
  col.list.scrollTop = top;
  col.sig = sig;
}

function focusedCard() {
  const active = document.activeElement;
  const card = active && active.closest ? active.closest(".card") : null;
  if (!card) return null;
  return { n: card.dataset.n, select: active.tagName === "SELECT" };
}

function restoreFocus(focus) {
  if (!focus) return;
  const active = document.activeElement;
  if (active && active !== document.body && document.contains(active)) return;
  const card = document.querySelector('.card[data-n="' + focus.n + '"]');
  if (!card) return;
  const target = focus.select ? card.querySelector("select") : card;
  (target || card).focus({ preventScroll: true });
}

// renderCard(card, repo) -> <li>: DOM calls only.
function renderCard(c, repo) {
  repo = repo || (S.board && S.board.repo);
  const n = c.number;
  const li = el("li", "card");
  li.dataset.n = String(n);
  li.tabIndex = 0;
  li.draggable = true;
  if (c.active) li.classList.add("active");
  if (S.pendingMove === n) li.classList.add("pending");

  const id = el("div", "card-id");
  if (c.active) {
    id.appendChild(el("span", "active-dot"));
    id.firstChild.setAttribute("aria-hidden", "true");
  }
  id.appendChild(document.createTextNode("#" + n));
  if (c.active) id.appendChild(el("span", "sr-only", "an agent is working on it now"));
  li.appendChild(id);

  li.appendChild(el("div", "card-title", c.title || "(untitled)"));

  const note = c.note || null;
  if (note && (note.round != null || note.pr != null)) {
    const meta = el("div", "card-meta");
    if (note.round != null) meta.appendChild(document.createTextNode("round " + note.round));
    if (note.pr != null) {
      if (note.round != null) meta.appendChild(document.createTextNode(" · "));
      const label = "PR #" + note.pr;
      if (repo && Number.isInteger(note.pr)) {
        const a = el("a", null, label);
        a.href = "https://github.com/" + repo + "/pull/" + note.pr;
        a.target = "_blank";
        a.rel = "noopener noreferrer";
        a.draggable = false;
        meta.appendChild(a);
      } else {
        meta.appendChild(document.createTextNode(label));
      }
    }
    li.appendChild(meta);
  }
  const models = note && formatModels(note.models);
  if (models) {
    const line = el("div", "card-meta", models.text);
    line.title = models.title;
    li.appendChild(line);
  }
  const fails = note && Number.isInteger(note.action_failures) ? note.action_failures : 0;
  if (fails > 0) {
    li.appendChild(el("div", "card-meta warn", fails + (fails === 1 ? " failed attempt" : " failed attempts")));
  }

  const labels = Array.isArray(c.labels) ? c.labels : [];
  if (labels.length) {
    const ul = el("ul", "labels");
    for (const l of labels) ul.appendChild(el("li", "label", l));
    li.appendChild(ul);
  }

  const foot = el("div", "card-foot");
  const sel = el("select", "move");
  sel.setAttribute("aria-label", "Move #" + n + " to");
  const first = el("option", null, "Move to…");
  first.value = "";
  first.selected = true;
  first.disabled = true;
  sel.appendChild(first);
  for (const s of (S.board && S.board.states) || []) {
    const opt = el("option", null, s.name);
    opt.value = s.key;
    if (s.key === c.state) opt.disabled = true;
    sel.appendChild(opt);
  }
  sel.addEventListener("change", function () {
    if (sel.value) moveCard(n, sel.value);
  });
  foot.appendChild(sel);
  li.appendChild(foot);

  li.addEventListener("keydown", function (e) {
    if (e.key === "Enter" && e.target === li) {
      e.preventDefault();
      openCard(n);
    }
  });
  li.addEventListener("dragstart", function (e) {
    S.dragging = n;
    e.dataTransfer.effectAllowed = "move";
    e.dataTransfer.setData("text/plain", "#" + n);
    li.classList.add("dragging");
  });
  li.addEventListener("dragend", function () {
    li.classList.remove("dragging");
    endDrag();
  });
  return li;
}

function bindDrop(col, key) {
  col.addEventListener("dragover", function (e) {
    if (S.dragging === null) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = "move";
    col.classList.add("drop-target");
  });
  col.addEventListener("dragleave", function (e) {
    if (!col.contains(e.relatedTarget)) col.classList.remove("drop-target");
  });
  col.addEventListener("drop", function (e) {
    e.preventDefault();
    const n = S.dragging;
    S.pendingBoard = null; // the move below fetches a fresher board
    endDrag();
    if (n === null) return;
    const card = S.board && S.board.cards.find(function (c) { return c.number === n; });
    if (!card || card.state === key) return;
    moveCard(n, key);
  });
}

function endDrag() {
  S.dragging = null;
  for (const k in S.cols) S.cols[k].el.classList.remove("drop-target");
  if (S.pendingBoard) {
    const b = S.pendingBoard;
    S.pendingBoard = null;
    renderBoard(b);
  }
}

// moveCard(n, state): shows the card in its new column at once, then asks the
// server. A refusal shows the server's error and re-renders from the server.
async function moveCard(n, state) {
  const card = S.board && S.board.cards.find(function (c) { return c.number === n; });
  const from = card ? card.state : null;
  if (card) {
    card.state = state;
    S.pendingMove = n;
    renderBoard(S.board, true);
  }
  let r;
  try {
    r = await api("POST", "/api/cards/" + n + "/move", { state: state });
  } catch (e) {
    r = { ok: false, status: 0, data: { error: "the board server did not answer" } };
  }
  S.pendingMove = null;
  if (!r.ok) {
    const where = from ? " stayed in " + stateName(from) : " did not move";
    showToast("#" + n + where + ": " + errorText(r), "error");
  }
  await fetchBoard(true);
  return r.ok;
}

// --- header and run ----------------------------------------------------------

async function pollRun() {
  clearTimeout(S.runTimer);
  const my = ++S.runSeq;
  let alive = isAlive(S.run);
  try {
    const r = await api("GET", "/api/run");
    if (my !== S.runSeq) return;
    if (r.ok) {
      renderHeader(r.data);
      alive = isAlive(r.data);
    }
  } catch (e) {
    if (my !== S.runSeq) return; // fetchBoard reports the server as unreachable
  }
  S.runFast = alive;
  S.runTimer = setTimeout(pollRun, alive ? RUN_FAST_MS : RUN_SLOW_MS);
}

function runPillText(run) {
  if (S.offline) return "server unreachable";
  switch (run.state) {
    case "running": return run.tick != null ? "running · tick " + run.tick : "running";
    case "stopped": return run.stop_reason ? "stopped: " + run.stop_reason : "stopped";
    default: return run.state || "idle";
  }
}

// renderHeader(run): the pill, cost and hours, Start/Stop, and the log panel
// (when run carries log_tail; /api/board's run does not).
function renderHeader(run) {
  if (run) S.run = Object.assign({}, S.run, run);
  run = S.run || { state: "idle" };
  const state = S.offline ? "offline" : run.state || "idle";

  const pill = $("run-pill");
  pill.dataset.state = state;
  $("run-pill-text").textContent = runPillText(run);
  const tip = [];
  if (run.pid) tip.push("pid " + run.pid);
  if (run.log_path) tip.push(run.log_path);
  pill.title = tip.join("\n");

  const cost = $("run-cost");
  const parts = [];
  if (typeof run.cost === "number") parts.push("$" + run.cost.toFixed(2));
  if (typeof run.hours === "number") parts.push(formatHours(run.hours));
  cost.textContent = parts.join(" · ");
  cost.hidden = !(run.state === "stopped" && parts.length);

  const start = $("start-btn");
  const stop = $("stop-btn");
  start.disabled = S.offline || S.busy || isAlive(run);
  stop.disabled = S.offline || S.busy || run.state !== "running";
  start.classList.toggle("primary", !start.disabled);

  if (S.logOpen && run.log_tail) renderLog(run.log_tail);
}

function renderLog(lines) {
  const pre = $("log");
  const atBottom = pre.scrollHeight - pre.scrollTop - pre.clientHeight < 8;
  const text = lines.length ? lines.join("\n") : "No run log yet. Start a run and its output appears here.";
  if (pre.textContent !== text) pre.textContent = text;
  if (atBottom) pre.scrollTop = pre.scrollHeight;
}

function toggleLog() {
  S.logOpen = !S.logOpen;
  const pre = $("log");
  pre.hidden = !S.logOpen;
  $("log-btn").setAttribute("aria-expanded", String(S.logOpen));
  if (S.logOpen) {
    renderLog((S.run && S.run.log_tail) || []);
    pre.scrollTop = pre.scrollHeight;
    pollRun();
  }
}

async function runAction(path, verb) {
  S.busy = true;
  renderHeader();
  let r;
  try {
    r = await api("POST", path);
  } catch (e) {
    r = { ok: false, status: 0, data: { error: "the board server did not answer" } };
  }
  S.busy = false;
  if (!r.ok) showToast(verb + " failed: " + errorText(r), "error");
  await pollRun();
  fetchBoard();
}

function startRun() {
  return runAction("/api/run/start", "Start");
}

function stopRun() {
  return runAction("/api/run/stop", "Stop");
}

function setOffline(on, why) {
  if (on === S.offline) return;
  S.offline = on;
  if (on) showToast("Can't reach the board server (" + why + "). Retrying every 3 s.", "error");
  renderHeader();
}

// --- toast -------------------------------------------------------------------

function showToast(msg, kind) {
  const t = $("toast");
  t.textContent = msg;
  t.className = kind || "";
  t.hidden = false;
  clearTimeout(S.toastTimer);
  S.toastTimer = setTimeout(hideToast, TOAST_MS);
}

function hideToast() {
  $("toast").hidden = true;
}

// --- hooks for the card drawer (Task 11) and the import view (Task 12) -------

function openCard(n) {
  // Task 11 opens the card drawer here.
}

function openNewCard() {
  // Task 11 opens the drawer on a new card here.
}

function openImport() {
  // Task 12 shows the import view here.
}

// --- start -------------------------------------------------------------------

function init() {
  $("start-btn").addEventListener("click", startRun);
  $("stop-btn").addEventListener("click", stopRun);
  $("log-btn").addEventListener("click", toggleLog);
  $("import-btn").addEventListener("click", function () { openImport(); });
  $("new-card-btn").addEventListener("click", function () { openNewCard(); });
  $("toast").addEventListener("click", hideToast);
  document.addEventListener("visibilitychange", function () {
    if (!document.hidden) {
      fetchBoard();
      pollRun();
    }
  });
  fetchBoard();
  pollRun();
}

init();
