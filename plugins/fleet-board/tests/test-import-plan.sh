#!/usr/bin/env bash
#
# Plain-bash tests for /fleet-board:import-plan (skills/import-plan/SKILL.md and
# scripts/import-plan.sh). Offline: gh is a stub that logs its calls. The fixture
# spec, plans and the grouped cards file are written at run time.
# No framework, no dependencies beyond POSIX tools, jq and git.
#
# Usage: bash plugins/fleet-board/tests/test-import-plan.sh

set -uo pipefail
unset CDPATH FLEET_BOARD_CONFIG || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN="$SCRIPT_DIR/.."
SKILL="$PLUGIN/skills/import-plan/SKILL.md"
SCRIPT="$PLUGIN/scripts/import-plan.sh"

PASS=0
FAIL=0
CLEANUP_DIRS=()
cleanup() { for d in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do rm -rf "$d" 2>/dev/null || true; done; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s: %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi; }

# ---------------------------------------------------------------- SKILL.md
echo "# skill file"
if [ -f "$SKILL" ]; then
  fm="$(awk 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{exit} NR>1{print}' "$SKILL")"
  case "$fm" in *"name: import-plan"*) pass "SKILL.md has name: import-plan" ;; *) fail "SKILL.md has name: import-plan" "missing" ;; esac
  case "$fm" in *"description: "*) pass "SKILL.md has a description" ;; *) fail "SKILL.md has a description" "missing" ;; esac
  case "$fm" in *"user-invocable: true"*) pass "SKILL.md is user-invocable: true" ;; *) fail "SKILL.md is user-invocable: true" "missing" ;; esac
else
  fail "SKILL.md exists" "no $SKILL"
fi

# ---------------------------------------------------------------- sandbox
SB="$(mktemp -d)"; CLEANUP_DIRS+=("$SB")
ROOT="$SB/root"; STUBS="$SB/stubs"; D="$SB/gh"
mkdir -p "$ROOT" "$STUBS" "$D/bodies"
git -C "$ROOT" init -q
cat > "$ROOT/.fleet-board.yml" <<'EOF'
board:
  repo: acme/api
worktrees:
  dir: ".wt"
EOF
ROOT_MAIN="$ROOT"

# gh stub: logs "<args>" per call; issue create prints a URL with a global counter
cat > "$STUBS/gh" <<'EOF'
#!/usr/bin/env bash
D="${FAKE_D:?}"
echo "$*" >> "$D/calls.log"
case "$1 $2" in
  "issue create")
    n=$(( $(cat "$D/counter" 2>/dev/null || echo 100) + 1 )); echo "$n" > "$D/counter"
    repo=""; bf=""; prev=""
    for a in "$@"; do
      [ "$prev" = "--repo" ] && repo="$a"
      [ "$prev" = "--body-file" ] && bf="$a"
      prev="$a"
    done
    cp "$bf" "$D/bodies/$n.md"
    echo "https://github.com/$repo/issues/$n" ;;
  "label list")
    repo=""; prev=""
    for a in "$@"; do [ "$prev" = "--repo" ] && repo="$a"; prev="$a"; done
    f="$D/labels/${repo//\//_}"
    [ -f "$f" ] && cat "$f" ;;
  "project item-add")
    echo "{\"id\":\"ITEM_$(cat "$D/counter")\"}" ;;
  "repo view") echo main ;;
  "api repos/"*)
    # gh api repos/<owner>/<name>/contents/<path>?ref=<branch>: ok only when the
    # fixture file $D/files/<owner>_<name>/<path> exists
    rp="${2#repos/}"; rp="${rp%%\?*}"
    rrepo="${rp%%/contents/*}"; rfile="${rp#*/contents/}"
    [ -f "$D/files/${rrepo//\//_}/$rfile" ] || exit 1 ;;
  *) : ;;
esac
EOF
chmod +x "$STUBS/gh"

