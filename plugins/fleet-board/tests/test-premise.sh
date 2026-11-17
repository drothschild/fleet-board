#!/usr/bin/env bash
#
# Plain-bash tests for the card premise stamp (premise.sh, the local adapter
# stamping, fl_default_head, fl_premise_json, fl_scope_text).
#
# Usage: bash plugins/fleet-board/tests/test-premise.sh

set -uo pipefail
unset CDPATH
unset FLEET_BOARD_ACTOR FLEET_BOARD_CONFIG FLEET_BOARD_LOCK_WAIT FB_CFG_FOR || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPTS="$SCRIPT_DIR/../scripts"
USER="${USER:-$(id -un)}"
export USER FLEET_BOARD_USER="${FLEET_BOARD_USER:-$USER}"

PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi; }

printf -- '- it works\n' > "$WORK/acc0.md"
OLD_SHA="1111111111111111111111111111111111111111"

# mkrepo <name> [branch]: a clone of a bare origin whose default branch is <branch> (main).
# Prints the clone's path. Sets origin/HEAD.
mkrepo() {
  local name="$1" br="${2:-main}" bare="$WORK/$1.git" repo="$WORK/$1"
  git init -q --bare "$bare"
  git init -q -b "$br" "$WORK/$1-seed"
  git -C "$WORK/$1-seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
  git -C "$WORK/$1-seed" remote add origin "$bare"
  git -C "$WORK/$1-seed" push -q origin "$br" 2>/dev/null
  git -C "$bare" symbolic-ref HEAD "refs/heads/$br"
  git clone -q "$bare" "$repo" 2>/dev/null
  git -C "$repo" remote set-head origin "$br" >/dev/null 2>&1
  setup_store "$repo"
  printf '%s\n' "$repo"
}

setup_store() {
  local repo="$1"
  printf 'board:\n  repo: "o/r"\ncommands:\n  test_one: "node --test {file}"\ntest_paths: ["test/**/*.test.js"]\n' > "$repo/.fleet-board.yml"
  mkdir -p "$repo/.fleet-board/cards"
  printf '2\n' > "$repo/.fleet-board/next"
}

# in <repo> <cmd...>: runs a script with the repo as cwd and its config.
inrepo() {
  local repo="$1"; shift
  ( cd "$repo" && FLEET_BOARD_CONFIG="$repo/.fleet-board.yml" "$@" )
}

BODY_SCOPE='## Why
x

## Scope
- `src/a.js`

## Notes
n
'

mkcard() { # <repo> <title> [state] -> card number
  local repo="$1" f="$WORK/body.md"
  printf '%s' "$BODY_SCOPE" > "$f"
  inrepo "$repo" bash "$SCRIPTS/board-create.sh" "$2" "$f" --acceptance-file "$WORK/acc0.md" ${3:+--state "$3"} 2>/dev/null | jq -r .number
}

card() { jq -c . "$1/.fleet-board/cards/$2.json"; }
seed() { # <repo> <n> <by>: stores a stamp with the old sha
  local f="$1/.fleet-board/cards/$2.json"
  jq --arg s "$OLD_SHA" --arg b "$3" '.premise = {sha: $s, at: "2020-01-01T00:00:00Z", by: $b}' "$f" > "$f.t" && mv "$f.t" "$f"
}
pj() { jq -c ".premise | $3" "$1/.fleet-board/cards/$2.json"; }
head_of() { git -C "$1" rev-parse "$2"; }

REPO="$(mkrepo main-repo)"
HEAD_MAIN="$(head_of "$REPO" refs/remotes/origin/main)"

echo "Test: create stamps"
N="$(mkcard "$REPO" "stamped")"
eq "create: premise.sha is the default branch head" "$(pj "$REPO" "$N" .sha)" "\"$HEAD_MAIN\""
eq "create: premise.by is create" "$(pj "$REPO" "$N" .by)" '"create"'
N="$(FLEET_BOARD_ACTOR=supervisor mkcard "$REPO" "stamped by supervisor")"
eq "supervisor create: premise.by is create" "$(pj "$REPO" "$N" .by)" '"create"'

echo "Test: create without a remote"
NOREM="$WORK/noremote"; git init -q -b main "$NOREM"; setup_store "$NOREM"
N="$(mkcard "$NOREM" "no remote")"
eq "no origin ref: premise is null" "$(jq -c '.premise' "$NOREM/.fleet-board/cards/$N.json")" null
eq "no origin ref: card exists" "$(jq -r .number "$NOREM/.fleet-board/cards/$N.json")" "$N"

