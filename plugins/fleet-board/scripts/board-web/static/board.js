// fleet-board local board page. Plain functions, no framework, no build step.
// Card text only ever reaches the page through textContent / createTextNode.
"use strict";

const BOARD_POLL_MS = 3000;
const BOARD_HIDDEN_MS = 30000; // a hidden tab polls the board this often, and asks for no stuck refresh
const TOAST_MS = 8000;
const COLLAPSIBLE = { done: true, wont_do: true };
const SVG_NS = "http://www.w3.org/2000/svg";

const S = {
  board: null,        // the last /api/board reply
  stateKeys: "",      // the column list the board was built for
  cols: {},           // state key -> {el, list, count, sig}
  unknown: null,      // the Unknown state group {el, list, count, sig}
  open: {},           // collapsible state key -> expanded
  dragging: null,     // number of the card being dragged
  pendingBoard: null, // a board that arrived mid-drag, rendered on dragend
  pendingMove: null,  // number of the card whose move is in flight
  offline: false,
  boardSeq: 0,
  boardTimer: null,
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

// prNumber(url): the pull number in a github.com pull URL, or null.
const PR_URL_RE = /^https:\/\/github\.com\/[^/\s]+\/[^/\s]+\/pull\/([1-9][0-9]*)$/;
function prNumber(url) {
  const m = typeof url === "string" ? PR_URL_RE.exec(url) : null;
  return m ? Number(m[1]) : null;
}

function prLink(url, text) {
  const a = el("a", null, text);
  a.href = url;
  a.target = "_blank";
  a.rel = "noopener noreferrer";
  a.draggable = false;
  a.title = url;
  return a;
}

// --- markdown ----------------------------------------------------------------

// md(text) -> DocumentFragment. Headings, paragraphs, bullet and numbered
// lists, fenced code, inline code, emphasis and links; HTML comments dropped;
// any other HTML stays literal text.
// stripComments(lines): drops <!-- ... --> outside fenced code; an unclosed one
// hides the rest of the body but never reaches into a code fence.
function stripComments(lines) {
  const out = [];
  let fence = null;
  let inComment = false;
  for (let line of lines) {
    if (inComment) {
      const end = line.indexOf("-->");
      if (end < 0) continue;
      line = line.slice(end + 3);
      inComment = false;
    }
    if (fence) {
      out.push(line);
      const t = line.trim();
      if (t.indexOf(fence) === 0 && /^(`+|~+)$/.test(t)) fence = null;
      continue;
    }
    const fm = /^\s*(`{3,}|~{3,})\s*([\w+.-]*)\s*$/.exec(line);
    if (fm) {
      fence = fm[1];
      out.push(line);
      continue;
    }
    let start = line.indexOf("<!--");
    while (start >= 0) {
      const end = line.indexOf("-->", start + 4);
      if (end < 0) {
        line = line.slice(0, start);
        inComment = true;
        break;
      }
      line = line.slice(0, start) + line.slice(end + 3);
      start = line.indexOf("<!--");
    }
    out.push(line);
  }
  return out;
}

function md(text) {
  const frag = document.createDocumentFragment();
  let lines = String(text == null ? "" : text)
    .replace(/\r\n?/g, "\n")
    .split("\n");
  lines = stripComments(lines);
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

const MD_INLINE = /`([^`]+)`|\[([^\]]+)\]\(((?:[^()\s]|\([^()\s]*\))+)\)|\*\*(.+?)\*\*|__(.+?)__|\*(?!\s)(.+?)\*|_(?!\s)(.+?)_(?!\w)/;

// mdInline(text, parent): appends text's inline markdown to parent.
function mdInline(text, parent) {
  let rest = text;
  while (rest) {
    const m = MD_INLINE.exec(rest);
    if (!m) {
      parent.appendChild(document.createTextNode(rest));
      break;
    }
    // no lookbehind (Safari before 16.4 rejects it): an _ inside a word is literal
    if (m[7] !== undefined && m.index > 0 && /\w/.test(rest.charAt(m.index - 1))) {
      parent.appendChild(document.createTextNode(rest.slice(0, m.index + 1)));
      rest = rest.slice(m.index + 1);
      continue;
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
  // only a visible tab's poll may start a stuck check on the server (a scan of a large board takes seconds)
  const hidden = !!document.hidden;
  try {
    const r = await api("GET", hidden ? "/api/board?refresh_stuck=0" : "/api/board");
    if (my !== S.boardSeq) return;
    if (!r.ok) throw new Error(errorText(r));
    setOffline(false);
    S.board = r.data;
    renderBoard(r.data, force);
    renderStuck(r.data);
    syncDrawer();
  } catch (e) {
    if (my !== S.boardSeq) return;
    setOffline(true, e.message);
  }
  S.boardTimer = setTimeout(fetchBoard, document.hidden ? BOARD_HIDDEN_MS : BOARD_POLL_MS);
}

// renderStuck(board): the banner above the board counts the cards that carry a
// stuck finding. A suppression text replaces the banner; a failed check is said
// so beside it (the last good findings stay on the cards). While a supervisor
// runs the board carries no stuck findings, so there is no banner.
function renderStuck(board) {
  board = board || {};
  const run = board.run || {};
  const cards = Array.isArray(board.cards) ? board.cards : [];
  const n = cards.filter(function (c) { return c && c.stuck && typeof c.stuck === "object"; }).length;
  const suppressed = typeof run.stuck_suppressed === "string" && run.stuck_suppressed ? clean(run.stuck_suppressed, 300) : "";
  const failed = !suppressed && run.stuck_error ? "stuck check failed: " + clean(run.stuck_error, 300) : "";
  const banner = $("stuck-banner");
  const note = $("stuck-note");
  const bannerText = !suppressed && n > 0 ? stuckBannerText(n) : "";
  if (banner.textContent !== bannerText) banner.textContent = bannerText; // an unchanged alert is not announced again
  banner.hidden = !bannerText;
  const noteText = suppressed || failed;
  if (note.textContent !== noteText) note.textContent = noteText;
  note.hidden = !noteText;
  renderSupervisor(); // Start follows the stuck count
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
  const stateOf = {};
  for (const s of board.states) byState[s.key] = [];
  for (const c of board.cards) stateOf[c.number] = c.state;
  const unknown = [];
  for (const c of board.cards) {
    // the open blockers depend on other cards: kept on the card so a column
    // re-renders when only a blocker's state changed
    c.open_blockers = (Array.isArray(c.blocked_by) ? c.blocked_by : []).filter(function (b) {
      return stateOf[b] !== "done";
    });
    if (byState[c.state] && c.known !== false) byState[c.state].push(c);
    else unknown.push(c);
  }

  const focus = focusedCard();
  for (const s of board.states) {
    const cards = byState[s.key].sort(function (a, b) { return a.number - b.number; });
    renderColumn(s, cards, board.repo, force);
  }
  renderUnknown(unknown.sort(function (a, b) { return a.number - b.number; }), board.repo, force);
  renderColumnTokens();
  if (S.sup && S.sup.seen) renderTokens(); // the All time tooltip depends on whether the Unknown group is shown
  restoreFocus(focus);
}

// renderUnknown: the "Unknown state" group at the end of the board, for cards
// whose stored state is not a column. It exists only while such cards do.
function renderUnknown(cards, repo, force) {
  let g = S.unknown;
  if (!cards.length) {
    if (g) {
      g.el.hidden = true;
      g.list.replaceChildren();
      g.sig = null;
    }
    return;
  }
  if (!g) {
    const col = el("section", "col unknown");
    col.setAttribute("aria-label", "Unknown state");
    const head = el("h2", "col-head");
    head.appendChild(el("span", null, "Unknown state"));
    const count = el("span", "col-count", "0");
    head.appendChild(count);
    const utokens = el("span", "col-tokens");
    head.appendChild(utokens);
    col.appendChild(head);
    const list = el("ol", "cards");
    list.id = "cards-unknown";
    col.appendChild(list);
    g = S.unknown = { el: col, list: list, count: count, tokens: utokens, sig: null };
    $("board").appendChild(col);
  }
  g.el.hidden = false;
  g.count.textContent = String(cards.length);
  const sig = cardsSig(repo, cards);
  if (!force && sig === g.sig) {
    refreshActivity(g.list, cards);
    return;
  }
  const frag = document.createDocumentFragment();
  for (const c of cards) frag.appendChild(renderCard(c, repo));
  g.list.replaceChildren(frag);
  g.sig = sig;
}

function buildColumns(states) {
  const root = $("board");
  root.replaceChildren();
  S.unknown = null;
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
    const tokens = el("span", "col-tokens");   // the column's all-time token total, set by renderColumnTokens

    if (collapsible) {
      const open = !!S.open[s.key];
      const toggle = el("button", "col-toggle");
      toggle.type = "button";
      toggle.setAttribute("aria-expanded", String(open));
      toggle.setAttribute("aria-controls", list.id);
      toggle.setAttribute("aria-label", s.name);   // the live token total is not part of the name
      toggle.appendChild(el("span", null, s.name));
      toggle.appendChild(count);
      toggle.appendChild(tokens);
      toggle.appendChild(chevron());
      toggle.addEventListener("click", function () { toggleColumn(s.key); });
      col.appendChild(toggle);
      list.hidden = !open;
      col.classList.toggle("open", open);
    } else {
      const head = el("h2", "col-head");
      head.appendChild(el("span", null, s.name));
      head.appendChild(count);
      head.appendChild(tokens);
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
    S.cols[s.key] = { el: col, list: list, count: count, tokens: tokens, toggle: col.querySelector(".col-toggle"), sig: null };
  }
  renderColumnTokens();
}

// compactTokens(n): 999 -> "999", 12345 -> "12.3k", 1234567 -> "1.2M", 1.5e9 -> "1.5B" (one decimal, no trailing ".0").
function compactTokens(n) {
  n = Math.floor(n);
  if (n < 1000) return String(n);
  const trim = function (v) { return v.toFixed(1).replace(/\.0$/, ""); };
  if (n < 999950) return trim(n / 1000) + "k";
  if (n < 999950000) return trim(n / 1000000) + "M";
  return trim(n / 1000000000) + "B";
}

// columnTokens(t) -> {text, title}: a column's all-time token total. A total with
// unknown usage is a lower bound, "≥ n", and its title says so.
function columnTokens(t) {
  const partial = t.partial === true || (isNum(t.unknown) && t.unknown > 0);
  if (partial && t.total === 0) return { text: "unknown tokens", title: "unknown: some usage could not be read" };
  return { text: (partial ? "≥ " : "") + compactTokens(t.total) + " tokens", title: tokensText(t) };
}

// columnsOf(u): the usage reply's per-column map, or null when the ledger is unreadable
// or the reply has none (then no header and no remainder is shown, never a 0).
function columnsOf(u) {
  return u && !u.error && u.columns && typeof u.columns === "object" && !Array.isArray(u.columns) ? u.columns : null;
}

// tokenRemainder() -> {text, title} or null: the card tokens that no page column
// shows (ledger columns the page no longer has, card lines with no column) =
// all-time card total minus the shown columns. Unknown usage in them keeps it a
// lower bound. Null when nothing is left over or the totals cannot be read.
function tokenRemainder() {
  const u = S.usage;
  const cols = columnsOf(u);
  const all = u && u.all_time;
  if (!cols || !all || typeof all !== "object" || !isNum(all.total)) return null;
  let total = all.total;
  let unknown = isNum(all.unknown) ? all.unknown : 0;
  for (const key of Object.keys(S.cols)) {
    const t = Object.prototype.hasOwnProperty.call(cols, key) ? cols[key] : null;
    if (t && typeof t === "object" && isNum(t.total)) {
      total -= t.total;
      unknown -= isNum(t.unknown) ? t.unknown : 0;
    }
  }
  if (total <= 0 && unknown <= 0) return null;
  const r = columnTokens({ total: Math.max(total, 0), unknown: Math.max(unknown, 0), partial: unknown > 0 });
  return { text: r.text, title: r.title + " in columns no longer on the board" };
}

// shownUnknownTokens(): the span on the "Unknown state" group's header while it is shown.
function shownUnknownTokens() {
  return S.unknown && !S.unknown.el.hidden ? S.unknown.tokens : null;
}

function setText(node, text, title) {
  if (node.textContent !== text) node.textContent = text;
  if (node.title !== title) node.title = title;
}

// renderColumnTokens(): the token total in each column header, from S.usage.columns
// (/api/usage, read on the supervisor's 15 s cadence). Columns are keyed by board
// state, the page's own column keys. A column with no ledger line shows nothing,
// and so does every column while the ledger is unreadable (never "0"). Tokens in
// no page column are the remainder: on the "Unknown state" header while that group
// is shown, else in the All time tooltip (see renderTokens). Text is set only when
// it changed, so a poll with the same totals writes nothing, and the column's card
// list and its re-render signature never depend on it.
function renderColumnTokens() {
  const cols = columnsOf(S.usage);
  for (const key of Object.keys(S.cols)) {
    let text = "";
    let title = "";
    if (cols && Object.prototype.hasOwnProperty.call(cols, key) && cols[key] && typeof cols[key] === "object" && isNum(cols[key].total)) {
      const t = columnTokens(cols[key]);
      text = t.text;
      title = t.title;
    }
    setText(S.cols[key].tokens, text, title);
  }
  const unk = shownUnknownTokens();
  if (unk) {
    const r = tokenRemainder();
    setText(unk, r ? r.text : "", r ? r.title : "");
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

// cardsSig(repo, cards): what a column re-renders on. An action's elapsed time
// changes on every poll, so it is left out and updated in place instead.
function cardsSig(repo, cards) {
  return JSON.stringify([repo, cards], function (k, v) {
    return k === "activity" && v && typeof v === "object" ? { action: v.action } : v;
  });
}

// refreshActivity(list, cards): the activity line of each card, in place.
function refreshActivity(list, cards) {
  const byN = {};
  for (const c of cards) if (c.activity) byN[String(c.number)] = cardActivityLine(c);
  for (const li of Array.from(list.children)) {
    const text = li.dataset ? byN[li.dataset.n] : undefined;
    if (text === undefined) continue;
    const line = li.querySelector(".card-exec");
    if (line && line.textContent !== text) line.textContent = text;
  }
}

function renderColumn(state, cards, repo, force) {
  const col = S.cols[state.key];
  col.count.textContent = String(cards.length);
  const sig = cardsSig(repo, cards);
  if (!force && sig === col.sig) {
    refreshActivity(col.list, cards);
    return;
  }
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

// restoreFocus: a re-render replaces the focused card's element; put focus
// back on the card with the same number so keyboard users keep their place.
function restoreFocus(focus) {
  if (!focus) return;
  const active = document.activeElement;
  if (active && active !== document.body && document.contains(active)) return;
  const card = document.querySelector('.card[data-n="' + focus.n + '"]');
  if (card) card.focus({ preventScroll: true });
}

// renderCard(card, repo) -> <li>: DOM calls only.
function renderCard(c, repo) {
  repo = repo || (S.board && S.board.repo);
  const n = c.number;
  const li = el("li", "card");
  li.dataset.n = String(n);
  li.tabIndex = 0;
  if (c.active) li.classList.add("active");
  const stuck = c.stuck && typeof c.stuck === "object" ? c.stuck : null;
  // an agent is working on it: no drag, unless it is stuck so a person can free it
  const locked = !!c.active && !stuck;
  li.draggable = !locked;
  if (locked) li.title = "Can't be moved while an agent is working on it";
  if (stuck) li.classList.add("card--stuck");
  if (S.pendingMove === n) li.classList.add("pending");

  const id = el("div", "card-id");
  if (c.active) {
    id.appendChild(el("span", "active-dot"));
    id.firstChild.setAttribute("aria-hidden", "true");
  }
  id.appendChild(document.createTextNode("#" + n));
  if (c.active) id.appendChild(el("span", "sr-only", "an agent is working on it now"));
  if (stuck) id.appendChild(el("span", "card-stuck-badge", "STUCK"));
  if (c.acceptance_count > 0) id.appendChild(el("span", "card-acc", c.acceptance_count + " acceptance"));
  li.appendChild(id);

  li.appendChild(el("div", "card-title", c.title || "(untitled)"));
  if (c.known === false) li.appendChild(el("div", "card-meta warn card-state", "state: " + c.state));

  const note = c.note || null;
  const open = c.blocked && Array.isArray(c.open_blockers) ? c.open_blockers : [];
  if (open.length) {
    li.classList.add("blocked");
    li.appendChild(el("div", "card-meta blocked-by", "blocked by " + open.map(function (b) { return "#" + b; }).join(", ")));
  }
  const parts = [];
  if (note && note.round != null) parts.push(document.createTextNode("round " + note.round));
  const prNum = prNumber(c.pr_url);
  if (prNum !== null) {
    parts.push(prLink(c.pr_url, "PR #" + prNum));
  } else if (note && note.pr != null && !c.pr_url) {
    parts.push(document.createTextNode("PR #" + note.pr));
  }
  if (parts.length) {
    const meta = el("div", "card-meta");
    parts.forEach(function (p, i) {
      if (i) meta.appendChild(document.createTextNode(" · "));
      meta.appendChild(p);
    });
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

  if (stuck) {
    li.appendChild(el("div", "card-meta card-stuck-detail", "stuck: " + clean(stuck.kind, 60) + (stuck.detail ? " — " + clean(stuck.detail, 300) : "")));
    li.appendChild(el("div", "card-meta card-stuck-resolve", "resolve with: fleet-board supervisor stuck --release " + n));
  }
  const activity = cardActivityLine(c);
  if (activity) li.appendChild(el("div", "card-meta card-exec", activity));

  const labels = Array.isArray(c.labels) ? c.labels : [];
  if (labels.length) {
    const ul = el("ul", "labels");
    for (const l of labels) ul.appendChild(el("li", "label", l));
    li.appendChild(ul);
  }

  li.addEventListener("keydown", function (e) {
    if (e.key === "Enter" && e.target === li) {
      e.preventDefault();
      openCard(n);
    }
  });
  li.addEventListener("click", function (e) {
    if (e.target.closest("a")) return;
    openCard(n);
  });
  li.addEventListener("dragstart", function (e) {
    if (locked) { e.preventDefault(); return; }
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
    let card = n !== null && S.board && S.board.cards.find(function (c) { return c.number === n; });
    if (card && card.active && !(card.stuck && typeof card.stuck === "object")) card = null;
    // only a real move fetches a fresher board; otherwise keep the held poll
    if (card && card.state !== key) S.pendingBoard = null;
    endDrag();
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
  const shown = document.querySelector('.card[data-n="' + n + '"]');
  if (shown) shown.classList.remove("pending"); // the refresh below may be superseded
  if (!r.ok) {
    if (card && from) { // snap back at once; the refresh may not arrive
      card.state = from;
      renderBoard(S.board, true);
    }
    const where = from ? " stayed in " + stateName(from) : " did not move";
    showToast("#" + n + where + ": " + errorText(r), "error");
  }
  await fetchBoard(true);
  return r.ok;
}

// --- header ------------------------------------------------------------------

function setOffline(on, why) {
  if (on === S.offline) return;
  S.offline = on;
  if (on) showToast("Can't reach the board server (" + why + "). Retrying every 3 s.", "error");
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
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

// S.drawer while open: {n (null = new card), card (the last GET reply),
// base: {title, body, labels, state, acceptance, blocked_by, pr_url} as saved,
// labels / acc / blk / pr: the edited labels, acceptance items, blocker
// numbers and PR URL (null = none), opener: the element to refocus on close,
// seq, busy}. The body is prose only; the fields travel as fields.
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
    acc: [],
    blk: [],
    pr: null,
    opener: opener || (prev ? prev.opener : document.activeElement),
    seq: prev ? prev.seq + 1 : 1,
    busy: false,
    usageSeq: 0,      // the newest /api/cards/<n>/usage request
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
  loadCardUsage(d);
}

const DRAWER_FIELDS = ["dr-title", "dr-state", "dr-body", "dr-label-input", "dr-acc-input", "dr-blk-input",
  "dr-pr-edit", "dr-pr-clear", "dr-pr-input", "dr-pr-done", "dr-comment", "dr-comment-btn"];

// clearDrawer(n): empties every field, the comment box and the label input,
// and disables them until renderDrawer fills them, so nothing typed or shown
// for one card carries over to the next (or to a new card).
function clearDrawer(n) {
  $("dr-num").textContent = n === null ? "New card" : "#" + n;
  $("dr-title").value = "";
  $("dr-body").value = "";
  $("dr-label-input").value = "";
  $("dr-acc-input").value = "";
  $("dr-blk-input").value = "";
  $("dr-pr-input").value = "";
  $("dr-comment").value = "";
  $("dr-state").replaceChildren();
  $("dr-preview").replaceChildren();
  $("dr-labels").replaceChildren();
  $("dr-acc").replaceChildren();
  $("dr-acc-count").textContent = "";
  $("dr-blk").replaceChildren();
  setFieldError("dr-blk-input", "dr-blk-err", "");
  setFieldError("dr-pr-input", "dr-pr-err", "");
  showPrForm(false);
  $("dr-pr-view").replaceChildren();
  $("dr-comments").replaceChildren();
  $("dr-meta").replaceChildren();
  setDrawerFields(false);
  clearCardUsage();
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
  $("import").inert = true;
  $("planner").inert = true;
  $("top").inert = true;
}

// requestCloseDrawer(): the user's close (button, backdrop, Escape). Unsaved
// edits ask first; a save in flight finishes on its own, so it does not.
function requestCloseDrawer() {
  const d = S.drawer;
  if (d && !d.busy && d.n !== null && isDirty() &&
      !confirm("Discard your unsaved changes to #" + d.n + "?")) return;
  closeDrawer();
}

// closeDrawer(): hides the drawer and returns focus to what opened it.
function closeDrawer() {
  const d = S.drawer;
  S.drawer = null;
  $("drawer").hidden = true;
  $("drawer-dim").hidden = true;
  $("board").inert = false;
  $("import").inert = false;
  $("planner").inert = false;
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
    ? { title: "", body: "", labels: [], state: "backlog", acceptance: [], blocked_by: [], pr_url: null }
    : {
        title: card.title || "",
        body: typeof card.body === "string" ? card.body : "",
        labels: (card.labels || []).slice(),
        state: card.state,
        acceptance: (Array.isArray(card.acceptance) ? card.acceptance : []).slice(),
        blocked_by: (Array.isArray(card.blocked_by) ? card.blocked_by : []).slice(),
        pr_url: typeof card.pr_url === "string" && card.pr_url ? card.pr_url : null,
      };
  d.labels = d.base.labels.slice();
  d.acc = d.base.acceptance.slice();
  d.blk = d.base.blocked_by.slice();
  d.pr = d.base.pr_url;
  setDrawerFields(true);

  const drawer = $("drawer");
  drawer.classList.toggle("new", isNew);
  drawer.setAttribute("aria-label", isNew ? "New card" : "Card #" + card.number);
  $("dr-num").textContent = isNew ? "New card" : "#" + card.number;
  $("dr-title").value = d.base.title;
  $("dr-body").value = d.base.body;
  fillStateSelect(d.base.state);
  renderLabels();
  renderAcceptance();
  renderBlockers();
  setFieldError("dr-blk-input", "dr-blk-err", "");
  $("dr-pr-field").hidden = isNew; // a card has no PR before it exists
  showPrForm(false);
  renderPr();
  renderBodyPreview();
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
  const known = (S.board && S.board.states) || [];
  if (known.length && !known.some(function (s) { return s.key === current; })) {
    const opt = el("option", null, "Unknown state: " + current);
    opt.value = current;
    frag.appendChild(opt);
  }
  for (const s of (S.board && S.board.states) || [{ key: current, name: current }]) {
    const opt = el("option", null, s.name);
    opt.value = s.key;
    frag.appendChild(opt);
  }
  sel.replaceChildren(frag);
  sel.value = current;
}

function renderBodyPreview() {
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

// --- acceptance, blocked by, pull request ------------------------------------

// accItems(list): the items that would be saved: trimmed, empties dropped.
function accItems(list) {
  return list.map(function (a) { return String(a).trim(); }).filter(function (a) { return a !== ""; });
}

function iconButton(cls, label, child) {
  const b = el("button", "acc-btn " + cls);
  b.type = "button";
  b.setAttribute("aria-label", label);
  b.title = label;
  if (child) b.appendChild(child); else b.textContent = "×";
  return b;
}

// autosize(textarea): grows a one-line criterion to fit its text.
function autosize(ta) {
  ta.style.height = "auto";
  ta.style.height = ta.scrollHeight + "px";
}

// renderAcceptance(focus): the editable list; focus = {i, end} puts the caret
// in item i after the re-render (or in the add box when i is past the end).
function renderAcceptance(focus) {
  const d = S.drawer;
  const ol = $("dr-acc");
  const frag = document.createDocumentFragment();
  const last = d.acc.length - 1;
  d.acc.forEach(function (text, i) {
    const li = el("li", "acc-item");
    li.appendChild(el("span", "acc-box"));
    li.firstChild.setAttribute("aria-hidden", "true");
    const ta = el("textarea", "acc-text");
    ta.rows = 1;
    ta.value = text;
    ta.spellcheck = true;
    ta.setAttribute("aria-label", "Criterion " + (i + 1));
    ta.addEventListener("input", function () {
      d.acc[i] = ta.value.replace(/[\r\n]+/g, " ");
      if (ta.value !== d.acc[i]) ta.value = d.acc[i];
      autosize(ta);
      updateAccCount();
      updateDirty();
    });
    ta.addEventListener("keydown", function (e) { accKey(e, i, ta); });
    li.appendChild(ta);
    const tools = el("span", "acc-tools");
    const up = iconButton("acc-up", "Move criterion " + (i + 1) + " up", chevron());
    up.disabled = i === 0;
    up.addEventListener("click", function () { moveAcc(i, -1); });
    const down = iconButton("acc-down", "Move criterion " + (i + 1) + " down", chevron());
    down.disabled = i === last;
    down.addEventListener("click", function () { moveAcc(i, 1); });
    const x = iconButton("acc-x", "Remove criterion " + (i + 1));
    x.addEventListener("click", function () { removeAcc(i); });
    tools.appendChild(up);
    tools.appendChild(down);
    tools.appendChild(x);
    li.appendChild(tools);
    frag.appendChild(li);
  });
  ol.replaceChildren(frag);
  for (const ta of ol.querySelectorAll(".acc-text")) autosize(ta);
  updateAccCount();
  if (focus) focusAcc(focus.i, focus.end, focus.sel);
}

function focusAcc(i, end, sel) {
  const items = $("dr-acc").querySelectorAll(".acc-text");
  if (i >= items.length || i < 0) {
    $("dr-acc-input").focus();
    return;
  }
  const t = items[i];
  if (sel) {
    t.parentNode.querySelector(sel).focus();
    return;
  }
  t.focus();
  const at = end ? t.value.length : 0;
  t.setSelectionRange(at, at);
}

function updateAccCount() {
  const n = accItems(S.drawer.acc).length;
  $("dr-acc-count").textContent = n ? String(n) : "";
}

// accKey: Enter goes to the next criterion (or the add box), Backspace in an
// empty one removes it, Alt+Up/Down moves it.
function accKey(e, i, ta) {
  if (e.key === "Enter") {
    e.preventDefault();
    focusAcc(i + 1, true);
  } else if (e.key === "Backspace" && ta.value === "") {
    e.preventDefault();
    S.drawer.acc.splice(i, 1);
    renderAcceptance({ i: i > 0 ? i - 1 : 0, end: true });
    updateDirty();
  } else if (e.altKey && (e.key === "ArrowUp" || e.key === "ArrowDown")) {
    e.preventDefault();
    moveAcc(i, e.key === "ArrowUp" ? -1 : 1, true);
  }
}

function moveAcc(i, by, keepCaret) {
  const d = S.drawer;
  const j = i + by;
  if (j < 0 || j >= d.acc.length) return;
  const item = d.acc.splice(i, 1)[0];
  d.acc.splice(j, 0, item);
  const sel = keepCaret ? null : (j === 0 ? ".acc-down" : j === d.acc.length - 1 ? ".acc-up" : by < 0 ? ".acc-up" : ".acc-down");
  renderAcceptance({ i: j, end: true, sel: sel });
  updateDirty();
}

function removeAcc(i) {
  const d = S.drawer;
  d.acc.splice(i, 1);
  renderAcceptance({ i: d.acc.length ? Math.min(i, d.acc.length - 1) : 0, end: true, sel: d.acc.length ? ".acc-x" : null });
  updateDirty();
}

function addAcc() {
  const d = S.drawer;
  const input = $("dr-acc-input");
  const text = input.value.replace(/[\r\n]+/g, " ").trim();
  if (!d || !text) return;
  d.acc.push(text);
  input.value = "";
  renderAcceptance();
  updateDirty();
}

// setFieldError(inputId, errId, msg): an inline error under a field; "" clears.
function setFieldError(inputId, errId, msg) {
  const input = $(inputId);
  const err = $(errId);
  err.textContent = msg;
  err.hidden = !msg;
  if (msg) input.setAttribute("aria-invalid", "true");
  else input.removeAttribute("aria-invalid");
}

// renderBlockers(): one chip per blocker: amber while it is open (not done,
// or not on the board), quiet once done.
function renderBlockers() {
  const d = S.drawer;
  const frag = document.createDocumentFragment();
  d.blk.forEach(function (n, i) {
    const c = boardCard(n);
    const done = !!c && c.state === "done";
    const li = el("li", "label blk-chip" + (done ? " done" : " open"));
    li.appendChild(el("span", "blk-num", "#" + n));
    li.appendChild(el("span", "blk-title", c ? c.title || "(untitled)" : "not on this board"));
    li.title = c ? "#" + n + " " + (c.title || "") + " · " + stateName(c.state) : "#" + n + " is not on this board";
    const x = el("button", "label-x", "×");
    x.type = "button";
    x.setAttribute("aria-label", "Remove blocker #" + n);
    x.addEventListener("click", function () {
      d.blk.splice(i, 1);
      renderBlockers();
      updateDirty();
      $("dr-blk-input").focus();
    });
    li.appendChild(x);
    frag.appendChild(li);
  });
  $("dr-blk").replaceChildren(frag);
  d.blkSig = JSON.stringify(d.blk.map(function (n) {
    const c = boardCard(n);
    return c ? [c.state, c.title] : null;
  }));
}

// addBlocker() -> false when the typed text is refused inline: it must be a
// card number, `#12` or `12`, and not this card. Whether the card exists is
// the server's call, on Save.
function addBlocker() {
  const d = S.drawer;
  const input = $("dr-blk-input");
  const raw = input.value.trim();
  if (!d || !raw) {
    setFieldError("dr-blk-input", "dr-blk-err", "");
    return true;
  }
  const m = /^#?\s*([1-9][0-9]*)$/.exec(raw);
  if (!m) {
    setFieldError("dr-blk-input", "dr-blk-err", "Type a card number, like #12. “" + raw + "” is not one.");
    return false;
  }
  const n = Number(m[1]);
  if (n === d.n) {
    setFieldError("dr-blk-input", "dr-blk-err", "A card cannot block itself.");
    return false;
  }
  setFieldError("dr-blk-input", "dr-blk-err", "");
  if (d.blk.indexOf(n) === -1) d.blk.push(n);
  input.value = "";
  renderBlockers();
  updateDirty();
  return true;
}

// renderPr(): the PR link (or None) with Edit and Clear.
function renderPr() {
  const d = S.drawer;
  const view = $("dr-pr-view");
  const n = prNumber(d.pr);
  if (d.pr && n !== null) {
    view.replaceChildren(prLink(d.pr, prRepo(d.pr) + "#" + n));
  } else if (d.pr) {
    view.replaceChildren(el("span", null, d.pr)); // never a link to an unchecked URL
  } else {
    view.replaceChildren(el("span", "dr-pr-none", "None"));
  }
  $("dr-pr-edit").textContent = d.pr ? "Edit" : "Add";
  $("dr-pr-clear").hidden = !d.pr;
}

function prRepo(url) {
  const m = /^https:\/\/github\.com\/([^/\s]+\/[^/\s]+)\/pull\//.exec(url);
  return m ? m[1] : "";
}

function showPrForm(on) {
  $("dr-pr-form").hidden = !on;
  $("dr-pr-show").hidden = on;
}

function editPr() {
  const d = S.drawer;
  const input = $("dr-pr-input");
  input.value = d.pr || "";
  setFieldError("dr-pr-input", "dr-pr-err", "");
  showPrForm(true);
  input.focus();
  input.select();
}

// applyPr() -> false when the URL is refused inline. Empty clears the PR.
function applyPr() {
  const d = S.drawer;
  const v = $("dr-pr-input").value.trim();
  if (v && prNumber(v) === null) {
    const repo = (S.board && S.board.repo) || "owner/repo";
    setFieldError("dr-pr-input", "dr-pr-err", "Paste a pull request link, like https://github.com/" + repo + "/pull/12.");
    return false;
  }
  setFieldError("dr-pr-input", "dr-pr-err", "");
  d.pr = v || null;
  showPrForm(false);
  renderPr();
  updateDirty();
  $("dr-pr-edit").focus();
  return true;
}

function cancelPr() {
  setFieldError("dr-pr-input", "dr-pr-err", "");
  showPrForm(false);
  $("dr-pr-edit").focus();
}

function clearPr() {
  S.drawer.pr = null;
  renderPr();
  updateDirty();
  $("dr-pr-edit").focus();
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

// drawerStateLocked(): an agent works on the open card and it is not stuck, so
// the state picker (like the tile drag) stays still. A stuck card stays movable.
function drawerStateLocked() {
  const d = S.drawer;
  if (!d || d.n === null || !d.card) return false;
  const src = boardCard(d.n) || d.card;
  return !!src.active && !(src.stuck && typeof src.stuck === "object");
}

function syncStateLock() {
  const sel = $("dr-state");
  const locked = drawerStateLocked();
  sel.disabled = locked;
  if (locked) sel.title = "Can't be moved while an agent is working on it";
  else sel.removeAttribute("title");
}

// renderDrawerMeta(): `round r · models (escalated) · agent working now`. Called on render and after every board poll (the active part is live).
function renderDrawerMeta() {
  const d = S.drawer;
  const meta = $("dr-meta");
  syncStateLock();
  if (!d || d.n === null || !d.card) {
    meta.replaceChildren(document.createTextNode(d && d.n === null ? "Not created yet" : ""));
    return;
  }
  const note = noteJson(d.card.manager_note) || {};
  const parts = [];
  if (note.round != null) parts.push(document.createTextNode("round " + note.round));
  // the PR is its own field below
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
// server trusts: the comment whose id is manager_note_id (older servers send no
// id: the last marker comment whose body matches manager_note), or -1.
function noteCommentIndex(card) {
  const list = card.comments || [];
  if (card.manager_note == null) return -1;
  if (card.manager_note_id != null) {
    for (let i = 0; i < list.length; i++) if (list[i] && list[i].id === card.manager_note_id) return i;
    return -1;
  }
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
    acceptance: accItems(d.acc),
    blocked_by: d.blk.slice(),
    pr_url: d.pr,
  };
}

const same = function (a, b) { return JSON.stringify(a) === JSON.stringify(b); };

function isDirty() {
  const d = S.drawer;
  if (!d || !d.base) return false;
  if (d.n === null) return true;
  // text typed in an add box is saved with the rest
  if ($("dr-acc-input").value.trim() || $("dr-blk-input").value.trim()) return true;
  const e = drawerEdits();
  return e.title !== d.base.title || e.body !== d.base.body || e.state !== d.base.state ||
    !same(e.labels, d.base.labels) || !same(e.acceptance, d.base.acceptance) ||
    !same(e.blocked_by, d.base.blocked_by) || e.pr_url !== d.base.pr_url;
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
  // what is typed in an add box counts
  if ($("dr-label-input").value.trim()) addLabel();
  if ($("dr-acc-input").value.trim()) addAcc();
  if (!addBlocker()) {
    $("dr-blk-input").focus();
    return;
  }
  if (!$("dr-pr-form").hidden && !applyPr()) {
    $("dr-pr-input").focus();
    return;
  }
  if (!isDirty()) return;
  const e = drawerEdits();
  if (!e.title.trim()) {
    showToast("Give the card a title before saving.", "error");
    $("dr-title").focus();
    return;
  }
  setDrawerBusy(true);
  if (d.n === null) {
    const r = await writeApi("POST", "/api/cards", {
      title: e.title, body: e.body, labels: e.labels, state: e.state,
      acceptance: e.acceptance, blocked_by: e.blocked_by,
    });
    if (S.drawer !== d) return;
    setDrawerBusy(false);
    fetchBoard(true);
    if (r.ok && Number.isInteger(r.data.number)) {
      showToast("Created #" + r.data.number + ".");
      openDrawer(r.data.number);
      return;
    }
    const made = /^created card #(\d+) in (\S+?), but the move to (\S+) failed: ([\s\S]*)$/.exec(errorText(r));
    if (made) {
      showToast("Created #" + made[1] + " in " + stateName(made[2]) + ". The move to " +
        stateName(made[3]) + " was refused: " + made[4], "error");
      openDrawer(Number(made[1]));
      return;
    }
    showToast("Card not created: " + errorText(r), "error");
    return;
  }

  const n = d.n;
  const patch = {};
  if (e.title !== d.base.title) patch.title = e.title;
  if (e.body !== d.base.body) patch.body = e.body;
  if (!same(e.labels, d.base.labels)) patch.labels = e.labels;
  if (!same(e.acceptance, d.base.acceptance)) patch.acceptance = e.acceptance;
  if (!same(e.blocked_by, d.base.blocked_by)) patch.blocked_by = e.blocked_by;
  if (e.pr_url !== d.base.pr_url) patch.pr_url = e.pr_url;
  if (Object.keys(patch).length) {
    const r = await writeApi("PATCH", "/api/cards/" + n, patch);
    if (!r.ok) {
      if (S.drawer === d) setDrawerBusy(false);
      fetchBoard(true);
      showToast("#" + n + " not saved: " + errorText(r), "error");
      return;
    }
  }
  // The drawer may have been closed while a write was in flight: the rest of
  // the save and the board refresh still happen, only the drawer is left alone.
  if (e.state !== d.base.state && !drawerStateLocked()) {
    const r = await writeApi("POST", "/api/cards/" + n + "/move", { state: e.state });
    if (!r.ok) {
      showToast("#" + n + " stayed in " + stateName(d.base.state) + ": " + errorText(r), "error");
    }
  }
  if (S.drawer !== d) {
    fetchBoard(true);
    return;
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
  const d = S.drawer;
  if (!d || !d.base) return;
  if (d.card) renderDrawerMeta();
  // a blocker that moved to done (or appeared) changes its chip
  const sig = JSON.stringify(d.blk.map(function (n) {
    const c = boardCard(n);
    return c ? [c.state, c.title] : null;
  }));
  if (sig !== d.blkSig) {
    const hadFocus = $("dr-blk").contains(document.activeElement);
    renderBlockers();
    if (hadFocus) $("dr-blk-input").focus();
  }
}

function bindDrawer() {
  $("dr-close").addEventListener("click", requestCloseDrawer);
  $("drawer-dim").addEventListener("click", requestCloseDrawer);
  $("dr-save").addEventListener("click", saveDrawer);
  $("dr-comment-btn").addEventListener("click", submitComment);
  $("dr-title").addEventListener("input", updateDirty);
  $("dr-state").addEventListener("change", updateDirty);
  $("dr-body").addEventListener("input", function () {
    renderBodyPreview();
    updateDirty();
  });
  $("dr-label-input").addEventListener("keydown", function (e) {
    if (e.key === "Enter") {
      e.preventDefault();
      addLabel();
    }
  });
  $("dr-acc-input").addEventListener("keydown", function (e) {
    if (e.key === "Enter") {
      e.preventDefault();
      addAcc();
    } else if (e.key === "Backspace" && !e.target.value && S.drawer && S.drawer.acc.length) {
      e.preventDefault();
      focusAcc(S.drawer.acc.length - 1, true);
    }
  });
  $("dr-acc-input").addEventListener("input", updateDirty);
  $("dr-blk-input").addEventListener("keydown", function (e) {
    if (e.key === "Enter") {
      e.preventDefault();
      addBlocker();
    }
  });
  $("dr-blk-input").addEventListener("input", function () {
    if (!$("dr-blk-err").hidden) setFieldError("dr-blk-input", "dr-blk-err", "");
    updateDirty();
  });
  $("dr-pr-edit").addEventListener("click", editPr);
  $("dr-pr-clear").addEventListener("click", clearPr);
  $("dr-pr-done").addEventListener("click", applyPr);
  $("dr-pr-input").addEventListener("keydown", function (e) {
    if (e.key === "Enter") {
      e.preventDefault();
      applyPr();
    } else if (e.key === "Escape") {
      e.preventDefault(); // closes the PR box, not the drawer
      cancelPr();
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
      requestCloseDrawer();
    }
  });
}

// drawerFromUrl(): /cards/<n> opens that card's drawer on load.
function drawerFromUrl() {
  const m = /^\/cards\/(\d+)$/.exec(location.pathname);
  if (m) openDrawer(Number(m[1]), null);
}

// --- import ------------------------------------------------------------------

const IMPORT_POLL_MS = 1000;
const SPLIT_FOLD_MS = 180;   // the sheet scales down and tilts
const SPLIT_FLY_MS = 420;    // one strip's flight into its slot
const SPLIT_STAGGER_MS = 60;
const SPLIT_STAGGER_MAX = 8; // strips after the ninth leave with the ninth
const SPLIT_TEXT_HOLD_MS = 200; // a strip shows its band of the plan this long in flight
const SHEET_CHARS = 4000;    // the sheet only ever shows the top of the plan

// S.imp while the view is open: {phase: running|splitting|ready|failed|
// creating, id (the import id), fileName, cards, timer (the next poll)}. Every await checks S.imp is still the same object,
// so a closed view stops polling and ignores late replies.
S.imp = null;

// openDraft(id, text): the preview view for a planner draft. The sheet shows
// the top of the conversation the draft was made from; pollImport takes over.
function openDraft(id, text) {
  if (S.imp) return;
  const imp = { phase: "running", id: id, fileName: null, cards: [], timer: null };
  S.imp = imp;
  $("imp-embed").checked = true;
  $("imp-grid").replaceChildren();
  $("imp-error").hidden = true;
  $("imp-error").textContent = "";
  $("imp-table").textContent = "";
  $("imp-dry").open = false;
  $("imp-sheet").className = "imp-sheet";
  $("imp-sheet-text").textContent = String(text || "").slice(0, SHEET_CHARS);
  setImportPhase("running");
  showImportProgress(0, "");
  $("planner").hidden = true;
  $("import").hidden = false;
  syncPlannerModal();
  $("imp-discard").focus({ preventScroll: true });
  imp.timer = setTimeout(function () { pollImport(id); }, IMPORT_POLL_MS);
}

// cancelImportSession(id): asks the server to stop a grouping session; errors are ignored.
function cancelImportSession(id) {
  return writeApi("POST", "/api/import/" + encodeURIComponent(id) + "/cancel", {}).catch(function () {});
}

// discardImport(): Discard / Escape. While grouping, cancels the server session
// first, then closes.
async function discardImport() {
  const imp = S.imp;
  if (imp && imp.phase === "running" && imp.id && !imp.cancelling) {
    imp.cancelling = true;
    clearTimeout(imp.timer);
    await cancelImportSession(imp.id);
  }
  if (S.imp === imp) closeImport();
}

// closeImport(): back to the chat the draft came from, or to the board. Nothing
// is created; it does not cancel a session (discardImport does that).
function closeImport() {
  const imp = S.imp;
  if (!imp) return;
  clearTimeout(imp.timer);
  S.imp = null;
  const fly = $("imp-fly");
  if (fly) fly.remove();
  const inside = $("import").contains(document.activeElement);
  $("import").hidden = true;
  if (S.pl) {
    $("planner").hidden = false;
    if (inside) $("pl-input").focus({ preventScroll: true });
  } else {
    if (inside || document.activeElement === document.body) $("plan-btn").focus({ preventScroll: true });
  }
  syncPlannerModal();
}

// setImportPhase(phase): shows the parts of the view that phase has.
function setImportPhase(phase) {
  const imp = S.imp;
  if (imp) imp.phase = phase;
  const ready = phase === "ready" || phase === "creating";
  $("import").dataset.phase = phase;
  $("imp-progress").hidden = phase !== "running";
  $("imp-create").hidden = !ready;
  $("imp-embed-row").hidden = !ready;
  $("imp-dry").hidden = !ready || !$("imp-table").textContent;
  const busy = phase === "creating";
  $("imp-create").disabled = busy;
  $("imp-embed").disabled = busy;
  $("imp-discard").disabled = busy;
  const grid = $("imp-grid");
  for (const n of grid.all ? grid.all() : grid.querySelectorAll("button")) {
    if (n.tagName === "BUTTON") n.disabled = phase !== "ready";
  }
}

// setImportStatus(text): the muted header line, after the dropped file's name.
function setImportStatus(text) {
  const imp = S.imp;
  const parts = [];
  if (text && imp && imp.fileName) parts.push(imp.fileName);
  if (text) parts.push(text);
  $("imp-status").textContent = parts.join(" · ");
}

function showImportProgress(elapsed, lastText) {
  setImportStatus("grouping · " + elapsed + " s");
  $("imp-elapsed").textContent = elapsed + " s";
  const line = String(lastText || "").replace(/\s+/g, " ").trim();
  $("imp-last").textContent = line || "Claude is reading the plan";
  $("imp-last").title = line;
}

// pollImport(id): one GET a second while running; ready plays the split.
async function pollImport(id) {
  const imp = S.imp;
  if (!imp || imp.id !== id || imp.phase !== "running") return;
  let r;
  try {
    r = await api("GET", "/api/import/" + encodeURIComponent(id));
  } catch (e) {
    r = { ok: false, status: 0, data: { error: "the board server did not answer" } };
  }
  if (S.imp !== imp || imp.phase !== "running") return;
  if (!r.ok) {
    if (r.status === 404) {
      showImportFailed(errorText(r));
      return;
    }
    // A blip: keep the last progress and ask again; say so after three misses.
    imp.misses = (imp.misses || 0) + 1;
    if (imp.misses >= 3) setImportStatus("board server not answering");
    imp.timer = setTimeout(function () { pollImport(id); }, IMPORT_POLL_MS);
    return;
  }
  imp.misses = 0;
  const d = r.data;
  const elapsed = Number.isInteger(d.elapsed_s) ? d.elapsed_s : 0;
  if (d.state === "running") {
    showImportProgress(elapsed, d.last_text);
    imp.timer = setTimeout(function () { pollImport(id); }, IMPORT_POLL_MS);
    return;
  }
  if (d.state !== "ready") {
    showImportFailed(d.error || "Grouping failed.");
    return;
  }
  const cards = d.cards && Array.isArray(d.cards.cards) ? d.cards.cards.filter(function (c) {
    return c && typeof c === "object";
  }) : [];
  if (!cards.length) {
    showImportFailed("Claude finished without grouping the plan into any cards.");
    return;
  }
  imp.cards = cards;
  setImportPhase("splitting");
  setImportStatus("grouped by Claude in " + elapsed + " s");
  $("imp-table").textContent = typeof d.table === "string" ? d.table.replace(/\s+$/, "") : "";
  renderPreview(cards);
  await playSplit(cards);
  if (S.imp !== imp) return;
  const create = $("imp-create");
  create.textContent = "Create " + cards.length + (cards.length === 1 ? " card" : " cards");
  setImportPhase("ready");
  create.focus({ preventScroll: true });
}

// showImportFailed(error): the error in place of the grid; Discard only. (No
// elapsed time: for a failed session the server measures it only to the
// session log's last write.)
function showImportFailed(error) {
  setImportPhase("failed");
  setImportStatus("grouping failed");
  $("imp-grid").replaceChildren();
  $("imp-sheet").classList.add("spent");
  const box = $("imp-error");
  box.textContent = String(error);
  box.hidden = false;
  $("imp-discard").focus({ preventScroll: true });
}

// cardDeps(card, cards) -> [text]: the titles of the cards this one depends on,
// from depends_on (a card key, or an owner/repo#n ref kept as written) and from
// consumes/produces (consuming a name another card produces).
function cardDeps(card, cards) {
  const byKey = Object.create(null); // a key named "constructor" is just a key
  for (const c of cards) if (typeof c.key === "string") byKey[c.key] = c;
  const out = [];
  const add = function (text) {
    if (text && out.indexOf(text) === -1) out.push(text);
  };
  const titleOf = function (c) { return c.title || c.key; };
  for (const d of Array.isArray(card.depends_on) ? card.depends_on : []) {
    if (typeof d !== "string" || d === card.key) continue;
    add(byKey[d] ? titleOf(byKey[d]) : d);
  }
  const consumes = Array.isArray(card.consumes) ? card.consumes : [];
  for (const other of cards) {
    if (other === card || !Array.isArray(other.produces)) continue;
    if (other.produces.some(function (p) { return consumes.indexOf(p) !== -1; })) add(titleOf(other));
  }
  return out;
}

// renderPreview(cards): one card per entry in the two-column grid.
function renderPreview(cards) {
  const frag = document.createDocumentFragment();
  for (const c of cards) {
    const li = el("li", "imp-card");
    const btn = el("button", "imp-card-btn");
    btn.type = "button";
    btn.disabled = !(S.imp && S.imp.phase === "ready");
    btn.addEventListener("click", function () { openImportDetail(c); });
    li.appendChild(btn);
    btn.appendChild(el("div", "imp-card-title", c.title || c.key || "(untitled)"));
    const meta = el("div", "imp-card-meta");
    const n = Array.isArray(c.acceptance) ? c.acceptance.length : 0;
    meta.appendChild(document.createTextNode(n + " acceptance"));
    const deps = cardDeps(c, cards);
    const produces = (Array.isArray(c.produces) ? c.produces : []).filter(function (p) { return typeof p === "string"; });
    if (deps.length) {
      meta.appendChild(document.createTextNode(" · "));
      meta.appendChild(el("span", "imp-dep", "depends on " + deps.join(", ")));
    } else if (produces.length) {
      meta.appendChild(document.createTextNode(" · produces " + produces.join(", ")));
    }
    btn.appendChild(meta);
    const labels = (Array.isArray(c.labels) ? c.labels : []).filter(function (l) { return typeof l === "string"; });
    if (labels.length) {
      const ul = el("ul", "labels");
      for (const l of labels) ul.appendChild(el("li", "label", l));
      btn.appendChild(ul);
    }
    frag.appendChild(li);
  }
  $("imp-grid").replaceChildren(frag);
}

// playSplit(cards) -> Promise: the sheet tilts back, is cut into one strip
// per card (each a clone of the sheet showing its own band of the plan), and
// the strips fly into their grid slots with a stagger, turning into cards on
// the way. CSS transitions only; resolves when the last strip lands (or at a
// timeout); reduced motion goes straight to the end state.
function playSplit(cards) {
  return new Promise(function (resolve) {
    const sheet = $("imp-sheet");
    const items = Array.prototype.slice.call($("imp-grid").children, 0, cards.length);
    const reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (reduce || !items.length) {
      sheet.classList.add("split", "spent");
      resolve();
      return;
    }
    for (const item of items) item.classList.add("landing");
    const R = sheet.getBoundingClientRect();
    sheet.classList.add("split");
    const imp = S.imp;

    let done = false;
    let fly = null;
    function finish() {
      if (done) return;
      done = true;
      for (const item of items) item.classList.remove("landing");
      if (fly) fly.remove();
      resolve();
    }

    setTimeout(function () {
      if (S.imp !== imp) return finish();
      fly = el("div", "imp-fly");
      fly.id = "imp-fly";
      fly.setAttribute("aria-hidden", "true");
      const band = R.height / items.length;
      const strips = items.map(function (item, i) {
        const delay = Math.min(i, SPLIT_STAGGER_MAX) * SPLIT_STAGGER_MS + "ms";
        const s = el("div", "imp-strip");
        s.style.left = R.left + "px";
        s.style.top = R.top + i * band + "px";
        s.style.width = R.width + "px";
        s.style.height = band + "px";
        // Pivot on the sheet's centre so the strips start exactly where the
        // tilted sheet is.
        s.style.transformOrigin = R.width / 2 + "px " + (R.height / 2 - i * band) + "px";
        s.style.transform = "translate(0px, 0px) scale(0.9) rotate(-3deg)";
        s.style.transitionDelay = delay;
        const copy = sheet.cloneNode(true);
        copy.removeAttribute("id");
        copy.className = "imp-sheet";
        copy.style.width = R.width + "px";
        copy.style.height = R.height + "px";
        copy.style.top = -i * band - 1 + "px";
        // The strip carries its band of the plan for most of the flight.
        copy.style.transitionDelay = Math.min(i, SPLIT_STAGGER_MAX) * SPLIT_STAGGER_MS + SPLIT_TEXT_HOLD_MS + "ms";
        s.appendChild(copy);
        fly.appendChild(s);
        return s;
      });
      document.body.appendChild(fly);
      sheet.classList.add("spent");
      void fly.offsetWidth; // commit the start positions before the end ones

      items.forEach(function (item, i) {
        const T = item.getBoundingClientRect();
        const s = strips[i];
        s.classList.add("flown");
        s.style.transform = "translate(" + (T.left - R.left) + "px, " + (T.top - R.top - i * band) + "px) scale(1) rotate(0deg)";
        s.style.width = T.width + "px";
        s.style.height = T.height + "px";
      });
      const last = strips[strips.length - 1];
      last.addEventListener("transitionend", function (e) {
        if (e.target === last && e.propertyName === "transform") finish();
      });
      const total = SPLIT_FLY_MS + Math.min(items.length - 1, SPLIT_STAGGER_MAX) * SPLIT_STAGGER_MS;
      setTimeout(finish, total + 200);
    }, SPLIT_FOLD_MS);
  });
}

// createImport(id): creates the previewed cards, then back to the board.
async function createImport(id) {
  const imp = S.imp;
  if (!imp || imp.id !== id || imp.phase !== "ready") return;
  setImportPhase("creating");
  const r = await writeApi("POST", "/api/import/" + encodeURIComponent(id) + "/create", { embed_docs: $("imp-embed").checked });
  if (S.imp !== imp) return;
  const created = Array.isArray(r.data.created) ? r.data.created.filter(Number.isInteger) : [];
  const nums = created.map(function (n) { return "#" + n; }).join(", ");
  if (r.ok && created.length) {
    closePlanner();
    closeImport();
    showToast("Created " + nums);
    fetchBoard(true);
    return;
  }
  if (created.length) { // a create that failed partway: those cards exist now
    closePlanner();
    closeImport();
    showToast("Created " + nums + ", then stopped: " + errorText(r), "error");
    fetchBoard(true);
    return;
  }
  showToast("No cards created: " + errorText(r), "error");
  setImportPhase("ready");
}

// --- import card detail -------------------------------------------------------

const DETAIL_LISTS = { labels: "imp-d-labels", scope: "imp-d-scope", acceptance: "imp-d-acceptance", depends_on: "imp-d-depends" };

function strList(v) {
  return (Array.isArray(v) ? v : []).filter(function (x) { return typeof x === "string"; });
}

function lines(text) {
  return String(text).split("\n").map(function (s) { return s.trim(); }).filter(Boolean);
}

// openImportDetail(card): the editable detail dialog for one previewed card.
function openImportDetail(card) {
  const imp = S.imp;
  if (!imp || imp.phase !== "ready") return;
  imp.detail = card;
  imp.detailOpener = document.activeElement;
  $("imp-d-key").textContent = card.key || "";
  $("imp-d-title").value = card.title || "";
  $("imp-d-why").value = typeof card.why === "string" ? card.why : "";
  for (const f in DETAIL_LISTS) $(DETAIL_LISTS[f]).value = strList(card[f]).join("\n");
  $("imp-d-repo").textContent = card.repo || "";
  $("imp-d-consumes").textContent = strList(card.consumes).join(", ");
  $("imp-d-produces").textContent = strList(card.produces).join(", ");
  $("imp-d-error").hidden = true;
  $("imp-d-error").textContent = "";
  $("imp-detail").hidden = false;
  $("imp-d-title").focus({ preventScroll: true });
}

function closeImportDetail() {
  $("imp-detail").hidden = true;
  const imp = S.imp;
  if (imp) {
    const back = imp.detailOpener;
    imp.detail = null;
    imp.detailOpener = null;
    if (back && back.focus) back.focus({ preventScroll: true });
  }
}

// saveImportDetail(): one PATCH with the changed fields; the grid is re-rendered
// from the response without replaying the split. A refusal stays in the dialog.
async function saveImportDetail() {
  const imp = S.imp;
  const card = imp && imp.detail;
  if (!card || imp.detailBusy) return;
  const edits = {};
  const title = $("imp-d-title").value;
  if (title !== (card.title || "")) edits.title = title;
  const why = $("imp-d-why").value;
  if (why !== (typeof card.why === "string" ? card.why : "")) edits.why = why;
  for (const f in DETAIL_LISTS) {
    const now = lines($(DETAIL_LISTS[f]).value);
    if (JSON.stringify(now) !== JSON.stringify(strList(card[f]))) edits[f] = now;
  }
  if (!Object.keys(edits).length) {
    closeImportDetail();
    return;
  }
  imp.detailBusy = true;
  $("imp-d-save").disabled = true;
  const r = await writeApi("PATCH", "/api/import/" + encodeURIComponent(imp.id) + "/cards/" + encodeURIComponent(card.key), edits);
  imp.detailBusy = false;
  $("imp-d-save").disabled = false;
  if (S.imp !== imp) return;
  const d = r.data;
  const cards = r.ok && d.cards && Array.isArray(d.cards.cards) ? d.cards.cards.filter(function (c) {
    return c && typeof c === "object";
  }) : null;
  if (!cards || !cards.length) {
    const box = $("imp-d-error");
    box.textContent = r.ok ? "The server's reply held no cards." : errorText(r);
    box.hidden = false;
    return;
  }
  imp.cards = cards;
  if (typeof d.table === "string") $("imp-table").textContent = d.table.replace(/\s+$/, "");
  renderPreview(cards);
  closeImportDetail();
}

function bindImport() {
  $("imp-detail").hidden = true;
  $("imp-d-form").addEventListener("submit", function (e) {
    e.preventDefault();
    saveImportDetail();
  });
  $("imp-d-save").addEventListener("click", function () { saveImportDetail(); });
  $("imp-d-cancel").addEventListener("click", closeImportDetail);
  $("imp-detail").addEventListener("keydown", function (e) {
    if (e.key === "Escape") closeImportDetail();
  });
  $("imp-discard").addEventListener("click", discardImport);
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape" && S.imp && S.imp.phase === "running" && !S.drawer && !e.defaultPrevented) {
      e.preventDefault();
      discardImport();
    }
  });
  $("imp-create").addEventListener("click", function () {
    if (S.imp) createImport(S.imp.id);
  });
}

// --- planner chat ------------------------------------------------------------

const PLANNER_POLL_MS = 1000;

// S.pl while the chat is open: {id (the conversation id once started), busy (a
// reply is running), turns, timer (the next poll)}. Every await checks S.pl is
// still the same object, so a closed chat stops polling and ignores late replies.
S.pl = null;

function plannerHasUserTurn() {
  return !!S.pl && S.pl.turns.some(function (t) { return t.role === "user"; });
}

function renderTurns() {
  const box = $("pl-transcript");
  box.replaceChildren();
  for (const t of S.pl.turns) {
    const div = document.createElement("div");
    div.className = "pl-turn";
    div.dataset.role = t.role;
    div.textContent = String(t.text);
    box.appendChild(div);
  }
  box.scrollTop = box.scrollHeight;
}

// setPlannerBusy(busy): the input and Send are off while a reply is running.
function setPlannerBusy(busy) {
  const pl = S.pl;
  if (pl) pl.busy = busy;
  $("pl-input").disabled = busy;
  $("pl-send").disabled = busy;
  $("pl-draft").disabled = busy || !plannerHasUserTurn();
  $("pl-running").hidden = !busy;
}

// syncPlannerModal(): the popup shows while the chat or the Draft cards view is open.
function syncPlannerModal() {
  $("planner-modal").hidden = !(S.pl || S.imp);
}

async function openPlanner() {
  if (S.pl) {
    if (!S.imp) $("pl-input").focus();
    return;
  }
  if (S.drawer || S.imp) return;
  const pl = { id: null, busy: true, turns: [], timer: null };
  S.pl = pl;
  $("pl-transcript").replaceChildren();
  $("pl-input").value = "";
  $("planner").hidden = false;
  syncPlannerModal();
  $("plan-btn").setAttribute("aria-expanded", "true");
  setPlannerBusy(true);
  $("pl-running").hidden = true;
  const r = await writeApi("POST", "/api/planner", {});
  if (S.pl !== pl) return;
  if (!r.ok || typeof r.data.id !== "string") {
    showToast("The planner did not start: " + errorText(r), "error");
    closePlanner();
    return;
  }
  pl.id = r.data.id;
  setPlannerBusy(false);
  $("pl-input").focus();
}

// closePlanner(): back to the board. A reply still running on the server is left to land.
function closePlanner() {
  const pl = S.pl;
  if (!pl) return;
  clearTimeout(pl.timer);
  S.pl = null;
  const inside = $("planner").contains(document.activeElement);
  $("planner").hidden = true;
  syncPlannerModal();
  $("plan-btn").setAttribute("aria-expanded", "false");
  if (inside || document.activeElement === document.body) $("plan-btn").focus({ preventScroll: true });
}

// requestClosePlanner(): the user's close (button, Escape). A running reply would be lost, so ask first.
function requestClosePlanner() {
  const pl = S.pl;
  if (!pl) return;
  if (pl.busy && plannerHasUserTurn() &&
      !confirm("A planner reply is still running. If you close now the reply will be lost. Close anyway?")) return;
  closePlanner();
}

async function sendPlanner() {
  const pl = S.pl;
  const text = $("pl-input").value.trim();
  if (!pl || !pl.id || pl.busy || !text) return;
  pl.turns.push({ role: "user", text: text });
  renderTurns();
  $("pl-input").value = "";
  setPlannerBusy(true);
  const r = await writeApi("POST", "/api/planner/" + encodeURIComponent(pl.id) + "/messages", { text: text });
  if (S.pl !== pl) return;
  if (!r.ok) {
    showToast("Message not sent: " + errorText(r), "error");
    pl.turns.pop();
    renderTurns();
    $("pl-input").value = text;
    setPlannerBusy(false);
    $("pl-input").focus();
    return;
  }
  pl.timer = setTimeout(function () { pollPlanner(pl); }, PLANNER_POLL_MS);
}

// pollPlanner(pl): one GET a second while a reply runs; running false shows the turns.
async function pollPlanner(pl) {
  if (S.pl !== pl || !pl.busy) return;
  let r;
  try {
    r = await api("GET", "/api/planner/" + encodeURIComponent(pl.id));
  } catch (e) {
    r = { ok: false, status: 0, data: { error: "the board server did not answer" } };
  }
  if (S.pl !== pl) return;
  if (!r.ok) {
    if (r.status === 404) {
      showToast("The conversation is gone: " + errorText(r), "error");
      setPlannerBusy(false);
      return;
    }
    pl.timer = setTimeout(function () { pollPlanner(pl); }, PLANNER_POLL_MS); // a blip
    return;
  }
  if (r.data.running !== false) {
    pl.timer = setTimeout(function () { pollPlanner(pl); }, PLANNER_POLL_MS);
    return;
  }
  if (Array.isArray(r.data.turns)) {
    pl.turns = r.data.turns.filter(function (t) { return t && typeof t === "object"; });
    renderTurns();
  }
  setPlannerBusy(false);
  $("pl-input").focus({ preventScroll: true });
}

// draftPlanner(): the conversation becomes a plan; the import id goes to the preview.
async function draftPlanner() {
  const pl = S.pl;
  if (!pl || !pl.id || pl.busy || !plannerHasUserTurn()) return;
  const text = pl.turns.map(function (t) { return t.text; }).join("\n\n");
  setPlannerBusy(true);
  const r = await writeApi("POST", "/api/planner/" + encodeURIComponent(pl.id) + "/draft", {});
  if (S.pl !== pl) return;
  setPlannerBusy(false);
  if (!r.ok || typeof r.data.import_id !== "string") {
    showToast("Drafting did not start: " + errorText(r), "error");
    return;
  }
  openDraft(r.data.import_id, text);
}

function bindPlanner() {
  $("pl-send").addEventListener("click", sendPlanner);
  $("pl-draft").addEventListener("click", draftPlanner);
  $("pl-close").addEventListener("click", requestClosePlanner);
  $("pl-input").addEventListener("keydown", function (e) {
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      sendPlanner();
    }
  });
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape" && S.pl && !S.imp && !S.drawer && !e.defaultPrevented) {
      e.preventDefault();
      requestClosePlanner();
    }
  });
}