# ---------------------------------------------------------------- fixtures
cat > "$SB/spec.md" <<'EOF'
# Rate limits
The API enforces per-key limits and the web app shows them.
EOF
cat > "$SB/plan-api.md" <<'EOF'
## Task 1: limits endpoint
Interfaces: Produces `POST /limits`.
- [ ] test: POST /limits returns 201 with {"limit": 100}
EOF
cat > "$SB/plan-web.md" <<'EOF'
## Task 1: limits UI
Interfaces: Consumes `POST /limits`. Produces `LimitsPanel`.
- [ ] test: panel renders "100 requests per minute"
## Task 2: docs
Interfaces: Consumes `LimitsPanel`.
- [ ] test: docs page lists the panel
EOF
# The grouped cards (the skill's output), deliberately listed dependents-first.
cat > "$SB/cards.json" <<'EOF'
{"cards":[
 {"key":"C","title":"Document rate limits","repo":"acme/web","labels":["docs"],
  "why":"Users need to find the limits.","scope":["docs/limits.md"],
  "acceptance":["The docs page lists the panel"],"consumes":["LimitsPanel"],"produces":[]},
 {"key":"B","title":"Add limits UI","repo":"acme/web","labels":["frontend"],
  "why":"Show the limit.","scope":["src/LimitsPanel.tsx"],
  "acceptance":["The panel renders \"100 requests per minute\""],"consumes":["POST /limits"],"produces":["LimitsPanel"]},
 {"key":"A","title":"Add limits endpoint","repo":"acme/api","labels":["backend"],
  "why":"Expose the limit.","scope":["src/limits.js"],
  "acceptance":["POST /limits returns 201 with {\"limit\": 100}"],"consumes":[],"produces":["POST /limits"]}
]}
EOF

# reset_gh: a fresh gh log, and (for the main sandbox) an empty local store
reset_gh() {
  rm -rf "$D"; mkdir -p "$D/bodies"
  if [ "$ROOT" = "$ROOT_MAIN" ]; then
    rm -rf "$ROOT/.fleet-board"; mkdir -p "$ROOT/.fleet-board/cards"; echo 1 > "$ROOT/.fleet-board/next"
  fi
}
run_import() { # <stdin-answer> args...
  local ans="$1"; shift
  OUT="$(cd "$ROOT" && printf '%s\n' "$ans" | FAKE_D="$D" PATH="$STUBS:$PATH" bash "$SCRIPT" "$@" 2>"$SB/err")"
  RC=$?
}
# card_of <title>: the number of the local card created with that title
card_of() {
  local f
  for f in "$ROOT/.fleet-board/cards/"*.json; do
    [ -e "$f" ] && [ "$(jq -r .title "$f")" = "$1" ] && { jq -r .number "$f"; return; }
  done
}
body_of() { # <title> -> a file holding the card's body as board-read.sh returns it
  local n; n="$(card_of "$1")"
  (cd "$ROOT" && bash "$PLUGIN/scripts/board-read.sh" "$n" 2>/dev/null) | jq -j '.body // ""' > "$D/bodies/$n.md"
  echo "$D/bodies/$n.md"
}
# cards_created: how many cards the store holds
cards_created() { ls "$ROOT/.fleet-board/cards/" 2>/dev/null | grep -c '\.json$' || true; }

# ---------------------------------------------------------------- dry run
echo "# dry run"
reset_gh
run_import "" "$SB/cards.json" --dry-run
check "dry run exits 0" "$RC" "0"
check "dry run table has one row per card" "$(printf '%s\n' "$OUT" | grep -c '^| ')" "4"  # header + 3 rows
for t in "Document rate limits" "Add limits UI" "Add limits endpoint"; do
  case "$OUT" in *"| $t "*) pass "dry run row for: $t" ;; *) fail "dry run row for: $t" "missing" ;; esac