echo "Test: edit"
printf -- '- changed acceptance\n' > "$WORK/acc.md"
N="$(mkcard "$REPO" "edit acceptance")"; seed "$REPO" "$N" create
inrepo "$REPO" bash "$SCRIPTS/adapters/local/edit.sh" "$N" --acceptance-file "$WORK/acc.md" >/dev/null 2>&1
eq "edit of acceptance: by is edit" "$(pj "$REPO" "$N" .by)" '"edit"'
eq "edit of acceptance: sha is current head" "$(pj "$REPO" "$N" .sha)" "\"$HEAD_MAIN\""

printf '## Why\nx\n\n## Scope\n- `src/b.js`\n\n## Notes\nn\n' > "$WORK/body-newscope.md"
N="$(mkcard "$REPO" "edit scope")"; seed "$REPO" "$N" create
inrepo "$REPO" bash "$SCRIPTS/adapters/local/edit.sh" "$N" --body-file "$WORK/body-newscope.md" >/dev/null 2>&1
eq "edit of Scope in body: by is edit" "$(pj "$REPO" "$N" .by)" '"edit"'

printf 'new title\n' > "$WORK/title.txt"
N="$(mkcard "$REPO" "edit title")"; seed "$REPO" "$N" create
inrepo "$REPO" bash "$SCRIPTS/adapters/local/edit.sh" "$N" --title-file "$WORK/title.txt" >/dev/null 2>&1
eq "edit of title only: stamp unchanged" "$(pj "$REPO" "$N" .)" "{\"sha\":\"$OLD_SHA\",\"at\":\"2020-01-01T00:00:00Z\",\"by\":\"create\"}"

printf '## Why\nchanged prose\n\n## Scope\n- `src/a.js`\n\n## Notes\nother\n' > "$WORK/body-samescope.md"
N="$(mkcard "$REPO" "edit body same scope")"; seed "$REPO" "$N" create
inrepo "$REPO" bash "$SCRIPTS/adapters/local/edit.sh" "$N" --body-file "$WORK/body-samescope.md" >/dev/null 2>&1
eq "edit of body with the same Scope: stamp unchanged" "$(pj "$REPO" "$N" .by)" '"create"'
eq "edit of body with the same Scope: body did change" "$(jq -r '.body | contains("changed prose")' "$REPO/.fleet-board/cards/$N.json")" true

echo "Test: move"
N="$(mkcard "$REPO" "move in")"; seed "$REPO" "$N" create
inrepo "$REPO" bash "$SCRIPTS/board-move.sh" "$N" ready >/dev/null 2>&1
eq "move into ready: by is move" "$(pj "$REPO" "$N" .by)" '"move"'
eq "move into ready: sha is current head" "$(pj "$REPO" "$N" .sha)" "\"$HEAD_MAIN\""
seed "$REPO" "$N" create
inrepo "$REPO" bash "$SCRIPTS/board-move.sh" "$N" ready >/dev/null 2>&1
eq "move ready to ready: stamp unchanged" "$(pj "$REPO" "$N" .by)" '"create"'
inrepo "$REPO" bash "$SCRIPTS/board-move.sh" "$N" blocked >/dev/null 2>&1
eq "move out of ready: stamp unchanged" "$(pj "$REPO" "$N" .by)" '"create"'

echo "Test: supervisor actor"
N="$(mkcard "$REPO" "supervisor move")"; seed "$REPO" "$N" create
FLEET_BOARD_ACTOR=supervisor inrepo "$REPO" bash "$SCRIPTS/board-move.sh" "$N" ready >/dev/null 2>&1
eq "supervisor move into ready: stamp unchanged" "$(pj "$REPO" "$N" .by)" '"create"'
eq "supervisor move into ready: card did move" "$(jq -r .state "$REPO/.fleet-board/cards/$N.json")" ready
N="$(mkcard "$REPO" "supervisor edit")"; seed "$REPO" "$N" create
FLEET_BOARD_ACTOR=supervisor inrepo "$REPO" bash "$SCRIPTS/adapters/local/edit.sh" "$N" --acceptance-file "$WORK/acc.md" >/dev/null 2>&1
eq "supervisor edit of acceptance: stamp unchanged" "$(pj "$REPO" "$N" .by)" '"create"'
eq "supervisor edit of acceptance: acceptance did change" "$(jq -c .acceptance "$REPO/.fleet-board/cards/$N.json")" '["changed acceptance"]'

