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

echo "$FAIL failing groups"
[ "$FAIL" -eq 0 ]