done
header="$(printf '%s\n' "$OUT" | grep '^| ' | head -1)"
for c in Title Repo "Depends on" Labels; do
  case "$header" in *"$c"*) pass "dry run column: $c" ;; *) fail "dry run column: $c" "missing in '$header'" ;; esac
done
row_b="$(printf '%s\n' "$OUT" | grep '^| Add limits UI ')"
case "$row_b" in *acme/web*"Add limits endpoint"*frontend*) pass "dry run row shows repo, depends on and labels" ;; *) fail "dry run row shows repo, depends on and labels" "$row_b" ;; esac
check "dry run creates no issue" "$(cards_created)" "0"

# ---------------------------------------------------------------- confirmed run
echo "# confirmed run"
reset_gh
run_import "y" "$SB/cards.json"
check "confirmed run exits 0" "$RC" "0"
check "three issues created" "$(cards_created)" "3"
titles="$(for n in 1 2 3; do jq -r .title "$ROOT/.fleet-board/cards/$n.json" 2>/dev/null; done | paste -sd'|' -)"
check "issues are created in dependency order" "$titles" "Add limits endpoint|Add limits UI|Document rate limits"

for t in "Add limits endpoint" "Add limits UI" "Document rate limits"; do
  f="$(body_of "$t")"
  ok=yes
  for h in "## Why" "## Scope"; do grep -qx "$h" "$f" 2>/dev/null || ok=no; done
  check "body of '$t' has Why and Scope" "$ok" "yes"
  acc="$ROOT/.fleet-board/cards/$(card_of "$t").json"
  # the acceptance is the card's field now, not a body section
  bad="$(jq -r '[(.acceptance // [])[] | select(type != "string" or . == "" or startswith("- "))] | length' "$acc" 2>/dev/null)"
  check "every acceptance item of '$t' is a non-empty string without a '- ' prefix" "$bad" "0"
  n="$(jq -r '(.acceptance // []) | length' "$acc" 2>/dev/null)"
  [ "${n:-0}" -ge 1 ] && pass "'$t' has an acceptance item" || fail "'$t' has an acceptance item" "none"
done

# every card goes to the one local board, so a dependency is a blocked_by number
check "the dependent card is blocked by the endpoint card" "$(jq -c .blocked_by "$ROOT/.fleet-board/cards/$(card_of "Add limits UI").json" 2>/dev/null)" "[$(card_of "Add limits endpoint")]"
check "the chained card is blocked by the UI card" "$(jq -c .blocked_by "$ROOT/.fleet-board/cards/$(card_of "Document rate limits").json" 2>/dev/null)" "[$(card_of "Add limits UI")]"
check "the acceptance field holds the card's acceptance" "$(jq -c .acceptance "$ROOT/.fleet-board/cards/$(card_of "Add limits UI").json" 2>/dev/null)" '["The panel renders \"100 requests per minute\""]'
check "the stored body has no Acceptance section" "$(jq -r .body "$ROOT/.fleet-board/cards/1.json" 2>/dev/null | grep -c '^## Acceptance')" "0"
check "no #A_NUM placeholder in any body" "$(cat "$D"/bodies/*.md 2>/dev/null | grep -c '_NUM')" "0"

check "each card is in Backlog by default" "$(jq -r .state "$ROOT/.fleet-board/cards/"*.json | grep -c '^backlog$')" "3"

# ---------------------------------------------------------------- --status ready
echo "# --status ready"
reset_gh
run_import "y" "$SB/cards.json" --status ready
check "--status ready exits 0" "$RC" "0"
check "--status ready sets Ready" "$(jq -r .state "$ROOT/.fleet-board/cards/"*.json | grep -c '^ready$')" "3"

