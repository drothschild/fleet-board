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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
