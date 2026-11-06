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
  selectOpen: null,   // {el, at}: a Move to select the user is choosing in
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
    syncDrawer();
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
  // A native select that is open would close under a re-render: skip this
  // poll. col.sig stays old, so the column re-renders once the select closes.
  if (!force && selectHeld(col.list)) return;
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
  return { n: card.dataset.n };
}

// restoreFocus puts focus back on the card itself, never its select, so a
// focused-but-closed select cannot hold a column's re-render.
function restoreFocus(focus) {
  if (!focus) return;
  const active = document.activeElement;
  if (active && active !== document.body && document.contains(active)) return;
  const card = document.querySelector('.card[data-n="' + focus.n + '"]');
  if (card) card.focus({ preventScroll: true });
}

// The select the user is choosing in: set from pointerdown or an opening key
// until change, blur or Escape, and for at most SELECT_HOLD_MS (a native popup
// closed some other way cannot hold a column stale for longer).
const SELECT_HOLD_MS = 10000;

function holdSelect(sel) {
  S.selectOpen = { el: sel, at: Date.now() };
}

function selectHeld(list) {
  const h = S.selectOpen;
  if (!h) return false;
  if (Date.now() - h.at > SELECT_HOLD_MS || !document.contains(h.el)) {
    S.selectOpen = null;
    return false;
  }
  return list.contains(h.el);
}

