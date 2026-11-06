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
  backend: github-projects
  repo: acme/api
  project_number: 3
worktrees:
  dir: ".wt"
EOF
mkdir -p "$ROOT/.wt/.cache"
cat > "$ROOT/.wt/.cache/projects.json" <<'EOF'
{"project_id":"PID","field_id":"FID","options":{"Backlog":"OPT_BACKLOG","Ready":"OPT_READY"}}
EOF

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

reset_gh() { rm -rf "$D"; mkdir -p "$D/bodies"; }
run_import() { # <stdin-answer> args...
  local ans="$1"; shift
  OUT="$(cd "$ROOT" && printf '%s\n' "$ans" | FAKE_D="$D" PATH="$STUBS:$PATH" bash "$SCRIPT" "$@" 2>"$SB/err")"
  RC=$?
}
body_of() { # <title> -> body file of the issue created with that title
  local n
  n="$(awk -v t="$1" 'BEGIN{i=100} /^issue create /{i++; if (index($0, "--title " t " ")) {print i; exit}}' "$D/calls.log")"
  echo "$D/bodies/$n.md"
}

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
check "dry run creates no issue" "$(cat "$D/calls.log" 2>/dev/null | grep -c "^issue create")" "0"

# ---------------------------------------------------------------- confirmed run
echo "# confirmed run"
reset_gh
run_import "y" "$SB/cards.json"
check "confirmed run exits 0" "$RC" "0"
check "three issues created" "$(grep -c '^issue create' "$D/calls.log")" "3"
titles="$(grep '^issue create ' "$D/calls.log" | sed 's/.*--title \(.*\) --body-file.*/\1/' | paste -sd'|' -)"
check "issues are created in dependency order" "$titles" "Add limits endpoint|Add limits UI|Document rate limits"

for t in "Add limits endpoint" "Add limits UI" "Document rate limits"; do
  f="$(body_of "$t")"
  ok=yes
  for h in "## Why" "## Scope" "## Acceptance"; do grep -qx "$h" "$f" 2>/dev/null || ok=no; done
  check "body of '$t' has Why, Scope and Acceptance" "$ok" "yes"
  bad="$(awk '/^## Acceptance/{s=1;next} /^## /{s=0} s && NF && $0 !~ /^- /' "$f" 2>/dev/null | wc -l | tr -d ' ')"
  check "every Acceptance line of '$t' starts with '- '" "$bad" "0"
  n="$(awk '/^## Acceptance/{s=1;next} /^## /{s=0} s && /^- /' "$f" 2>/dev/null | wc -l | tr -d ' ')"
  [ "$n" -ge 1 ] && pass "'$t' has an Acceptance bullet" || fail "'$t' has an Acceptance bullet" "none"
done

fb="$(body_of "Add limits UI")"
grep -qx -- '- acme/api#101' "$fb" 2>/dev/null && pass "cross-repo dependency is '- acme/api#101'" || fail "cross-repo dependency is '- acme/api#101'" "$(cat "$fb" 2>/dev/null)"
fc="$(body_of "Document rate limits")"
grep -qx -- '- acme/web#102' "$fc" 2>/dev/null && pass "chained dependency is '- acme/web#102'" || fail "chained dependency is '- acme/web#102'" "$(cat "$fc" 2>/dev/null)"
check "no #A_NUM placeholder in any body" "$(cat "$D"/bodies/*.md 2>/dev/null | grep -c '_NUM')" "0"

check "each issue is added to the project" "$(grep -c '^project item-add 3 ' "$D/calls.log")" "3"
check "each issue is set to Backlog by default" "$(grep '^project item-edit' "$D/calls.log" | grep -c -- '--single-select-option-id OPT_BACKLOG')" "3"

# ---------------------------------------------------------------- --status ready
echo "# --status ready"
reset_gh
run_import "y" "$SB/cards.json" --status ready
check "--status ready exits 0" "$RC" "0"
check "--status ready sets Ready" "$(grep '^project item-edit' "$D/calls.log" | grep -c -- '--single-select-option-id OPT_READY')" "3"