# ---------------------------------------------------------------- declined
echo "# confirmation"
reset_gh
run_import "no" "$SB/cards.json"
check "declined run exits 0" "$RC" "0"
check "declined run prints the table" "$(printf '%s\n' "$OUT" | grep -c '^| ')" "4"
if [ -s "$D/calls.log" ]; then fail "declined run leaves the gh log empty" "$(cat "$D/calls.log")"; else pass "declined run leaves the gh log empty"; fi
check "declined run creates no card" "$(cards_created)" "0"

# ---------------------------------------------------------------- dry run stops by itself
echo "# dry run with a yes answer"
reset_gh
run_import "y" "$SB/cards.json" --dry-run
check "dry run with a yes answer exits 0" "$RC" "0"
check "dry run with a yes answer creates no issue" "$(cards_created)" "0"

# ---------------------------------------------------------------- explained failures
echo "# cycle and unknown dependency"
printf '%s' '{"cards":[{"key":"a","title":"A","repo":"x/y","depends_on":["b"]},{"key":"b","title":"B","repo":"x/y","depends_on":["a"]}]}' > "$SB/cycle.json"
reset_gh
run_import "" "$SB/cycle.json" --dry-run
check "cycle exits 1" "$RC" "1"
case "$(cat "$SB/err")" in *"dependency cycle"*) pass "cycle error explains the reason" ;; *) fail "cycle error explains the reason" "$(cat "$SB/err")" ;; esac
printf '%s' '{"cards":[{"key":"a","title":"A","repo":"x/y","depends_on":["zzz"]}]}' > "$SB/unknown.json"
run_import "" "$SB/unknown.json" --dry-run
check "unknown dependency exits 1" "$RC" "1"
case "$(cat "$SB/err")" in *"unknown dependency: zzz"*) pass "unknown dependency error names the key" ;; *) fail "unknown dependency error names the key" "$(cat "$SB/err")" ;; esac

# ---------------------------------------------------------------- card linter
echo "# card linter"
printf '%s' '{"cards":[{"key":"a","title":"Good card","repo":"acme/api","acceptance":["POST /limits returns 201"]},{"key":"b","title":"Bad card","repo":"acme/api","acceptance":["The panel looks right"]}]}' > "$SB/badcards.json"
reset_gh
run_import "y" "$SB/badcards.json"
check "a failing card makes the import exit 1" "$RC" "1"
check "a failing card creates no issue" "$(cards_created)" "0"
case "$(cat "$SB/err") $OUT" in *untestable-bullet*) pass "the import names the lint rule" ;; *) fail "the import names the lint rule" "$(cat "$SB/err")" ;; esac
case "$(cat "$SKILL")" in *lint*) pass "SKILL.md mentions the linter" ;; *) fail "SKILL.md mentions the linter" "missing" ;; esac
# ---------------------------------------------------------------- cross-repo file check
echo "# cross-repo file check"
printf '%s' '{"cards":[{"key":"b","title":"Web card","repo":"acme/web","acceptance":["`src/web-only.js` exports a limits panel"]}]}' > "$SB/webfile.json"
reset_gh
mkdir -p "$D/files/acme_web/src"; : > "$D/files/acme_web/src/web-only.js"
run_import "" "$SB/webfile.json" --dry-run
check "file exists only in repo B: the missing-file check passes (exit 0)" "$RC" "0"
case "$(cat "$SB/err") $OUT" in *missing-file*) fail "file exists only in repo B: no missing-file violation" "$(cat "$SB/err")" ;; *) pass "file exists only in repo B: no missing-file violation" ;; esac
reset_gh
run_import "" "$SB/webfile.json" --dry-run
check "file absent from repo B: the check fails (exit 1)" "$RC" "1"
case "$(cat "$SB/err")" in *missing-file*"src/web-only.js"*"acme/web"*) pass "file absent from repo B: message names missing-file, the path and acme/web" ;; *) fail "file absent from repo B: message names missing-file, the path and acme/web" "$(cat "$SB/err")" ;; esac
check "import-plan.sh passes no flag that disables the file check" "$(grep -c -- '--no-file-check' "$SCRIPT")" "0"
# ---------------------------------------------------------------- parse
echo "# parse"
cat > "$SB/plan-parse.md" <<'EOP'
# Calc plan