echo "Test: premise.sh"
N="$(mkcard "$REPO" "premise verbs")"; seed "$REPO" "$N" create
inrepo "$REPO" bash "$SCRIPTS/premise.sh" stamp "$N" --by check >/dev/null 2>&1
eq "stamp --by check: exit 0 and by is check" "$(pj "$REPO" "$N" .by)" '"check"'
S="$(printf 'ab%.0s' $(seq 1 20))"
inrepo "$REPO" bash "$SCRIPTS/premise.sh" stamp "$N" --by check --sha "$S" >/dev/null 2>&1
eq "stamp --sha: writes that sha" "$(pj "$REPO" "$N" .sha)" "\"$S\""
inrepo "$REPO" bash "$SCRIPTS/premise.sh" stamp "$N" --by nonsense >/dev/null 2>&1
eq "stamp unknown --by: exit 2" "$?" 2
inrepo "$REPO" bash "$SCRIPTS/premise.sh" stamp "$N" --by check --sha xyz >/dev/null 2>&1
eq "stamp malformed --sha: exit 2" "$?" 2
inrepo "$REPO" bash "$SCRIPTS/premise.sh" stamp 99999 --by check >/dev/null 2>&1
eq "stamp unreadable card: exit 3" "$?" 3
f="$REPO/.fleet-board/cards/$N.json"
jq '.premise = "yes"' "$f" > "$f.t" && mv "$f.t" "$f"
eq "show of \"yes\" prints null" "$(inrepo "$REPO" bash "$SCRIPTS/premise.sh" show "$N" 2>/dev/null)" null
jq '.premise = {sha: "abc"}' "$f" > "$f.t" && mv "$f.t" "$f"
eq "show of {sha:abc} prints null" "$(inrepo "$REPO" bash "$SCRIPTS/premise.sh" show "$N" 2>/dev/null)" null

echo "Test: board-read returns the stamp"
seed "$REPO" "$N" check
eq "board-read.sh premise equals the stored object" \
  "$(inrepo "$REPO" bash "$SCRIPTS/board-read.sh" "$N" 2>/dev/null | jq -c .premise)" \
  "{\"sha\":\"$OLD_SHA\",\"at\":\"2020-01-01T00:00:00Z\",\"by\":\"check\"}"

echo "Test: default branch is not main"
TR="$(mkrepo trunk-repo trunk)"
HEAD_TRUNK="$(head_of "$TR" refs/remotes/origin/trunk)"
N="$(mkcard "$TR" "trunk")"
eq "origin/HEAD -> trunk: sha is trunk's head" "$(pj "$TR" "$N" .sha)" "\"$HEAD_TRUNK\""

echo "Test: fl_scope_text"
SCOPE_OUT="$(
  . "$SCRIPTS/board-lib.sh"; . "$SCRIPTS/adapters/local/local-lib.sh"
  fl_scope_text "$(printf '## Why\n\n```\n## Scope\n- `fake.js`\n```\n\n## Scope\n- `real.js`\n\n## Other\nz\n')"
)"
eq "fl_scope_text: takes the real section, not the fenced line" "$SCOPE_OUT" '- `real.js`'
SCOPE_NONE="$(
  . "$SCRIPTS/board-lib.sh"; . "$SCRIPTS/adapters/local/local-lib.sh"
  fl_scope_text "$(printf '## Why\n\n```\n## Scope\n- `fake.js`\n```\n')"
)"
eq "fl_scope_text: a fenced heading alone gives nothing" "$SCOPE_NONE" ""

echo "Test: premise.sh moved"
# mkcard2 <repo> <title> <body file> <acceptance file> -> card number
mkcard2() {
  inrepo "$1" bash "$SCRIPTS/board-create.sh" "$2" "$3" --acceptance-file "$4" 2>/dev/null | jq -r .number
}
# stampat <repo> <n> <sha>
stampat() {
  local f="$1/.fleet-board/cards/$2.json"
  jq --arg s "$3" '.premise = {sha: $s, at: "2020-01-01T00:00:00Z", by: "create"}' "$f" > "$f.t" && mv "$f.t" "$f"
}
# push_commit <repo name> <path>: a commit touching <path> on the default branch, fetched into the clone
push_commit() {
  local seed="$WORK/$1-seed"
  mkdir -p "$seed/$(dirname "$2")"
  printf 'change %s\n' "$RANDOM" > "$seed/$2"
  git -C "$seed" add "$2"
  git -C "$seed" -c user.email=t@t -c user.name=t commit -q -m "touch $2"
  git -C "$seed" push -q origin main 2>/dev/null
  git -C "$WORK/$1" fetch -q origin 2>/dev/null
  git -C "$WORK/$1" remote set-head origin main >/dev/null 2>&1
}
moved() { inrepo "$1" bash "$SCRIPTS/premise.sh" moved "$2" 2>/dev/null; }

NOREM="$WORK/noremote-moved"; git init -q -b main "$NOREM"; setup_store "$NOREM"
N="$(mkcard "$NOREM" "no remote moved")"
eq "moved, no origin ref: moved false, reason null, head null" "$(moved "$NOREM" "$N" | jq -c '[.moved, .reason, .head]')" '[false,null,null]'