# ---------------------------------------------------------------- declined
echo "# confirmation"
reset_gh
run_import "no" "$SB/cards.json"
check "declined run exits 0" "$RC" "0"
check "declined run prints the table" "$(printf '%s\n' "$OUT" | grep -c '^| ')" "4"
if [ -s "$D/calls.log" ]; then fail "declined run leaves the gh log empty" "$(cat "$D/calls.log")"; else pass "declined run leaves the gh log empty"; fi

# ---------------------------------------------------------------- dry run stops by itself
echo "# dry run with a yes answer"
reset_gh
run_import "y" "$SB/cards.json" --dry-run
check "dry run with a yes answer exits 0" "$RC" "0"
check "dry run with a yes answer creates no issue" "$(cat "$D/calls.log" 2>/dev/null | grep -c "^issue create")" "0"

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
check "a failing card creates no issue" "$(cat "$D/calls.log" 2>/dev/null | grep -c "^issue create")" "0"
case "$(cat "$SB/err") $OUT" in *untestable-bullet*) pass "the import names the lint rule" ;; *) fail "the import names the lint rule" "$(cat "$SB/err")" ;; esac
case "$(cat "$SKILL")" in *lint*) pass "SKILL.md mentions the linter" ;; *) fail "SKILL.md mentions the linter" "missing" ;; esac
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

# ---------------------------------------------------------------- labels backend
echo "# labels backend"
ROOT_P="$ROOT"
ROOT="$SB/root-labels"; mkdir -p "$ROOT"; git -C "$ROOT" init -q
cat > "$ROOT/.fleet-board.yml" <<'EOF2'
board:
  backend: github-labels
  repo: acme/api
EOF2
reset_gh
run_import "y" "$SB/cards.json"
check "labels board: import-plan exits 0 instead of refusing" "$RC" "0"
check "labels board: three issues created" "$(grep -c '^issue create' "$D/calls.log" 2>/dev/null)" "3"
check "labels board: each created issue carries the fleet:backlog label" "$(grep '^issue create' "$D/calls.log" 2>/dev/null | grep -c -- '--label fleet:backlog')" "3"
check "labels board: stubbed gh log has no project item call" "$(grep -c '^project ' "$D/calls.log" 2>/dev/null)" "0"
reset_gh
run_import "y" "$SB/cards.json" --status ready
check "labels board: --status ready labels each issue fleet:ready" "$(grep '^issue create' "$D/calls.log" 2>/dev/null | grep -c -- '--label fleet:ready')" "3"
# ---------------------------------------------------------------- labels must exist
echo "# labels must exist before import"
reset_gh
run_import "y" "$SB/cards.json"
check "labels board, label missing: exits 0" "$RC" "0"
lc="$(grep -n '^label create fleet:backlog --repo acme/api' "$D/calls.log" | head -1 | cut -d: -f1)"
ic="$(grep -n '^issue create --repo acme/api' "$D/calls.log" | head -1 | cut -d: -f1)"
if [ -n "$lc" ] && [ -n "$ic" ] && [ "$lc" -lt "$ic" ]; then pass "labels board: gh label create fleet:backlog --repo acme/api is logged before that repo's first gh issue create"; else fail "labels board: gh label create fleet:backlog --repo acme/api is logged before that repo's first gh issue create" "label line '$lc', issue line '$ic'"; fi
check "labels board: label created once for acme/api, not once per card" "$(grep -c '^label create fleet:backlog --repo acme/api' "$D/calls.log")" "1"
check "labels board: label created once for acme/web though it has two cards" "$(grep -c '^label create fleet:backlog --repo acme/web' "$D/calls.log")" "1"
check "labels board: label created for exactly the two repos" "$(grep -c '^label create ' "$D/calls.log")" "2"
reset_gh
mkdir -p "$D/labels"
printf 'fleet:backlog\nbug\n' > "$D/labels/acme_api"
printf 'fleet:backlog\n' > "$D/labels/acme_web"
run_import "y" "$SB/cards.json"
check "labels board, label exists: exits 0" "$RC" "0"
check "labels board, label exists: no gh label create call is made" "$(grep -c '^label create ' "$D/calls.log")" "0"
reset_gh
run_import "y" "$SB/cards.json" --status ready
check "labels board, --status ready: fleet:ready is created in each repo" "$(grep -c '^label create fleet:ready --repo ' "$D/calls.log")" "2"
check "labels board, --status ready: fleet:backlog is not created" "$(grep -c '^label create fleet:backlog' "$D/calls.log")" "0"
ROOT="$ROOT_P"
reset_gh
run_import "y" "$SB/cards.json"
check "projects board: no gh label create call is made" "$(grep -c '^label create ' "$D/calls.log")" "0"

