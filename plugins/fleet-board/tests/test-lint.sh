#!/usr/bin/env bash
#
# Plain-bash tests for /fleet-board:lint (skills/lint/SKILL.md and scripts/lint.sh).
# Offline: gh is a stub. Card bodies are written at run time.
#
# Usage: bash plugins/fleet-board/tests/test-lint.sh

set -uo pipefail
unset CDPATH FLEET_BOARD_CONFIG || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN="$SCRIPT_DIR/.."
SKILL="$PLUGIN/skills/lint/SKILL.md"
SCRIPT="$PLUGIN/scripts/lint.sh"

PASS=0
FAIL=0
CLEANUP_DIRS=()
cleanup() { for d in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do rm -rf "$d" 2>/dev/null || true; done; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s: %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "expected '$3' in: $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) fail "$1" "did not expect '$3' in: $2" ;; *) pass "$1" ;; esac; }

# ---------------------------------------------------------------- skill file
echo "# skill file"
if [ -f "$SKILL" ]; then
  fm="$(awk 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{exit} NR>1{print}' "$SKILL")"
  has "SKILL.md has name: lint" "$fm" "name: lint"
  has "SKILL.md has a description" "$fm" "description: "
  has "SKILL.md is user-invocable: true" "$fm" "user-invocable: true"
  has "SKILL.md runs lint.sh" "$(cat "$SKILL")" "lint.sh"
else
  fail "SKILL.md exists" "no $SKILL"
fi
if [ -f "$SCRIPT" ]; then
  has "lint.sh reuses card-lint.sh" "$(cat "$SCRIPT")" "card-lint.sh"
else
  fail "lint.sh exists" "no $SCRIPT"
fi

# ---------------------------------------------------------------- sandbox
SB="$(mktemp -d)"; CLEANUP_DIRS+=("$SB")
ROOT="$SB/root"; STUBS="$SB/stubs"; BODIES="$SB/bodies"
mkdir -p "$ROOT" "$STUBS"
git -C "$ROOT" init -q -b main
git -C "$ROOT" config user.email t@example.com
git -C "$ROOT" config user.name T
printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\n' > "$ROOT/.fleet-board.yml"
mkdir -p "$ROOT/src"
echo x > "$ROOT/src/real.js"
git -C "$ROOT" add -A
git -C "$ROOT" commit -q -m initial

# the board store of ROOT holds card 7 (not 404); gh is never needed
mkdir -p "$ROOT/.fleet-board/cards"
echo 8 > "$ROOT/.fleet-board/next"
jq -n '{number: 7, title: "t", body: "", acceptance: ["x"], blocked_by: [], state: "backlog", labels: [], next_comment_id: 1, comments: []}' \
  > "$ROOT/.fleet-board/cards/7.json"
printf '#!/usr/bin/env bash\necho "gh must not be called: $*" >&2\nexit 99\n' > "$STUBS/gh"
chmod +x "$STUBS/gh"

newset() { rm -rf "$BODIES"; mkdir -p "$BODIES"; }
card() { printf '%b' "$2" > "$BODIES/$1.md"; }
run_lint() {
  OUT="$(cd "$ROOT" && PATH="$STUBS:$PATH" bash "$SCRIPT" --bodies "$BODIES" "$@" 2>"$SB/err")"
  RC=$?
  ERR="$(cat "$SB/err")"
}

GOOD='## Acceptance\n- clamp(5, 0, 3) returns 3\n'

echo "# passing card"
newset; card 1 "$GOOD"
run_lint
check "clean card exits 0" "$RC" "0"
check "clean card prints nothing" "$OUT" ""

echo "# untestable-bullet"
for w in manual visually looks; do
  newset; card 1 "## Acceptance\n- clamp returns 3\n- the slider $w right\n"
  run_lint
  check "'$w' exits 1" "$RC" "1"
  has "'$w' reports untestable-bullet" "$OUT" "untestable-bullet"
  has "'$w' names the card" "$OUT" "#1"
  has "'$w' names the bullet" "$OUT" "the slider $w right"
  hasnt "'$w' spares the clean bullet" "$OUT" "clamp returns 3"
done

echo "# reuse of card-lint rules"
newset; card 1 "## Why\nnothing\n"
run_lint
check "no-heading exits 1" "$RC" "1"
has "no-heading comes from card-lint.sh" "$OUT" "no-heading"

echo "# dependency-cycle"
newset
card 1 "$GOOD\n## Depends on\n- #2\n"
card 2 "$GOOD\n## Depends on\n- #1\n"
card 3 "$GOOD\n## Depends on\n- #1\n"
run_lint
check "cycle exits 1" "$RC" "1"
has "cycle reports dependency-cycle" "$OUT" "dependency-cycle"
cyc="$(printf '%s\n' "$OUT" | grep dependency-cycle | head -1)"
has "cycle line names card 1" "$cyc" "#1"
has "cycle line names card 2" "$cyc" "#2"
check "card 3 is not in the cycle" "$(printf '%s\n' "$OUT" | grep dependency-cycle | grep -c '^#3:')" "0"

echo "# unresolved-dependency"
newset; card 1 "$GOOD\n## Depends on\n- #404\n"
run_lint
check "unresolved exits 1" "$RC" "1"
has "unresolved reports the rule" "$OUT" "unresolved-dependency"
has "unresolved names the reference" "$OUT" "#404"
newset; card 1 "$GOOD\n## Depends on\n- #7\n"
run_lint
check "an existing dependency passes" "$RC" "0"
newset; card 1 "$GOOD\n## Depends on\n- #2\n"; card 2 "$GOOD"
run_lint
check "a dependency inside the set passes" "$RC" "0"

echo "# missing-file"
newset; card 1 "$GOOD\n## Scope\n- edit \`src/gone.js\` and \`src/real.js\`\n"
run_lint
check "missing file exits 1" "$RC" "1"
has "missing file reports the rule" "$OUT" "missing-file"
has "missing file names the path" "$OUT" "src/gone.js"
hasnt "existing file is not reported" "$OUT" "src/real.js"
newset; card 1 "$GOOD\n## Scope\n- edit \`src/real.js\`\n"
run_lint
check "existing file passes" "$RC" "0"

echo "# missing-file: a path in an acceptance item (board path)"
jq -n '{number: 9, title: "t", body: "Prose only.\n", acceptance: ["`src/gone.js` exports clamp", "`src/real.js` is untouched"], blocked_by: [], state: "backlog", labels: [], next_comment_id: 1, comments: []}' \
  > "$ROOT/.fleet-board/cards/9.json"
BOUT="$(cd "$ROOT" && PATH="$STUBS:$PATH" bash "$SCRIPT" 9 2>"$SB/err")"; BRC=$?
check "board card: a missing path in an acceptance item exits 1" "$BRC" "1"
has "board card: missing-file names the path from the acceptance field" "$BOUT" "src/gone.js"
hasnt "board card: an existing path in an acceptance item is not reported" "$BOUT" "src/real.js"
rm -f "$ROOT/.fleet-board/cards/9.json"

echo "# missing-file: ## Creates heading, not create/new/add wording"
newset; card 1 "$GOOD\n## Creates\n- \`src/fresh.js\`\n"
run_lint
check "path under ## Creates without create wording exits 0" "$RC" "0"
hasnt "path under ## Creates is not flagged" "$OUT" "src/fresh.js"
newset; card 1 "$GOOD\n## Scope\n- we will create \`src/fresh.js\`\n"
run_lint
check "create wording outside ## Creates no longer skips the check" "$RC" "1"
newset; card 1 "$GOOD\n## Creates\n- \`src/fresh.js\`\n\n## Scope\n- edit \`src/gone.js\`\n"
run_lint
check "path outside ## Creates exits 1" "$RC" "1"
has "path outside ## Creates is flagged with the path" "$OUT" "src/gone.js is not on main"
hasnt "## Creates path still not flagged beside a flagged one" "$OUT" "src/fresh.js"
check "lint.sh has no create/new/add word-list skip" "$(grep -cE 'create\|new\|add' "$SCRIPT")" "0"
check "lint.sh missing-file check names no create/new/adds word list" "$(grep -cE '\(create|\|new\||adds\?' "$SCRIPT")" "0"

echo "# card arguments"
newset
card 1 "## Acceptance\n- the slider looks right\n"
card 2 "$GOOD"
run_lint 2
check "only the named card is linted" "$RC" "0"
run_lint 1
check "the named bad card fails" "$RC" "1"

# ---------------------------------------------------------------- board mode
echo "# board mode (the issue fixtures become local cards: routes-store.sh)"
FG="$SB/fakegh"; mkdir -p "$FG/bin" "$FG/r"
ln -s "$SCRIPT_DIR/fake-gh.sh" "$FG/bin/gh"
mk_issue() { jq -n --arg b "$2" --arg l "$3" --argjson n "$1" '{number:$n,title:"t",html_url:"x",body:$b,labels:[{name:$l}]}' > "$FG/r/issue$1.json"; }
mk_issue 21 "$(printf '## Acceptance\n- the slider looks right\n')" fleet:ready
mk_issue 22 "$(printf '## Acceptance\n- clamp returns 3\n')" fleet:backlog
mk_issue 23 "$(printf '## Acceptance\n- the slider looks right\n')" fleet:in_review
echo '[]' > "$FG/r/comments.json"; echo '[]' > "$FG/r/empty.json"
echo '[{"number":21,"title":"t","url":"x","labels":[{"name":"fleet:ready"}]}]' > "$FG/r/ready.json"
echo '[{"number":22,"title":"t","url":"x","labels":[{"name":"fleet:backlog"}]}]' > "$FG/r/backlog.json"
echo '{"login":"bot"}' > "$FG/r/user.json"
{
  printf 'api user\t0\t%s\n' "$FG/r/user.json"
  for n in 21 22 23; do
    printf 'api repos/acme/toy/issues/%s\t0\t%s\n' "$n" "$FG/r/issue$n.json"
    printf 'api --paginate repos/acme/toy/issues/%s/comments\t0\t%s\n' "$n" "$FG/r/comments.json"
  done
  printf 'issue list --repo acme/toy --label fleet:ready *\t0\t%s\n' "$FG/r/ready.json"
  printf 'issue list --repo acme/toy --label fleet:backlog *\t0\t%s\n' "$FG/r/backlog.json"
} > "$FG/routes"
run_board() {
  FLEET_BOARD_USER="$(bash "$SCRIPT_DIR/routes-store.sh" "$FG/routes" "$ROOT")"; export FLEET_BOARD_USER
  OUT="$(cd "$ROOT" && FAKE_GH_DIR="$FG" FAKE_GH_ROUTES="$FG/routes" PATH="$FG/bin:$PATH" bash "$SCRIPT" "$@" 2>"$SB/err")"
  RC=$?
}
run_board
check "no arguments: exit 1 when a Ready card fails" "$RC" "1"
has "no arguments: lints the Ready card" "$OUT" "#21"
hasnt "no arguments: does not lint other columns" "$OUT" "#23"
run_board 22
check "argument 22 (Backlog, clean) exits 0" "$RC" "0"
check "argument 22 prints nothing" "$OUT" ""
run_board 21
check "argument 21 exits 1" "$RC" "1"
has "argument 21 reports untestable-bullet" "$OUT" "untestable-bullet"
run_board 23
has "an explicit card outside Ready/Backlog is linted" "$OUT" "#23"

# a failing Backlog card must show up in the no-argument run
mk_issue 24 "$(printf '## Acceptance\n- the slider looks right\n')" fleet:backlog
echo '[{"number":22,"title":"t","url":"x","labels":[{"name":"fleet:backlog"}]},{"number":24,"title":"t","url":"x","labels":[{"name":"fleet:backlog"}]}]' > "$FG/r/backlog.json"
{
  printf 'api repos/acme/toy/issues/24\t0\t%s\n' "$FG/r/issue24.json"
  printf 'api --paginate repos/acme/toy/issues/24/comments\t0\t%s\n' "$FG/r/comments.json"
} >> "$FG/routes"
run_board
has "no arguments: lints a failing Backlog card" "$OUT" "#24"
hasnt "no arguments: clean Backlog card 22 stays silent" "$OUT" "#22"

# ---------------------------------------------------------------- local backend
echo "# local cards: board.repo refs read the card files; gh exits 99"
LR="$SB/localroot"; LSTUB="$SB/stub99"
mkdir -p "$LR/.fleet-board/cards" "$LSTUB"
git -C "$LR" init -q -b main
git -C "$LR" config user.email t@example.com
git -C "$LR" config user.name T
printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\n' > "$LR/.fleet-board.yml"
git -C "$LR" add .fleet-board.yml
git -C "$LR" commit -q -m initial
echo 3 > "$LR/.fleet-board/next"
# lcard <n> <sectioned body>: a local card whose Acceptance bullets and board-repo
# Depends on refs are stored in the fields (a card read on local always carries them)
lcard() {
  local acc dep
  acc="$(printf '%s\n' "$2" | awk '/^## Acceptance/{s=1;next} /^##/{s=0} s&&/^- /{sub(/^- /,"");print}' | jq -R -s -c 'split("\n") | map(select(length > 0))')"
  dep="$(printf '%s\n' "$2" | awk '/^## Depends on/{s=1;next} /^##/{s=0} s&&/^- /{sub(/^- /,"");print}' | { grep -E '^(acme/toy)?#[0-9]+$' || true; } | sed 's/.*#//' | jq -R -s -c 'split("\n") | map(select(length > 0) | tonumber) | unique')"
  jq -n --argjson n "$1" --argjson a "$acc" --argjson d "$dep" '{number: $n, title: "t", body: "", acceptance: $a, blocked_by: $d, state: "ready", labels: [], next_comment_id: 1, comments: [], created_at: "2026-11-06T00:00:00Z"}' \
    > "$LR/.fleet-board/cards/$1.json"
}
lcard 2 "$(printf '## Acceptance\n- clamp returns 3\n')"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/calls"\nexit 99\n' "$LSTUB" > "$LSTUB/gh"
chmod +x "$LSTUB/gh"
run_local() {
  OUT="$(cd "$LR" && PATH="$LSTUB:$PATH" bash "$SCRIPT" "$@" 2>"$SB/err")"
  RC=$?
}
lcard 1 "$(printf '## Acceptance\n- clamp returns 3\n\n## Depends on\n- #2\n- acme/toy#2\n')"
run_local 1
check "local: #2 and acme/toy#2 resolve from the card file" "$RC" "0"
check "local: prints nothing" "$OUT" ""
lcard 1 "$(printf '## Acceptance\n- clamp returns 3\n\n## Depends on\n- #9\n- acme/toy#8\n')"
run_local 1
check "local: a missing card file exits 1" "$RC" "1"
has "local: #9 is unresolved" "$OUT" "#9 does not exist"
has "local: acme/toy#8 is unresolved" "$OUT" "acme/toy#8 does not exist"
check "local: no gh call for this repo's refs" "$(cat "$LSTUB/calls" 2>/dev/null)" ""
lcard 1 "$(printf '## Acceptance\n- clamp returns 3\n\n## Depends on\n- other/repo#5\n')"
run_local 1
check "local: an outside ref is not a field, so lint makes no gh call for it" "$(cat "$LSTUB/calls" 2>/dev/null)" ""
lfcard() { # n acceptance-json blocked_by-json body
  jq -n --argjson n "$1" --argjson a "$2" --argjson d "$3" --arg b "$4" '{number: $n, title: "t", body: $b, acceptance: $a, blocked_by: $d, state: "ready", labels: [], next_comment_id: 1, comments: [], created_at: "2026-11-06T00:00:00Z"}' \
    > "$LR/.fleet-board/cards/$1.json"
}
lfcard 1 '[]' '[]' "$(printf '## Acceptance\n- stale body bullet\n')"
run_local 1
check "local fields: acceptance [] fails whatever the body says" "$RC" "1"
has "local fields: acceptance [] is reported" "$OUT" "#1: empty-acceptance"
lfcard 1 '["clamp returns 3"]' '[2]' ""
run_local 1
check "local fields: items and blocked_by pass" "$RC" "0"
lfcard 1 '["clamp returns 3"]' '[2]' ""
lfcard 2 '["clamp returns 3"]' '[1]' ""
run_local 1 2
check "local fields: a blocked_by cycle fails" "$RC" "1"
has "local fields: the cycle is reported" "$OUT" "dependency-cycle"
lcard 2 "$(printf '## Acceptance\n- clamp returns 3\n')"
newset; card 1 "$GOOD\n## Depends on\n- #2\n"
OUT="$(cd "$LR" && PATH="$LSTUB:$PATH" bash "$SCRIPT" --bodies "$BODIES" 2>"$SB/err")"; RC=$?
check "local --bodies: #2 resolves from the card file" "$RC" "0"

echo
echo "passed: $PASS failed: $FAIL"
[ "$FAIL" -eq 0 ]