// --- supervisor --------------------------------------------------------------
// Supervisor mode starts when GET /api/supervisor answers 200 with a boolean
// `running` (the board server always does; until then the supervisor panel stays
// hidden and detection is retried). `running: false` is "no supervisor", not a
// snapshot: Start launches one. Nothing here sends a mutating request on load or
// from a poll: commands run only from a click or key press. Every server-provided
// value reaches the page through textContent / createTextNode (clean() also
// drops control characters). Tokens are the only unit shown; there is no money.

const SUP_POLL_MS = 3000;
const SUP_HIDDEN_MS = 30000;    // polling backs off while the document is hidden
const SUP_DETECT_MS = 5000;     // detection is retried until the board answers with a running flag
const SUP_USAGE_MS = 15000;     // /api/usage is re-read at most this often
const SUP_ACK_MS = 30000;       // an acknowledged Start the supervisor never reports is dropped
const CONTROL_RE = /[\u0000-\u0008\u000b-\u001f\u007f-\u009f‎‏‪-‮⁦-⁩]/g;

S.supMode = false;
S.supervisor = null;  // the last status snapshot of a RUNNING supervisor (or the body of a 409); null when none runs
S.usage = null;       // the last token totals: {run, all_time, planner, error?}
S.sup = {
  seq: 0,           // newest status poll; an older one is dropped
  ackSeq: 0,        // bumped by a command reply: polls started before it are dropped
  timerSeq: 0,
  idSeq: 0,
  seen: false,      // a status reply (running or not) has been adopted
  stale: false,     // the last poll failed: the board server did not give a status
  reason: "",
  okAt: null,       // ms of the last good status poll
  busy: false,      // a command is in flight
  req: null,        // {key, id, body}: the command a click may retry
  ack: null,        // {kind, phase, state_revision, at}: acknowledged, not yet observed
  hint: 0,          // the revision an acknowledgement reported
  notice: null,
  menuOpen: false,
  statusText: null,
  tokensText: null,
  visBound: false,
  usageAt: null,    // ms of the last /api/usage read
  usageRunning: null, // whether a supervisor was running at that read
};