## Task 1: Add calc

Files:
- src/calc.js
- Create src/index.js

Test steps:
- add(1, 2) returns 3
- add("a", 1) throws a TypeError

## Task 2: Add docs

Files:
- README.md

Test steps:
- README mentions `add`
EOP
cat > "$SB/plan-parse.expected.json" <<'EOP'
{"cards":[
{"title":"Add calc","scope":["src/calc.js","Create src/index.js"],"acceptance":["add(1, 2) returns 3","add(\"a\", 1) throws a TypeError"]},
{"title":"Add docs","scope":["README.md"],"acceptance":["README mentions `add`"]}
]}
EOP
bash "$SCRIPT" parse "$SB/plan-parse.md" > "$SB/parse1.out" 2> "$SB/parse1.err"; RC=$?
check "parse exits 0" "$RC" "0"
check "parse prints one card per task heading with title, scope, acceptance" \
  "$(jq -cS . "$SB/parse1.out" 2>/dev/null)" "$(jq -cS . "$SB/plan-parse.expected.json")"
bash "$SCRIPT" parse "$SB/plan-parse.md" > "$SB/parse2.out" 2>/dev/null
check "parse is deterministic: two runs print identical output" "$(cmp -s "$SB/parse1.out" "$SB/parse2.out" && echo same || echo differ)" "same"
printf '# Notes\n\nNo tasks here.\n' > "$SB/plan-empty.md"
bash "$SCRIPT" parse "$SB/plan-empty.md" > "$SB/parse3.out" 2> "$SB/parse3.err"; RC=$?
check "plan with no task headings exits 1" "$RC" "1"
case "$(cat "$SB/parse3.err")" in *"no task headings"*) pass "no-task error prints a message" ;; *) fail "no-task error prints a message" "$(cat "$SB/parse3.err")" ;; esac

# ---------------------------------------------------------------- a second local board
echo "# local board (acme/toy)"
ROOT_L="$SB/root-local"
mkdir -p "$ROOT_L/.fleet-board/cards"
git -C "$ROOT_L" init -q
echo 1 > "$ROOT_L/.fleet-board/next"
cat > "$ROOT_L/.fleet-board.yml" <<'EOF'
board:
  repo: acme/toy
worktrees:
  dir: ".wt"