// releaseSelect: ends the hold and re-renders any column a poll skipped.
function releaseSelect(sel) {
  if (!S.selectOpen || S.selectOpen.el !== sel) return;
  S.selectOpen = null;
  setTimeout(function () {
    if (S.board && S.pendingMove === null) renderBoard(S.board);
  }, 0);
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
  sel.addEventListener("pointerdown", function () { holdSelect(sel); });
  sel.addEventListener("keydown", function (e) {
    if (e.key === "Escape" || e.key === "Tab") releaseSelect(sel);
    else if (e.key === " " || e.key === "Enter" || e.key === "ArrowDown" || e.key === "ArrowUp") holdSelect(sel);
  });
  sel.addEventListener("blur", function () { releaseSelect(sel); });
  sel.addEventListener("change", function () {
    releaseSelect(sel);
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
  li.addEventListener("click", function (e) {
    if (e.target.closest("a, select, button")) return;
    openCard(n);
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

// --- card drawer -------------------------------------------------------------

const NOTE_MARKER = "<!-- fleet-board:manager-note -->";
const NEW_CARD_BODY = "## Acceptance\n- ";
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

// S.drawer while open: {n (null = new card), card (the last GET reply),
// base: {title, body, labels, state} as saved, labels: the edited label list,
// opener: the element to refocus on close, seq, busy}.
S.drawer = null;

function openCard(n) {
  return openDrawer(n);
}

function openNewCard() {
  return openDrawer(null);
}

// openDrawer(n | null): shows the drawer for card n, or empty for a new card.
async function openDrawer(n, opener) {
  const prev = S.drawer;
  const d = {
    n: n,
    card: null,
    base: null,
    labels: [],
    opener: opener || (prev ? prev.opener : document.activeElement),
    seq: prev ? prev.seq + 1 : 1,
    busy: false,
  };
  S.drawer = d;
  clearDrawer(n);
  showDrawer();
  if (n === null) {
    renderDrawer(null);
    history.replaceState(null, "", "/");
    $("dr-title").focus();
    return;
  }
  history.replaceState(null, "", "/cards/" + n);
  const card = await fetchCard(n);
  if (S.drawer !== d) return;
  if (!card) {
    closeDrawer();
    return;
  }
  renderDrawer(card);
  $("dr-title").focus();
}

const DRAWER_FIELDS = ["dr-title", "dr-state", "dr-body", "dr-label-input", "dr-comment", "dr-comment-btn"];

// clearDrawer(n): empties every field, the comment box and the label input,
// and disables them until renderDrawer fills them, so nothing typed or shown
// for one card carries over to the next (or to a new card).
function clearDrawer(n) {
  $("dr-num").textContent = n === null ? "New card" : "#" + n;
  $("dr-title").value = "";
  $("dr-body").value = "";
  $("dr-label-input").value = "";
  $("dr-comment").value = "";
  $("dr-state").replaceChildren();
  $("dr-preview").replaceChildren();
  $("dr-labels").replaceChildren();
  $("dr-comments").replaceChildren();
  $("dr-meta").replaceChildren();
  setDrawerFields(false);
  updateDirty();
}

function setDrawerFields(on) {
  for (const id of DRAWER_FIELDS) $(id).disabled = !on;
}

async function fetchCard(n) {
  let r;
  try {
    r = await api("GET", "/api/cards/" + n);
  } catch (e) {
    r = { ok: false, status: 0, data: { error: "the board server did not answer" } };
  }
  if (!r.ok) {
    showToast("Could not open #" + n + ": " + errorText(r), "error");
    return null;
  }
  return r.data;
}

function showDrawer() {
  $("drawer").hidden = false;
  $("drawer-dim").hidden = false;
  $("board").inert = true;
  $("top").inert = true;
}

// closeDrawer(): hides the drawer and returns focus to what opened it.
function closeDrawer() {
  const d = S.drawer;
  S.drawer = null;
  $("drawer").hidden = true;
  $("drawer-dim").hidden = true;
  $("board").inert = false;
  $("top").inert = false;
  if (location.pathname !== "/") history.replaceState(null, "", "/");
  if (!d) return;
  let target = d.opener === document.body ? null : d.opener;
  if (target && target.closest && target.closest(".card")) {
    // The column may have re-rendered since: find the card by number.
    const n = target.closest(".card").dataset.n;
    target = document.querySelector('.card[data-n="' + n + '"]');
  } else if (d.n !== null && !(target && document.contains(target))) {
    target = document.querySelector('.card[data-n="' + d.n + '"]');
  }
  if (!target || !document.contains(target)) target = $("new-card-btn");
  target.focus({ preventScroll: true });
}

// renderDrawer(card | null): fills every field from card (or a blank new
// card). Only called on open and after Save, never from a poll, so unsaved
// edits survive the board refreshing behind the drawer.
function renderDrawer(card) {
  const d = S.drawer;
  const isNew = card === null;
  d.card = card;
  d.base = isNew
    ? { title: "", body: NEW_CARD_BODY, labels: [], state: "backlog" }
    : { title: card.title || "", body: card.body || "", labels: (card.labels || []).slice(), state: card.state };
  d.labels = d.base.labels.slice();
  setDrawerFields(true);

  const drawer = $("drawer");
  drawer.classList.toggle("new", isNew);
  drawer.setAttribute("aria-label", isNew ? "New card" : "Card #" + card.number);
  $("dr-num").textContent = isNew ? "New card" : "#" + card.number;
  $("dr-title").value = d.base.title;
  $("dr-body").value = d.base.body;
  fillStateSelect(d.base.state);
  renderLabels();
  renderPreview();
  renderDrawerMeta();
  $("dr-comments-sec").hidden = isNew;
  if (isNew) {
    $("dr-comments").replaceChildren();
  } else {
    renderComments(card);
  }
  updateDirty();
}

function fillStateSelect(current) {
  const sel = $("dr-state");
  const frag = document.createDocumentFragment();
  for (const s of (S.board && S.board.states) || [{ key: current, name: current }]) {
    const opt = el("option", null, s.name);
    opt.value = s.key;
    frag.appendChild(opt);
  }
  sel.replaceChildren(frag);
  sel.value = current;
}

function renderPreview() {
  $("dr-preview").replaceChildren(md($("dr-body").value));
}

function renderLabels() {
  const d = S.drawer;
  const ul = $("dr-labels");
  const frag = document.createDocumentFragment();
  d.labels.forEach(function (name, i) {
    const li = el("li", "label");
    li.appendChild(el("span", null, name));
    const x = el("button", "label-x", "×");
    x.type = "button";
    x.setAttribute("aria-label", "Remove label " + name);
    x.addEventListener("click", function () {
      d.labels.splice(i, 1);
      renderLabels();
      updateDirty();
      $("dr-label-input").focus();
    });
    li.appendChild(x);
    frag.appendChild(li);
  });
  ul.replaceChildren(frag);
}

function addLabel() {
  const d = S.drawer;
  const input = $("dr-label-input");
  const name = input.value.trim();
  if (!d || !name) return;
  if (d.labels.indexOf(name) === -1) d.labels.push(name);
  input.value = "";
  renderLabels();
  updateDirty();
}

// boardCard(n): the card's summary in the last board poll, or null.
function boardCard(n) {
  return (S.board && S.board.cards.find(function (c) { return c.number === n; })) || null;
}

// noteJson(text): the manager note's fenced JSON object, or null.
function noteJson(text) {
  if (typeof text !== "string") return null;
  const m = /^```json\n([\s\S]*?)\n```\s*$/m.exec(text);
  if (!m) return null;
  try {
    const v = JSON.parse(m[1]);
    return v && typeof v === "object" && !Array.isArray(v) ? v : null;
  } catch (e) {
    return null;
  }
}

// renderDrawerMeta(): `round r · PR #p · models (escalated) · agent working
// now`. Called on render and after every board poll (the active part is live).
function renderDrawerMeta() {
  const d = S.drawer;
  const meta = $("dr-meta");
  if (!d || d.n === null || !d.card) {
    meta.replaceChildren(document.createTextNode(d && d.n === null ? "Not created yet" : ""));
    return;
  }
  const note = noteJson(d.card.manager_note) || {};
  const parts = [];
  if (note.round != null) parts.push(document.createTextNode("round " + note.round));
  if (note.pr != null) {
    const label = "PR #" + note.pr;
    if (d.card.pr_url) {
      const a = el("a", null, label);
      a.href = d.card.pr_url;
      a.target = "_blank";
      a.rel = "noopener noreferrer";
      parts.push(a);
    } else {
      parts.push(document.createTextNode(label));
    }
  }
  const models = formatModels(note.models);
  if (models) {
    const span = el("span", null, models.text + (note.escalated ? " (escalated)" : ""));
    span.title = models.title;
    parts.push(span);
  }
  const live = boardCard(d.n);
  const active = live ? live.active : d.card.active;
  if (active) parts.push(el("span", "dr-now", "agent working now"));
  if (!parts.length) parts.push(document.createTextNode("No manager note yet"));
  const frag = document.createDocumentFragment();
  parts.forEach(function (p, i) {
    if (i) frag.appendChild(document.createTextNode(" · "));
    frag.appendChild(p);
  });
  meta.replaceChildren(frag);
}

// formatTime(iso): HH:MM today, else MMM D HH:MM, in local time.
function formatTime(iso) {
  const t = new Date(iso);
  if (!iso || isNaN(t.getTime())) return "";
  const pad = function (x) { return (x < 10 ? "0" : "") + x; };
  const hm = pad(t.getHours()) + ":" + pad(t.getMinutes());
  const now = new Date();
  if (t.toDateString() === now.toDateString()) return hm;
  return MONTHS[t.getMonth()] + " " + t.getDate() + " " + hm;
}

// noteCommentIndex(card): the index in card.comments of the manager note the
// server trusts (the last marker comment whose body matches manager_note), or -1.
function noteCommentIndex(card) {
  const list = card.comments || [];
  if (card.manager_note == null) return -1;
  for (let i = list.length - 1; i >= 0; i--) {
    const b = list[i] && list[i].body;
    if (typeof b !== "string" || b.indexOf(NOTE_MARKER) !== 0) continue;
    const rest = b.indexOf("\n") === -1 ? "" : b.slice(b.indexOf("\n") + 1);
    if (rest === card.manager_note) return i;
  }
  return -1;
}

function renderComments(card) {
  const list = Array.isArray(card.comments) ? card.comments : [];
  const noteAt = noteCommentIndex(card);
  const frag = document.createDocumentFragment();
  list.forEach(function (c, i) {
    if (!c || typeof c !== "object") return;
    const li = el("li", "dr-comment-item");
    const when = formatTime(c.created_at);
    if (i === noteAt) {
      li.appendChild(renderNoteComment(c, card.manager_note, when));
    } else {
      const head = el("div", "dr-c-head", [c.author || "unknown", when].filter(Boolean).join(" · "));
      if (c.created_at) head.title = c.created_at;
      li.appendChild(head);
      const body = el("div", "dr-c-body md");
      body.appendChild(md(c.body));
      li.appendChild(body);
    }
    frag.appendChild(li);
  });
  $("dr-comments").replaceChildren(frag);
}

// renderNoteComment: one line `author · manager note · time ▸ {...}` that
// toggles the pretty-printed JSON (the raw body when the fence does not parse).
function renderNoteComment(c, noteBody, when) {
  const wrap = document.createDocumentFragment();
  const obj = noteJson(noteBody);
  const pre = el("pre", "note-json", obj ? JSON.stringify(obj, null, 2) : noteBody);
  pre.id = "note-json-" + c.id;
  pre.hidden = true;
  const btn = el("button", "note-toggle");
  btn.type = "button";
  btn.setAttribute("aria-expanded", "false");
  btn.setAttribute("aria-controls", pre.id);
  btn.appendChild(el("span", "note-head", [c.author || "unknown", "manager note", when].filter(Boolean).join(" · ")));
  btn.appendChild(chevron());
  const peek = obj ? JSON.stringify(obj) : String(noteBody).replace(/\s+/g, " ").trim();
  btn.appendChild(el("span", "note-peek", peek.length > 80 ? peek.slice(0, 80) + "…" : peek));
  btn.addEventListener("click", function () {
    const open = btn.getAttribute("aria-expanded") !== "true";
    btn.setAttribute("aria-expanded", String(open));
    pre.hidden = !open;
  });
  wrap.appendChild(btn);
  wrap.appendChild(pre);
  return wrap;
}

function drawerEdits() {
  const d = S.drawer;
  return {
    title: $("dr-title").value,
    body: $("dr-body").value,
    labels: d.labels.slice(),
    state: $("dr-state").value,
  };
}

function isDirty() {
  const d = S.drawer;
  if (!d || !d.base) return false;
  if (d.n === null) return true;
  const e = drawerEdits();
  return e.title !== d.base.title || e.body !== d.base.body || e.state !== d.base.state ||
    JSON.stringify(e.labels) !== JSON.stringify(d.base.labels);
}

// updateDirty(): Save is the page's one filled button only while there is
// something to save.
function updateDirty() {
  const save = $("dr-save");
  const dirty = isDirty();
  save.classList.toggle("primary", dirty && !(S.drawer && S.drawer.busy));
  save.disabled = !!(S.drawer && S.drawer.busy) || !dirty;
}

function setDrawerBusy(on) {
  if (S.drawer) S.drawer.busy = on;
  updateDirty();
  $("dr-comment-btn").disabled = on;
}

async function writeApi(method, path, body) {
  try {
    return await api(method, path, body);
  } catch (e) {
    return { ok: false, status: 0, data: { error: "the board server did not answer" } };
  }
}

// saveDrawer(): PATCH title, body and labels, then a changed state through the
// move route. A new card is created with POST /api/cards and then opened.
async function saveDrawer() {
  const d = S.drawer;
  if (!d || d.busy) return;
  if ($("dr-label-input").value.trim()) addLabel(); // a typed label counts
  if (!isDirty()) return;
  const e = drawerEdits();
  if (!e.title.trim()) {
    showToast("Give the card a title before saving.", "error");
    $("dr-title").focus();
    return;
  }
  setDrawerBusy(true);
  if (d.n === null) {
    const r = await writeApi("POST", "/api/cards", { title: e.title, body: e.body, labels: e.labels, state: e.state });
    if (S.drawer !== d) return;
    setDrawerBusy(false);
    fetchBoard(true);
    if (r.ok && Number.isInteger(r.data.number)) {
      showToast("Created #" + r.data.number + ".");
      openDrawer(r.data.number);
      return;
    }
    showToast("Card not created: " + errorText(r), "error");
    const made = /created card #(\d+)/.exec(errorText(r));
    if (made) openDrawer(Number(made[1]));
    return;
  }

  const n = d.n;
  const fields = e.title !== d.base.title || e.body !== d.base.body ||
    JSON.stringify(e.labels) !== JSON.stringify(d.base.labels);
  if (fields) {
    const r = await writeApi("PATCH", "/api/cards/" + n, { title: e.title, body: e.body, labels: e.labels });
    if (S.drawer !== d) return;
    if (!r.ok) {
      setDrawerBusy(false);
      showToast("#" + n + " not saved: " + errorText(r), "error");
      return;
    }
  }
  if (e.state !== d.base.state) {
    const r = await writeApi("POST", "/api/cards/" + n + "/move", { state: e.state });
    if (S.drawer !== d) return;
    if (!r.ok) {
      showToast("#" + n + " stayed in " + stateName(d.base.state) + ": " + errorText(r), "error");
    }
  }
  const card = await fetchCard(n);
  fetchBoard(true);
  if (S.drawer !== d) return;
  d.busy = false;
  $("dr-comment-btn").disabled = false;
  if (!card) {
    updateDirty();
    return;
  }
  // Everything was saved or nothing changed but a refused state, so a fresh
  // render loses no edit and resets a refused select to the stored state.
  renderDrawer(card);
}

// submitComment(): posts the comment box, then reloads only the comments and
// the meta line, so unsaved edits above it stay.
async function submitComment() {
  const d = S.drawer;
  const box = $("dr-comment");
  const text = box.value;
  if (!d || d.n === null || d.busy || !text.trim()) return;
  setDrawerBusy(true);
  const r = await writeApi("POST", "/api/cards/" + d.n + "/comments", { body: text });
  if (S.drawer !== d) return;
  if (!r.ok) {
    setDrawerBusy(false);
    showToast("Comment not posted: " + errorText(r), "error");
    return;
  }
  box.value = "";
  const card = await fetchCard(d.n);
  fetchBoard(true);
  if (S.drawer !== d) return;
  setDrawerBusy(false);
  if (card) {
    d.card = card;
    renderComments(card);
    renderDrawerMeta();
  }
}

// syncDrawer(): after a board poll, refresh the live parts of the drawer.
function syncDrawer() {
  if (S.drawer && S.drawer.card) renderDrawerMeta();
}

function bindDrawer() {
  $("dr-close").addEventListener("click", closeDrawer);
  $("drawer-dim").addEventListener("click", closeDrawer);
  $("dr-save").addEventListener("click", saveDrawer);
  $("dr-comment-btn").addEventListener("click", submitComment);
  $("dr-title").addEventListener("input", updateDirty);
  $("dr-state").addEventListener("change", updateDirty);
  $("dr-body").addEventListener("input", function () {
    renderPreview();
    updateDirty();
  });
  $("dr-label-input").addEventListener("keydown", function (e) {
    if (e.key === "Enter") {
      e.preventDefault();
      addLabel();
    }
  });
  $("dr-title").addEventListener("keydown", function (e) {
    if (e.key === "Enter") {
      e.preventDefault();
      saveDrawer();
    }
  });
  $("dr-comment").addEventListener("keydown", function (e) {
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      submitComment();
    }
  });
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape" && S.drawer && !e.defaultPrevented) {
      e.preventDefault();
      closeDrawer();
    }
  });
}

// drawerFromUrl(): /cards/<n> opens that card's drawer on load.
function drawerFromUrl() {
  const m = /^\/cards\/(\d+)$/.exec(location.pathname);
  if (m) openDrawer(Number(m[1]), null);
}

// --- hooks for the import view (Task 12) ------------------------------------

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
  bindDrawer();
  fetchBoard().then(drawerFromUrl);
  pollRun();
}

init();
