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

printf '\npassed: %s  failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