EOF
cat > "$SB/cards-local.json" <<'EOF'
{"cards":[
 {"key":"b","title":"B","repo":"acme/toy","labels":["frontend"],
  "why":"Use the thing.","scope":["src/b.js"],
  "acceptance":["B uses the thing"],"consumes":["the thing"],"produces":[]},
 {"key":"a","title":"A","repo":"acme/toy","labels":["backend"],
  "why":"Make the thing.","scope":["src/a.js"],
  "acceptance":["A makes the thing"],"consumes":[],"produces":["the thing"]}
]}
EOF
ROOT_SAVED="$ROOT"; ROOT="$ROOT_L"
reset_gh
run_import "y" "$SB/cards-local.json" --status ready
check "local board: exits 0" "$RC" "0"
case "$OUT" in *"Created #1: A"*) pass "local board: prints Created #1: A" ;; *) fail "local board: prints Created #1: A" "$OUT $(cat "$SB/err")" ;; esac
case "$OUT" in *"Created #2: B"*) pass "local board: prints Created #2: B" ;; *) fail "local board: prints Created #2: B" "$OUT" ;; esac
check "local board: card 2 is blocked by card 1" "$(jq -c .blocked_by "$ROOT_L/.fleet-board/cards/2.json" 2>/dev/null)" "[1]"
check "local board: card 2's stored body has no Depends on section" "$(jq -r .body "$ROOT_L/.fleet-board/cards/2.json" 2>/dev/null | grep -c '^## Depends on')" "0"
check "local board: card 1 is in state ready" "$(jq -r .state "$ROOT_L/.fleet-board/cards/1.json" 2>/dev/null)" "ready"
check "local board: card 2 is in state ready" "$(jq -r .state "$ROOT_L/.fleet-board/cards/2.json" 2>/dev/null)" "ready"
check "local board: card labels are stored" "$(jq -c .labels "$ROOT_L/.fleet-board/cards/2.json" 2>/dev/null)" '["frontend"]'
check "local board: no gh issue create is called" "$(cat "$D/calls.log" 2>/dev/null | grep -c "^issue create")" "0"
cat > "$SB/cards-local-x.json" <<'EOF'
{"cards":[
 {"key":"b","title":"B2","repo":"acme/toy","labels":[],
  "why":"Use the thing.","scope":["src/b.js"],
  "acceptance":["B uses the thing"],"consumes":["the thing"],"produces":[]},
 {"key":"a","title":"A2","repo":"other/repo","labels":[],
  "why":"Make the thing.","scope":["src/a.js"],
  "acceptance":["A makes the thing"],"consumes":[],"produces":["the thing"]}
]}
EOF
reset_gh
run_import "y" "$SB/cards-local-x.json" --status ready
check "local board, other repo: exits 0" "$RC" "0"
check "local board, other repo: dependent card is blocked by card 3 on this board" "$(jq -c .blocked_by "$ROOT_L/.fleet-board/cards/4.json" 2>/dev/null)" "[3]"
check "local board, other repo: no ref names other/repo" "$(jq -r .body "$ROOT_L/.fleet-board/cards/4.json" 2>/dev/null | grep -c 'other/repo#')" "0"
ROOT="$ROOT_SAVED"

# ---------------------------------------------------------------- bare #N dependency
echo "# bare #N dependency"
cat > "$SB/cards-bare.json" <<'EOF'
{"cards":[
 {"key":"d","title":"Depends on five","repo":"acme/api","labels":[],
  "why":"Needs card five.","scope":["src/d.js"],
  "acceptance":["D works"],"depends_on":["#5"],"consumes":[],"produces":[]},
 {"key":"e","title":"Independent","repo":"acme/api","labels":[],
  "why":"Stands alone.","scope":["src/e.js"],
  "acceptance":["E works"],"consumes":[],"produces":[]}
]}
EOF
reset_gh
run_import "" "$SB/cards-bare.json" --dry-run
check "import-plan.sh --dry-run on a card with depends_on [\"#5\"] exits 0" "$RC" "0"
check "depends_on [\"#5\"] prints no unknown dependency error" "$(grep -c 'unknown dependency' "$SB/err")" "0"
reset_gh
run_import "y" "$SB/cards-bare.json" --status ready
check "creating a card with depends_on [\"#5\"] exits 0" "$RC" "0"
check "creating a card with depends_on [\"#5\"] sets its blocked_by to [5]" "$(jq -c .blocked_by "$ROOT/.fleet-board/cards/$(card_of "Depends on five").json" 2>/dev/null)" "[5]"
check "a card with depends_on [\"#5\"] is created even when listed before cards it does not depend on" "$(cards_created)" "2"
printf '%s' '{"cards":[{"key":"a","title":"A","repo":"x/y","depends_on":["nosuchkey"]}]}' > "$SB/nosuch.json"
reset_gh
run_import "" "$SB/nosuch.json" --dry-run
check "depends_on [\"nosuchkey\"] still exits 1" "$RC" "1"
case "$(cat "$SB/err")" in *"unknown dependency: nosuchkey"*) pass "depends_on [\"nosuchkey\"] still fails with unknown dependency: nosuchkey" ;; *) fail "depends_on [\"nosuchkey\"] still fails with unknown dependency: nosuchkey" "$(cat "$SB/err")" ;; esac

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