function clean(v, max) {
  let t = String(v === undefined || v === null ? "" : v).replace(CONTROL_RE, "").replace(/\s+/g, " ");
  max = max || 300;
  if (t.length > max) t = t.slice(0, max) + "…";
  return t;
}

function isNum(v) {
  return typeof v === "number" && isFinite(v);
}

// A timestamp from the server: an ISO string or epoch seconds. -> ms or null.
function toMs(v) {
  if (isNum(v)) return v * 1000;
  const t = typeof v === "string" ? Date.parse(v) : NaN;
  return isNaN(t) ? null : t;
}

function fmtUtc(ms) {
  return new Date(ms).toISOString().replace("T", " ").replace(/(\.\d+)?Z$/, " UTC");
}

function ageText(ms) {
  const secs = Math.floor((Date.now() - ms) / 1000);
  if (secs < 0) return "in the future";
  if (secs < 5) return "just now";
  if (secs < 60) return secs + " seconds ago";
  const mins = Math.floor(secs / 60);
  if (mins < 60) return mins + (mins === 1 ? " minute ago" : " minutes ago");
  const hours = Math.floor(mins / 60);
  if (hours < 48) return hours + (hours === 1 ? " hour ago" : " hours ago");
  const days = Math.floor(hours / 24);
  return days + " days ago";
}