MR="$(mkrepo moved-repo)"
N="$(mkcard "$MR" "no stamp")"
jq 'del(.premise)' "$MR/.fleet-board/cards/$N.json" > "$MR/.fleet-board/cards/$N.json.t" && mv "$MR/.fleet-board/cards/$N.json.t" "$MR/.fleet-board/cards/$N.json"
eq "moved, no stamp: moved true" "$(moved "$MR" "$N" | jq -c .moved)" true
eq "moved, no stamp: reason" "$(moved "$MR" "$N" | jq -c .reason)" '"no premise stamp"'
eq "moved, no stamp: head is the default head" "$(moved "$MR" "$N" | jq -c .head)" "\"$(head_of "$MR" refs/remotes/origin/main)\""
N="$(mkcard "$MR" "unknown commit")"; stampat "$MR" "$N" 0000000000000000000000000000000000000000
eq "moved, unknown commit: moved true" "$(moved "$MR" "$N" | jq -c .moved)" true
eq "moved, unknown commit: reason" "$(moved "$MR" "$N" | jq -c .reason)" '"premise stamp commit is unknown"'

BASE_SHA="$(head_of "$MR" refs/remotes/origin/main)"
N_SAME="$(mkcard "$MR" "head equals stamp")"; stampat "$MR" "$N_SAME" "$BASE_SHA"
eq "moved, head equals stamp: moved false" "$(moved "$MR" "$N_SAME" | jq -c '[.moved, .reason]')" '[false,null]'

printf '## Why\nx\n\n## Scope\n- `src/`\n' > "$WORK/body-dir.md"
printf -- '- `test/a.test.js` passes\n' > "$WORK/acc-path.md"
printf -- '- `npm test -- --grep add` passes\n- `curl localhost:3000/health` prints ok\n' > "$WORK/acc-cmds.md"
N_FILE="$(mkcard "$MR" "scope file")"; stampat "$MR" "$N_FILE" "$BASE_SHA"
N_DIR="$(mkcard2 "$MR" "scope dir" "$WORK/body-dir.md" "$WORK/acc0.md")"; stampat "$MR" "$N_DIR" "$BASE_SHA"
N_ACC="$(mkcard2 "$MR" "acceptance path" "$WORK/body-newscope.md" "$WORK/acc-path.md")"; stampat "$MR" "$N_ACC" "$BASE_SHA"
N_CMD="$(mkcard2 "$MR" "acceptance commands" "$WORK/body-newscope.md" "$WORK/acc-cmds.md")"; stampat "$MR" "$N_CMD" "$BASE_SHA"

push_commit moved-repo docs/x.md
eq "moved, unrelated file: moved false" "$(moved "$MR" "$N_FILE" | jq -c '[.moved, .reason]')" '[false,null]'
eq "moved, unrelated file: head is the new default head" "$(moved "$MR" "$N_FILE" | jq -c .head)" "\"$(head_of "$MR" refs/remotes/origin/main)\""

push_commit moved-repo src/a.js
eq "moved by a Scope file: reason" "$(moved "$MR" "$N_FILE" | jq -c '[.moved, .reason]')" '[true,"ground moved: src/a.js"]'
eq "moved by a Scope file: paths holds the changed path" "$(moved "$MR" "$N_FILE" | jq -c '.paths | index("src/a.js") != null')" true

push_commit moved-repo src/deep/b.js
eq "moved by a Scope directory: a file under it" "$(moved "$MR" "$N_DIR" | jq -c .moved)" true
eq "moved by a Scope directory: reason starts with ground moved" "$(moved "$MR" "$N_DIR" | jq -r '.reason | startswith("ground moved: src/")')" true

push_commit moved-repo test/a.test.js
eq "moved by an acceptance path in backticks" "$(moved "$MR" "$N_ACC" | jq -c .moved)" true

# acceptance spans that are commands add no path; the Scope file src/b.js did not change
eq "acceptance command spans: moved is false" "$(moved "$MR" "$N_CMD" | jq -c .moved)" false
inrepo "$MR" bash "$SCRIPTS/premise.sh" moved "$N_CMD" >/dev/null 2>&1
eq "acceptance command spans: exit 0" "$?" 0
eq "acceptance command spans: paths holds neither command" \
  "$(moved "$MR" "$N_CMD" | jq -c '[.paths[] | select(test("npm|curl|[ ]"))] | length')" 0
inrepo "$MR" bash "$SCRIPTS/premise.sh" moved 99999 >/dev/null 2>&1
eq "moved, unreadable card: exit 1" "$?" 1

printf '\npassed: %s  failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
