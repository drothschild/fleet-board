#!/usr/bin/env bash
#
# Plain-bash tests: board.css keeps every phone rule in one max-width 720px block.
# Usage: bash plugins/fleet-board/tests/test-board-mobile-css.sh

set -uo pipefail
unset CDPATH
DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
command -v node >/dev/null 2>&1 || { echo "skipped: node not on PATH"; exit 0; }
REPO="$(git -C "$DIR" rev-parse --show-toplevel)"
REL="plugins/fleet-board/scripts/board-web/static/board.css"
BASE="$(git -C "$REPO" show "origin/main:$REL" 2>/dev/null)" || { echo "skipped: no origin/main"; exit 0; }

CSS_FILE="$REPO/$REL" BASE_CSS="$BASE" node - <<'EOF'
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const css = fs.readFileSync(process.env.CSS_FILE, "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
const base = process.env.BASE_CSS.replace(/\/\*[\s\S]*?\*\//g, "");

// Returns {blocks: [body...], rest: css without those @media blocks}.
function phoneBlocks(src) {
  const blocks = []; let rest = ""; let i = 0;
  const re = /@media\s*\(max-width:\s*720px\)\s*\{/g;
  let m;
  while ((m = re.exec(src))) {
    rest += src.slice(i, m.index);
    let depth = 1, j = re.lastIndex;
    while (depth && j < src.length) { const c = src[j++]; if (c === "{") depth++; else if (c === "}") depth--; }
    blocks.push(src.slice(re.lastIndex, j - 1));
    i = j; re.lastIndex = j;
  }
  return {blocks, rest: rest + src.slice(i)};
}
const norm = (s) => s.replace(/\s+/g, " ").trim();
const cur = phoneBlocks(css), old = phoneBlocks(base);
let fails = 0;
function test(name, fn) { try { fn(); console.log("ok - " + name); } catch (e) { fails++; console.log("not ok - " + name + "\n  " + e.message); } }

test("board.css has exactly one @media (max-width: 720px) block", () => {
  assert.equal(cur.blocks.length, 1);
});
test("no rule outside a media query changes the desktop layout compared with origin/main", () => {
  assert.equal(norm(cur.rest), norm(old.rest));
});
test("every phone rule from origin/main is still inside the one block", () => {
  const all = norm(cur.blocks.join(" "));
  for (const b of old.blocks) for (const rule of b.split("}").map(norm).filter(Boolean).filter((r) => !r.startsWith(".col, .stack")))
    assert.ok(all.includes(rule + " }") || all.includes(rule), "missing phone rule: " + rule);
});
test("inside that block the board uses scroll-snap-type: x mandatory", () => {
  assert.match(cur.blocks[0], /scroll-snap-type:\s*x mandatory/);
});
test("inside that block the board shows one column per screen width", () => {
  const rule = cur.blocks[0].split("}").find((r) => /\.col\b/.test(r.split("{")[0]) && /flex(-basis)?:/.test(r));
  assert.ok(rule, "no .col flex rule in the phone block");
  assert.match(rule, /flex(-basis)?:\s*(0 0 )?100(%|vw)/);
});
test("inside that block interactive controls are at least 44px tall", () => {
  const rules = cur.blocks[0].split("}");
  const rule = rules.find((r) => /\.btn\b/.test(r.split("{")[0]) && /min-height:\s*44px|height:\s*44px/.test(r));
  assert.ok(rule, "no .btn 44px rule in the phone block");
});
process.exit(fails ? 1 : 0);
EOF