function fmtDuration(sec) {
  if (!isNum(sec) || sec < 0) return "unknown";
  sec = Math.floor(sec);
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  const s = sec % 60;
  if (h) return h + "h " + m + "m " + s + "s";
  if (m) return m + "m " + s + "s";
  return s + "s";
}

// fmtInt(n): 1234 -> "1,234" (no locale: the page reads the same everywhere)
function fmtInt(n) {
  return String(Math.floor(n)).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

// A token total from /api/usage. `total` is the sum of the counts that were
// readable, so a total with unknown usage is a lower bound: "≥ n", never an
// exact figure (an input of 0 beside unknown usage is not 0).
function tokensText(t) {
  if (!t || typeof t !== "object" || !isNum(t.total)) return "unknown";
  const partial = t.partial === true || (isNum(t.unknown) && t.unknown > 0);
  return partial ? "≥ " + fmtInt(t.total) + " (some usage unknown)" : fmtInt(t.total) + " tokens";
}

// budgetText(b): the one Budget line, the tokens counted toward limits.max_tokens (input, output and
// cache write; cache reads are shown in "This run" but not counted). Null when the status has none.
function budgetText(b) {
  if (!b || typeof b !== "object" || !isNum(b.tokens)) return null;
  const n = (b.partial === true ? "≥ " : "") + fmtInt(b.tokens);
  return isNum(b.cap) && b.cap > 0 ? "Budget: " + n + " of " + fmtInt(b.cap) + " (cache reads not counted)"
    : "Budget: " + n + " (no limit; cache reads not counted)";
}

// One count of a usage row: null (the ledger could not read it) is "unknown", never 0.
function countText(v) {
  return isNum(v) ? fmtInt(v) : "unknown";
}

// msgText(reply): the reason the server gave, whatever key it used.
function msgText(r) {
  const d = r.data || {};
  for (const k of ["reason", "message", "error"]) {
    if (typeof d[k] === "string" && d[k]) return clean(d[k], 400);
  }
  return "the server answered HTTP " + r.status;
}

function newRequestId() {
  S.sup.idSeq++;
  return "ui-" + Date.now().toString(36) + "-" + S.sup.idSeq + "-" + Math.random().toString(36).slice(2, 10);
}

// runCommand(holder, key, path, build): POSTs one revision-bound command.
// holder.req keeps {key, id, body} after a lost or 5xx reply, so the next click
// of the SAME action resends the identical request id; any other answer clears
// it. Returns the reply, or null when no reply arrived.
async function runCommand(holder, key, path, build) {
  if (!holder.req || holder.req.key !== key) holder.req = { key: key, id: newRequestId(), body: null };
  const req = holder.req;
  if (!req.body) req.body = Object.assign({ request_id: req.id }, build());
  let r = null;
  try {
    r = await api("POST", path, req.body);
  } catch (e) {
    r = null;
  }
  if (r && r.status < 500) holder.req = null;
  return r;
}

function showNotice(msg) {
  const sup = S.sup;
  if (!sup.notice) {
    const box = el("div", "sup-notice");
    box.setAttribute("role", "alert");
    box.hidden = true;
    const text = el("span", "sup-notice-text");
    const close = el("button", "text-btn", "Dismiss");
    close.type = "button";
    close.addEventListener("click", hideNotice);
    box.appendChild(text);
    box.appendChild(close);
    document.body.appendChild(box);
    sup.notice = { box: box, text: text };
  }
  sup.notice.text.textContent = clean(msg, 500);
  sup.notice.box.hidden = false;
}

function hideNotice() {
  if (S.sup.notice) S.sup.notice.box.hidden = true;
}

// --- supervisor: mode, polling ------------------------------------------------

// A status snapshot of a running supervisor (also the body a 409 carries).
function isSnapshot(d) {
  return !!d && typeof d === "object" && !Array.isArray(d) &&
    ("revision" in d || "desired_mode" in d || "schema_version" in d);
}

// detectSupervisor(): the board server always answers GET /api/supervisor with a
// running flag. Any other outcome (a thrown fetch, a non-200, a reply without the
// flag) is a failure to ask: it is retried on a timer, and the supervisor panel
// stays hidden meanwhile, so no Start is sent before the board has answered.
async function detectSupervisor() {
  if (S.supMode) return;
  let r = null;
  try {
    r = await api("GET", "/api/supervisor");
  } catch (e) {
    r = null;
  }
  if (!r || !r.ok || typeof r.data.running !== "boolean") {
    setTimeout(detectSupervisor, SUP_DETECT_MS);
    return;
  }
  enterSupervisorMode();
  await supervisorTick(r);
}

function enterSupervisorMode() {
  if (S.supMode) return;
  S.supMode = true;
  const root = $("supervisor");
  // index.html already places it; this only matters for a page built without it
  if (!document.body.contains(root)) document.body.appendChild(root);
  root.hidden = false;
  const status = $("supervisor-status");
  if (!root.contains(status)) root.appendChild(status);
  status.hidden = false;
  status.setAttribute("role", "status");
  status.setAttribute("aria-live", "polite");
  status.setAttribute("aria-label", "Supervisor status");
  $("supervisor-stop-menu").replaceChildren($("supervisor-drain-btn"), $("supervisor-cancel-btn"));
  setStopMenu(false);
  if (!S.sup.visBound) {
    S.sup.visBound = true;
    document.addEventListener("visibilitychange", function () {
      if (document.hidden) scheduleSupervisor(SUP_HIDDEN_MS);
      else supervisorTick();
    });
  }
}

function scheduleSupervisor(ms) {
  const my = ++S.sup.timerSeq;
  setTimeout(function () {
    if (my === S.sup.timerSeq) return supervisorTick();
  }, ms);
}

// supervisorTick(first): one status poll, then the token totals. first is an
// already fetched /api/supervisor reply (the mode detection's).
async function supervisorTick(first) {
  const sup = S.sup;
  const seq = ++sup.seq;
  const ack0 = sup.ackSeq;
  let r = first || null;
  let failure = null;
  if (!r) {
    try {
      r = await api("GET", "/api/supervisor");
    } catch (e) {
      failure = "no answer from the board server";
    }
  }
  if (seq !== sup.seq) return; // a newer poll owns the schedule
  if (r && !r.ok) failure = msgText(r);
  if (r && r.ok && typeof r.data.running !== "boolean") failure = "unreadable supervisor status";
  if (r && r.ok && r.data.running === true && !isSnapshot(r.data)) failure = "unreadable supervisor status";
  if (failure) {
    markStale("supervisor status unavailable: " + failure);
  } else if (ack0 === sup.ackSeq) {
    if (r.data.running) adoptSnapshot(r.data);
    else adoptNotRunning(r.data);
  }
  if (!failure && ack0 === sup.ackSeq) {
    const running = r.data.running === true;
    const due = sup.usageAt === null || Date.now() - sup.usageAt >= SUP_USAGE_MS || sup.usageRunning !== running;
    if (due) {
      await refreshUsage(seq, r.data);
    } else if (!running) { // a not-running reply carries the ledger totals for free
      S.usage = { run: null, all_time: r.data.all_time, planner: r.data.planner, columns: r.data.columns, error: r.data.error };
      renderTokens();
    }
  }
  if (seq !== sup.seq) return;
  scheduleSupervisor(document.hidden ? SUP_HIDDEN_MS : SUP_POLL_MS);
}

function markStale(reason) {
  S.sup.stale = true;
  S.sup.reason = reason;
  renderSupervisor();
}

// adoptSnapshot(data): replaces the last status with a fresh full snapshot of a running supervisor.
function adoptSnapshot(data) {
  const sup = S.sup;
  const was = sup.stale;
  S.supervisor = data;
  sup.seen = true;
  sup.hint = 0;
  sup.stale = false;
  sup.reason = "";
  sup.okAt = Date.now();
  const ack = sup.ack;
  if (ack) {
    const phase = supPhase(data);
    const reached = ack.kind === "pause" ? phase === "paused"
      : ack.kind === "stop" ? phase === "stopping" || phase === "stopped" || phase === "idle"
      : data.ready === true && phase === "running";
    const moved = isNum(ack.state_revision) && isNum(data.revision) && data.revision > ack.state_revision;
    // a Start is not done until the supervisor is ready (its startup check has finished)
    if ((reached || moved) && (ack.kind !== "start" || data.ready === true)) sup.ack = null;
  }
  if (was) fetchBoard(true); // reconnected: a fresh board with the snapshot
  renderStuck(S.board); // the banner's wording follows whether a supervisor runs; it renders the controls
}

// adoptNotRunning(data): the board answered {running: false}. That is a state of its
// own (Start launches a supervisor), never a snapshot and never an outage.
function adoptNotRunning(data) {
  const sup = S.sup;
  const was = sup.stale;
  S.supervisor = null;
  sup.seen = true;
  sup.hint = 0;
  sup.stale = false;
  sup.reason = "";
  sup.okAt = Date.now();
  const ack = sup.ack;
  if (ack && (ack.kind === "stop" || ack.kind === "pause" || Date.now() - ack.at > SUP_ACK_MS)) sup.ack = null;
  if (was) fetchBoard(true);
  renderStuck(S.board);
}

// refreshUsage(seq, data): the token totals. /api/usage is always answered; when it
// is not, a not-running reply still carries the ledger totals.
async function refreshUsage(seq, data) {
  S.sup.usageAt = Date.now();
  S.sup.usageRunning = !!(data && data.running === true);
  let usage = null;
  try {
    const r = await api("GET", "/api/usage");
    if (r.ok && r.data && typeof r.data === "object" && !Array.isArray(r.data)) usage = r.data;
  } catch (e) {
    usage = null;
  }
  if (seq !== S.sup.seq) return;
  if (!usage && data && data.running === false) {
    usage = { run: null, all_time: data.all_time, planner: data.planner, columns: data.columns, error: data.error };
  }
  if (usage) S.usage = usage;
  renderTokens();
}

// --- supervisor: rendering ----------------------------------------------------

function supPhase(v) {
  return typeof v.phase === "string" && v.phase ? v.phase : null;
}

function supHeartbeatAt(v) {
  return v && v.heartbeat && typeof v.heartbeat === "object" ? v.heartbeat.at : null;
}

function supItem(cls, label, value) {
  const item = el("span", "sup-item" + (cls ? " " + cls : ""));
  if (label) item.appendChild(el("span", "sup-k", label));
  item.appendChild(el("span", "sup-v", value));
  return item;
}

function renderSupervisor() {
  if (!S.supMode) return;
  const sup = S.sup;
  const view = S.supervisor || {};
  const running = !!S.supervisor;
  const frag = document.createDocumentFragment();
  const phase = supPhase(view);

  // headline: desired mode, observed phase, readiness (or: no supervisor)
  const head = el("span", "sup-head");
  if (running) {
    head.appendChild(supItem("sup-mode", "desired", clean(view.desired_mode || "unknown", 40)));
    if (sup.ack) {
      head.appendChild(supItem("sup-phase pending", "phase", clean(sup.ack.phase, 40) + " (acknowledged, waiting for the supervisor to report it)"));
    } else {
      head.appendChild(supItem("sup-phase", "phase", clean(phase || "unknown", 40)));
    }
    head.appendChild(supItem(view.ready === true ? "" : "sup-warn", "", view.ready === true ? "ready" : view.ready === false ? "not ready" : "readiness unknown"));
  } else if (sup.seen) {
    head.appendChild(supItem("sup-mode sup-off", "supervisor", "not running"));
    if (sup.ack) head.appendChild(supItem("sup-phase pending", "phase", clean(sup.ack.phase, 40) + " (acknowledged, waiting for the supervisor to report it)"));
  } else {
    head.appendChild(supItem("sup-warn", "supervisor", "status unknown"));
  }
  frag.appendChild(head);

  if (sup.stale) {
    const row = el("span", "sup-item sup-warn sup-stale");
    row.appendChild(el("span", "sup-k", "unreachable"));
    row.appendChild(el("span", "sup-v", clean(sup.reason || "no connection", 300)));
    frag.appendChild(row);
    if (sup.okAt !== null) {
      const when = el("span", "sup-item");
      when.appendChild(el("span", "sup-k", "last known"));
      const t = el("time", "sup-v", fmtUtc(sup.okAt));
      t.setAttribute("datetime", new Date(sup.okAt).toISOString());
      when.appendChild(t);
      when.appendChild(el("span", "sup-v", ageText(sup.okAt)));
      frag.appendChild(when);
    }
  }

  if (running || sup.stale) {
    // slots: never shown as 0 when the supervisor cannot say
    const capacity = view.capacity && typeof view.capacity === "object" ? view.capacity : {};
    const cap = isNum(capacity.global_cap) ? String(capacity.global_cap) : "unknown";
    if (sup.stale || !isNum(capacity.slots)) {
      frag.appendChild(supItem("sup-warn", "", "occupancy unknown"));
      frag.appendChild(supItem("", "global cap", cap));
    } else {
      frag.appendChild(supItem("", "slots", capacity.slots + " / " + cap));
    }
    const providers = capacity.per_provider && typeof capacity.per_provider === "object" ? capacity.per_provider : {};
    for (const name of Object.keys(providers).slice(0, 20)) {
      const known = !sup.stale && isNum(providers[name]);
      frag.appendChild(supItem("sup-prov", clean(name, 60), known ? providers[name] : "unknown"));
    }

    const counts = view.queue && typeof view.queue === "object" ? view.queue : {};
    for (const k of ["ready", "running", "waiting", "attention"]) {
      const n = counts[k];
      const warn = k === "attention" && isNum(n) && n > 0;
      frag.appendChild(supItem(warn ? "sup-warn" : "", k, isNum(n) ? n : "unknown"));
    }
  }

  // a provider the supervisor holds back says why
  const health = view.provider_health && typeof view.provider_health === "object" ? view.provider_health : {};
  for (const name of Object.keys(health).slice(0, 20)) {
    const h = health[name] && typeof health[name] === "object" ? health[name] : {};
    let why = h.reason ? clean(h.reason, 200) : "no reason given";
    if (isNum(h.until)) why += " (until " + fmtUtc(h.until * 1000) + ")";
    frag.appendChild(supItem("sup-warn", "unhealthy " + clean(name, 60), why));
  }

  if (view.mode === "paused" && typeof view.pause_reason === "string" && view.pause_reason) {
    frag.appendChild(supItem("sup-warn", "paused", clean(view.pause_reason, 200)));
  }

  const hb = toMs(supHeartbeatAt(view));
  if (hb !== null && !sup.stale) frag.appendChild(supItem("", "heartbeat", ageText(hb)));

  const le = view.last_error;
  const leText = le && typeof le === "object" ? le.message || JSON.stringify(le) : le;
  if (leText) frag.appendChild(supItem("sup-warn sup-err", "last error", clean(leText, 400)));

  const text = frag.textContent;
  if (text !== sup.statusText) {
    sup.statusText = text;
    $("supervisor-status").replaceChildren(frag);
  }
  $("supervisor-status").setAttribute("aria-label", "Supervisor status: " + (running
    ? "desired " + clean(view.desired_mode || "unknown", 40) + ", phase " + clean(sup.ack ? sup.ack.phase : phase || "unknown", 40)
    : sup.seen ? "not running" : "unknown"));

  renderSupervisorControls(view);
  renderTokens();
  $("supervisor-retry-btn").hidden = !sup.stale;
  $("supervisor-retry-btn").disabled = false;
}

// renderTokens(): "This run", then "All time", then the planner on its own line.
// Counts are tokens only; a total with unknown usage is a lower bound.
function renderTokens() {
  const u = S.usage;
  const frag = document.createDocumentFragment();
  const runTokens = [u && u.run, S.supervisor && S.supervisor.run_tokens].filter(function (t) {
    return t && typeof t === "object" && isNum(t.total);
  })[0];
  let run;
  if (!S.sup.seen) run = "unknown";
  else if (!S.supervisor) run = "none (no supervisor running)";
  else run = tokensText(runTokens);
  frag.appendChild(el("span", "sup-item sup-tok", "This run: " + run));
  const budget = budgetText(S.supervisor && S.supervisor.run_budget);
  if (budget) {
    const b = el("span", "sup-item sup-tok sup-tok-budget", budget);
    b.title = clean(S.supervisor.run_budget.label || "counted toward limits.max_tokens", 80);
    frag.appendChild(b);
  }
  const allTime = el("span", "sup-item sup-tok", "All time: " + tokensText(u && u.all_time));
  const rest = shownUnknownTokens() ? null : tokenRemainder();   // else it is on the Unknown state header
  if (rest) allTime.title = rest.title;
  frag.appendChild(allTime);
  frag.appendChild(el("span", "sup-item sup-tok sup-tok-planner", "Planner: " + tokensText(u && u.planner)));
  if (u && u.error) frag.appendChild(el("span", "sup-item sup-warn", "usage: " + clean(u.error, 200)));
  const text = frag.textContent + (rest ? "\n" + rest.title : "");
  if (text !== S.sup.tokensText) {
    S.sup.tokensText = text;
    $("supervisor-tokens").replaceChildren(frag);
  }
  renderColumnTokens();
}

// setControl(btn, enabled, reason): a disabled control says why in its title and
// in a description it points at.
function setControl(btn, enabled, reason, whyId) {
  btn.disabled = !enabled;
  const why = $(whyId || btn.id + "-why");
  if (enabled) {
    btn.title = "";
    btn.removeAttribute("aria-describedby");
    why.textContent = "";
  } else {
    btn.title = reason;
    btn.setAttribute("aria-describedby", why.id);
    why.textContent = reason;
  }
}

function renderSupervisorControls(view) {
  const sup = S.sup;
  const desired = view.desired_mode;
  const phase = supPhase(view);
  const notRunning = sup.seen && !sup.stale && !S.supervisor;
  let gate = null;
  if (sup.stale) gate = "The supervisor status is unavailable (" + clean(sup.reason || "no connection", 120) + "). Retry the connection first.";
  else if (!sup.seen) gate = "No supervisor status yet.";
  else if (sup.busy) gate = "Another supervisor command is in flight.";
  const rest = gate || (notRunning ? "No supervisor is running: Start launches one." : null);
  const start = $("supervisor-start-btn");
  const pause = $("supervisor-pause-btn");
  const resume = $("supervisor-resume-btn");
  const stop = $("supervisor-stop-btn");
  // Start launches a supervisor when none runs, and resumes a paused one; it does nothing for a running one.
  let startWhy = gate;
  if (!startWhy && notRunning) startWhy = stuckStartGate();
  else if (!startWhy && (phase === "stopping" || phase === "draining" || phase === "cancelling")) startWhy = "The supervisor is stopping.";
  else if (!startWhy && !notRunning && desired === "running") startWhy = "A supervisor is already running.";
  setControl(start, !startWhy, startWhy);
  setControl(pause, !rest && desired === "running",
    rest || "Nothing is running to pause (desired mode: " + clean(desired || "unknown", 40) + ").");
  setControl(resume, !rest && desired === "paused",
    rest || "The session is not paused.");
  setControl(stop, !rest && desired !== "stopped",
    rest || "The supervisor is already stopped.");
  if (stop.disabled && sup.menuOpen) setStopMenu(false);
  start.classList.toggle("primary", false);
  pause.classList.toggle("primary", !pause.disabled);
  resume.classList.toggle("primary", pause.disabled && !resume.disabled);
  start.classList.toggle("primary", pause.disabled && resume.disabled && !start.disabled);
}

// The cards the board marks stuck; Start (with no supervisor running) waits for none.
function stuckCount() {
  const cards = S.board && Array.isArray(S.board.cards) ? S.board.cards : [];
  return cards.filter(function (c) { return c && c.stuck && typeof c.stuck === "object"; }).length;
}

// stuckStartGate(): why Start must wait when no supervisor runs, else null. The
// supervisor's own startup check would refuse while cards are stuck, while a
// run holds the lock, or before the board has any stuck result to go on.
function stuckStartGate() {
  const run = S.board && S.board.run ? S.board.run : {};
  if (typeof run.stuck_suppressed === "string" && run.stuck_suppressed) return clean(run.stuck_suppressed, 300);
  const n = stuckCount();
  if (n > 0) return stuckBannerText(n);
  if (run.stuck_known === false && run.stuck_error) return "stuck check failed: " + clean(run.stuck_error, 300);
  if (run.stuck_known === false && run.stuck_checking === true) return "checking for stuck cards…";
  return null;
}

function stuckBannerText(n) {
  return n + (n === 1 ? " stuck card — the supervisor will not start until it is resolved"
    : " stuck cards — the supervisor will not start until they are resolved");
}

// --- supervisor: commands -----------------------------------------------------

function expectedRevision() {
  const rev = S.supervisor && isNum(S.supervisor.revision) ? S.supervisor.revision : 0;
  return Math.max(rev, S.sup.hint);
}

const ACK_PHASE = { start: "starting", resume: "starting", pause: "pausing", stop: "stopping" };

// supCommand(kind, extra): kind is start|pause|resume|stop. The reply is an
// acknowledgement only: the page shows it as such until a poll observes it.
async function supCommand(kind, extra) {
  const sup = S.sup;
  if (sup.busy || sup.stale || !sup.seen) return;
  const key = kind + (extra && extra.mode ? ":" + extra.mode : "");
  hideNotice();
  sup.busy = true;
  renderSupervisor();
  const r = await runCommand(sup, key, "/api/supervisor/" + kind, function () {
    return Object.assign({ expected_revision: expectedRevision() }, extra || {});
  });
  sup.busy = false;
  const verb = kind === "stop" && extra ? "Stop (" + extra.mode + ")" : kind.charAt(0).toUpperCase() + kind.slice(1);
  let refetch = false;
  if (!r) {
    showNotice(verb + ": the board server did not answer. Click again to retry the same request.");
  } else if (r.status === 409) {
    const cur = r.data && (r.data.snapshot || r.data.current);
    ++sup.ackSeq;
    sup.ack = null;
    if (isSnapshot(cur)) adoptSnapshot(cur);
    // no supervisor answered the command: ask again what is running
    if (r.data && r.data.code === "not_running") refetch = true;
    showNotice(verb + " not applied, the supervisor state changed: " + msgText(r));
  } else if (!r.ok) {
    showNotice(verb + " failed: " + msgText(r));
  } else {
    const d = r.data || {};
    ++sup.ackSeq;
    if (isNum(d.state_revision)) sup.hint = d.state_revision;
    sup.ack = { kind: kind, phase: typeof d.phase === "string" && d.phase ? d.phase : ACK_PHASE[kind], state_revision: isNum(d.state_revision) ? d.state_revision : null, at: Date.now() };
  }
  renderSupervisor();
  if (refetch) supervisorTick();
}

function setStopMenu(open, focusFirst) {
  const menu = $("supervisor-stop-menu");
  S.sup.menuOpen = open;
  menu.hidden = !open;
  $("supervisor-stop-btn").setAttribute("aria-expanded", String(open));
  if (open && focusFirst) $("supervisor-drain-btn").focus();
}

function closeStopMenu() {
  setStopMenu(false);
  $("supervisor-stop-btn").focus();
}

function runStop(mode) {
  closeStopMenu();
  if (mode === "cancel" && !confirm("Cancel stops the active work now. Stop in cancel mode?")) return;
  return supCommand("stop", { mode: mode });
}

function menuItems() {
  return [$("supervisor-drain-btn"), $("supervisor-cancel-btn")];
}

function menuKey(e, item) {
  const items = menuItems();
  const i = items.indexOf(item);
  if (e.key === "ArrowDown" || e.key === "ArrowUp") {
    e.preventDefault();
    items[(i + (e.key === "ArrowDown" ? 1 : items.length - 1)) % items.length].focus();
  } else if (e.key === "Home" || e.key === "End") {
    e.preventDefault();
    items[e.key === "Home" ? 0 : items.length - 1].focus();
  } else if (e.key === "Escape") {
    e.preventDefault();
    closeStopMenu();
  } else if (e.key === "Tab") {
    setStopMenu(false);
  } else if (e.key === "Enter" || e.key === " ") {
    e.preventDefault();
    runStop(item === items[1] ? "cancel" : "drain");
  }
}

function bindSupervisor() {
  $("supervisor-start-btn").addEventListener("click", function () { supCommand("start"); });
  $("supervisor-pause-btn").addEventListener("click", function () { supCommand("pause"); });
  $("supervisor-resume-btn").addEventListener("click", function () { supCommand("resume"); });
  $("supervisor-retry-btn").addEventListener("click", function () { supervisorTick(); });

  const stop = $("supervisor-stop-btn");
  const menu = $("supervisor-stop-menu");
  stop.addEventListener("click", function () { setStopMenu(!S.sup.menuOpen); });
  stop.addEventListener("keydown", function (e) {
    if (e.key === "ArrowDown" || e.key === "Enter" || e.key === " ") {
      e.preventDefault(); // the click would toggle the menu a second time
      if (e.key === " ") setStopMenu(!S.sup.menuOpen);
      else setStopMenu(true, true);
    } else if (e.key === "Escape" && S.sup.menuOpen) {
      e.preventDefault();
      closeStopMenu();
    }
  });
  stop.addEventListener("keyup", function (e) {
    if (e.key === " ") e.preventDefault();
  });
  menu.addEventListener("keydown", function (e) {
    if (e.key === "Escape") {
      e.preventDefault();
      closeStopMenu();
    }
  });
  menuItems().forEach(function (item) {
    item.addEventListener("keydown", function (e) { menuKey(e, item); });
  });
  $("supervisor-drain-btn").addEventListener("click", function () { runStop("drain"); });
  $("supervisor-cancel-btn").addEventListener("click", function () { runStop("cancel"); });
  document.addEventListener("click", function (e) {
    if (S.sup.menuOpen && !menu.contains(e.target) && !stop.contains(e.target)) setStopMenu(false);
  });
}

// --- card: activity and token drill-down --------------------------------------

// The board's card carries activity: {action, elapsed_seconds} while a supervisor action runs on it.
function cardActivityLine(c) {
  const a = c.activity;
  if (!a || typeof a !== "object") return "";
  return "activity: " + clean(a.action, 60) + " · " + fmtDuration(a.elapsed_seconds);
}

function clearCardUsage() {
  $("dr-usage-sec").hidden = true;
  $("dr-usage-total").textContent = "";
  $("dr-usage-cols").replaceChildren();
}

async function loadCardUsage(d) {
  if (!d || d.n === null) return;
  const seq = ++d.usageSeq;
  let r;
  try {
    r = await api("GET", "/api/cards/" + d.n + "/usage");
  } catch (e) {
    r = null;
  }
  if (S.drawer !== d || seq !== d.usageSeq) return;
  // a failed read keeps what is showing (clearDrawer emptied it for a new card): never a wrong figure, never a blank
  if (r && r.ok) renderCardUsage(r.data);
}

// renderCardUsage(u): the drawer's drill-down, columns then actions. A count the
// ledger could not read is "unknown"; the log is a reference, shown as text.
function renderCardUsage(u) {
  const columns = u && Array.isArray(u.columns) ? u.columns : [];
  $("dr-usage-sec").hidden = false;
  $("dr-usage-total").textContent = "Total: " + tokensText(u && u.totals);
  const ol = document.createDocumentFragment();
  for (const col of columns.slice(0, 30)) {
    if (!col || typeof col !== "object") continue;
    const li = el("li", "dr-usage-col");
    const head = el("div", "dr-usage-col-head");
    head.appendChild(el("span", "dr-usage-col-name", clean(col.column || "unknown column", 60)));
    head.appendChild(el("span", "dr-usage-col-total", tokensText(col.totals)));
    li.appendChild(head);
    const ul = el("ul", "dr-usage-actions");
    for (const a of (Array.isArray(col.actions) ? col.actions : []).slice(0, 200)) {
      if (!a || typeof a !== "object") continue;
      const row = el("li", "dr-usage-action");
      row.appendChild(el("span", "dr-usage-what", [a.action, a.role, a.model].map(function (v) { return clean(v || "unknown", 80); }).join(" · ")));
      row.appendChild(el("span", "dr-usage-counts", "input " + countText(a.input) + " · output " + countText(a.output) +
        " · cache read " + countText(a.cache_read) + " · cache write " + countText(a.cache_write)));
      row.appendChild(el("span", "dr-usage-log", a.log ? "log " + clean(a.log, 200) : "no log"));
      ul.appendChild(row);
    }
    li.appendChild(ul);
    ol.appendChild(li);
  }
  if (!ol.children.length) ol.appendChild(el("li", "dr-usage-none", "No usage recorded for this card yet."));
  $("dr-usage-cols").replaceChildren(ol);
}

// --- start -------------------------------------------------------------------

function init() {
  // the supervisor panel appears only once detection has answered
  $("supervisor").hidden = true;
  $("plan-btn").addEventListener("click", function () { openPlanner(); });
  $("new-card-btn").addEventListener("click", function () { openNewCard(); });
  $("toast").addEventListener("click", hideToast);
  document.addEventListener("visibilitychange", function () {
    if (!document.hidden) fetchBoard();
  });
  bindSupervisor();
  bindDrawer();
  bindImport();
  bindPlanner();
  fetchBoard().then(drawerFromUrl);
  detectSupervisor();
}

init();