# ---------------------------------------------------------------- local backend
echo "# local backend"
ROOT_L="$SB/root-local"
mkdir -p "$ROOT_L/.fleet-board/cards"
git -C "$ROOT_L" init -q
echo 1 > "$ROOT_L/.fleet-board/next"
cat > "$ROOT_L/.fleet-board.yml" <<'EOF'
board:
  backend: local
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
check "local board: card 2 body lists the dependency as acme/toy#1" "$(jq -r .body "$ROOT_L/.fleet-board/cards/2.json" 2>/dev/null | grep -c -- '^- acme/toy#1')" "1"
check "local board: card 2 body has a Depends on section" "$(jq -r .body "$ROOT_L/.fleet-board/cards/2.json" 2>/dev/null | grep -c '^## Depends on')" "1"
check "local board: card 1 is in state ready" "$(jq -r .state "$ROOT_L/.fleet-board/cards/1.json" 2>/dev/null)" "ready"
check "local board: card 2 is in state ready" "$(jq -r .state "$ROOT_L/.fleet-board/cards/2.json" 2>/dev/null)" "ready"
check "local board: card labels are stored" "$(jq -c .labels "$ROOT_L/.fleet-board/cards/2.json" 2>/dev/null)" '["frontend"]'
check "local board: no gh issue create is called" "$(cat "$D/calls.log" 2>/dev/null | grep -c "^issue create")" "0"
check "local board: the gh stub was never invoked" "$([ -e "$D/calls.log" ] && wc -l < "$D/calls.log" | tr -d ' ' || echo 0)" "0"

# board-create.sh printing no number: import-plan stops with failed to create
SCRIPTS_COPY="$SB/scripts-copy"
cp -R "$PLUGIN/scripts" "$SCRIPTS_COPY"
printf '#!/usr/bin/env bash\necho "{}"\n' > "$SCRIPTS_COPY/board-create.sh"
reset_gh
OUT="$(cd "$ROOT_L" && printf 'y\n' | FAKE_D="$D" PATH="$STUBS:$PATH" bash "$SCRIPTS_COPY/import-plan.sh" "$SB/cards-local.json" --status ready 2>"$SB/err")"
RC=$?
check "local board, no number printed: exits 1" "$RC" "1"
case "$(cat "$SB/err")" in *"failed to create: A"*) pass "local board, no number printed: stderr says failed to create: A" ;; *) fail "local board, no number printed: stderr says failed to create: A" "$(cat "$SB/err")" ;; esac
case "$OUT" in *"Created #"*) fail "local board, no number printed: nothing reported created" "$OUT" ;; *) pass "local board, no number printed: nothing reported created" ;; esac
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
check "local board, other repo: dependent card cites the board repo, acme/toy#3" "$(jq -r .body "$ROOT_L/.fleet-board/cards/4.json" 2>/dev/null | grep -c -- '^- acme/toy#3')" "1"
check "local board, other repo: no ref names other/repo" "$(jq -r .body "$ROOT_L/.fleet-board/cards/4.json" 2>/dev/null | grep -c 'other/repo#')" "0"
ROOT="$ROOT_SAVED"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
