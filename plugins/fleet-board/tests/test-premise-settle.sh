#!/usr/bin/env bash
#
# Plain-bash tests for premise-settle.sh (propose, approve, confirm, reject) and the
# local move.sh clearing a proposal when a person moves a card out of Blocked.
#
# Usage: bash plugins/fleet-board/tests/test-premise-settle.sh

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

printf -- '- old item one\n- old item two\n' > "$WORK/acc0.md"
PROP_HEAD="2222222222222222222222222222222222222222"

mkrepo() {
  local name="$1" bare="$WORK/$1.git" repo="$WORK/$1"
  git init -q --bare "$bare"
  git init -q -b main "$WORK/$1-seed"
  git -C "$WORK/$1-seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
  git -C "$WORK/$1-seed" remote add origin "$bare"
  git -C "$WORK/$1-seed" push -q origin main 2>/dev/null
  git -C "$bare" symbolic-ref HEAD refs/heads/main
  git clone -q "$bare" "$repo" 2>/dev/null
  git -C "$repo" remote set-head origin main >/dev/null 2>&1
  printf 'board:\n  repo: "o/r"\ncommands:\n  test_one: "node --test {file}"\ntest_paths: ["test/**/*.test.js"]\n' > "$repo/.fleet-board.yml"
  mkdir -p "$repo/.fleet-board/cards"
  printf '2\n' > "$repo/.fleet-board/next"
  printf '%s\n' "$repo"
}

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
mkcard() { # <repo> <title> <state> [body-file] -> card number
  local repo="$1" f="${4:-$WORK/body.md}" n
  [ -n "${4:-}" ] || printf '%s' "$BODY_SCOPE" > "$f"
  n="$(inrepo "$repo" bash "$SCRIPTS/board-create.sh" "$2" "$f" --acceptance-file "$WORK/acc0.md" --state ready 2>/dev/null | jq -r .number)"
  if [ "$3" != ready ]; then inrepo "$repo" bash "$SCRIPTS/board-move.sh" "$n" "$3" >/dev/null 2>&1; fi
  printf '%s\n' "$n"
}
cardf() { printf '%s/.fleet-board/cards/%s.json' "$1" "$2"; }
settle() { local repo="$1"; shift; inrepo "$repo" bash "$SCRIPTS/premise-settle.sh" "$@"; }
decisions() { local f="$1/.fleet-board/premise-decisions.jsonl"; if [ -f "$f" ]; then jq -sc 'map(.decision)' "$f"; else echo '[]'; fi; }

REWRITE="$WORK/rewrite.json"
jq -n --arg h "$PROP_HEAD" '{kind: "rewrite", scope: "- `src/new.js`\n- `test/new.test.js`", acceptance: ["new item one", "new item two"], summary: "the file moved", head: $h}' > "$REWRITE"
CLOSE="$WORK/close.json"
jq -n --arg h "$PROP_HEAD" '{kind: "close", evidence: [{item: 1, command: "true", output: "ok"}, {item: 2, command: "true", output: "ok"}], head: $h}' > "$CLOSE"

REPO="$(mkrepo r1)"
MAIN_HEAD="$(git -C "$REPO" rev-parse refs/remotes/origin/main)"

echo "Test: propose"
N="$(mkcard "$REPO" "rewrite me" blocked)"
jq '.blocked_by = [1]' "$(cardf "$REPO" "$N")" > "$WORK/t" && mv "$WORK/t" "$(cardf "$REPO" "$N")"
settle "$REPO" propose "$N" "$REWRITE" >/dev/null 2>&1
eq "propose rewrite: exit 0" "$?" 0
eq "propose rewrite: stores the kind" "$(jq -r .proposal.kind "$(cardf "$REPO" "$N")")" rewrite
eq "propose rewrite: stores the head" "$(jq -r .proposal.head "$(cardf "$REPO" "$N")")" "$PROP_HEAD"
eq "propose rewrite: stamps the time" "$(jq -r '.proposal.at | length > 0' "$(cardf "$REPO" "$N")")" true

echo "Test: approve"
BEFORE_BODY="$(jq -r .body "$(cardf "$REPO" "$N")")"
settle "$REPO" approve "$N" >/dev/null 2>&1
eq "approve: exit 0" "$?" 0
F="$(cardf "$REPO" "$N")"
eq "approve: lands in ready" "$(jq -r .state "$F")" ready
eq "approve: acceptance replaced" "$(jq -c .acceptance "$F")" '["new item one","new item two"]'
eq "approve: Scope replaced" "$(jq -r '.body | contains("src/new.js") and (contains("src/a.js") | not)' "$F")" true
eq "approve: other sections kept" "$(jq -r '.body | contains("## Notes") and contains("## Why")' "$F")" true
eq "approve: blocked_by kept" "$(jq -c .blocked_by "$F")" '[1]'
eq "approve: proposal cleared" "$(jq -c .proposal "$F")" null
eq "approve: stamp by approve" "$(jq -r .premise.by "$F")" approve
eq "approve: stamp sha is the proposal's" "$(jq -r .premise.sha "$F")" "$PROP_HEAD"

printf '## Why\nno scope here\n' > "$WORK/noscope.md"
N2="$(mkcard "$REPO" "no scope" blocked "$WORK/noscope.md")"
settle "$REPO" propose "$N2" "$REWRITE" >/dev/null 2>&1
settle "$REPO" approve "$N2" >/dev/null 2>&1
eq "approve a body with no Scope: exit 0" "$?" 0
eq "approve a body with no Scope: gains the section" "$(jq -r '.body | contains("## Scope") and contains("src/new.js") and contains("no scope here")' "$(cardf "$REPO" "$N2")")" true

echo "Test: approve refusals"
snap() { jq -S 'del(.updated_at)' "$(cardf "$REPO" "$1")"; }
N3="$(mkcard "$REPO" "ready card" ready)"
settle "$REPO" propose "$N3" "$REWRITE" >/dev/null 2>&1
S="$(snap "$N3")"
OUT="$(settle "$REPO" approve "$N3" 2>&1)"; RC=$?
eq "approve on a Ready card: exit 1" "$RC" 1
eq "approve on a Ready card: message" "$OUT" "card #$N3 has no rewrite proposal to approve"
eq "approve on a Ready card: card unchanged" "$(snap "$N3")" "$S"

N4="$(mkcard "$REPO" "close card" blocked)"
settle "$REPO" propose "$N4" "$CLOSE" >/dev/null 2>&1
S="$(snap "$N4")"
OUT="$(settle "$REPO" approve "$N4" 2>&1)"; RC=$?
eq "approve on a close proposal: exit 1" "$RC" 1
eq "approve on a close proposal: message" "$OUT" "card #$N4 has no rewrite proposal to approve"
eq "approve on a close proposal: card unchanged" "$(snap "$N4")" "$S"

N5="$(mkcard "$REPO" "no proposal" blocked)"
S="$(snap "$N5")"
OUT="$(settle "$REPO" approve "$N5" 2>&1)"; RC=$?
eq "approve with no proposal: exit 1" "$RC" 1
eq "approve with no proposal: message" "$OUT" "card #$N5 has no rewrite proposal to approve"
eq "approve with no proposal: card unchanged" "$(snap "$N5")" "$S"

jq -n --arg h "$PROP_HEAD" '{kind: "rewrite", scope: "just words, no path", acceptance: ["x"], summary: "s", head: $h}' > "$WORK/nopath.json"
N6="$(mkcard "$REPO" "no path" blocked)"
settle "$REPO" propose "$N6" "$WORK/nopath.json" >/dev/null 2>&1
S="$(snap "$N6")"
OUT="$(settle "$REPO" approve "$N6" 2>&1)"; RC=$?
eq "approve of a scope with no path: exit 1" "$RC" 1
eq "approve of a scope with no path: message" "$OUT" "card #$N6: the proposed Scope names no repository path"
eq "approve of a scope with no path: card unchanged" "$(snap "$N6")" "$S"

echo "Test: confirm"
settle "$REPO" confirm "$N4" >/dev/null 2>&1
eq "confirm: exit 0" "$?" 0
F="$(cardf "$REPO" "$N4")"
eq "confirm: moves to done" "$(jq -r .state "$F")" done
eq "confirm: label" "$(jq -c '.labels | index("fleet:closed-as-built") != null' "$F")" true
eq "confirm: proposal cleared" "$(jq -c .proposal "$F")" null
eq "confirm: one confirmed line" "$(jq -sc '[.[] | select(.card == '"$N4"')] | map(.decision)' "$REPO/.fleet-board/premise-decisions.jsonl")" '["confirmed"]'
eq "confirm: the line is dated" "$(jq -sc '[.[] | select(.card == '"$N4"') | .at | length > 0]' "$REPO/.fleet-board/premise-decisions.jsonl")" '[true]'
N7="$(mkcard "$REPO" "rewrite for confirm" blocked)"
settle "$REPO" propose "$N7" "$REWRITE" >/dev/null 2>&1
settle "$REPO" confirm "$N7" >/dev/null 2>&1
eq "confirm on a rewrite proposal: exit 1" "$?" 1
eq "confirm on a rewrite proposal: state unchanged" "$(jq -r .state "$(cardf "$REPO" "$N7")")" blocked

echo "Test: reject"
REPO2="$(mkrepo r2)"
R="$(mkcard "$REPO2" "reject me" blocked)"
settle "$REPO2" propose "$R" "$CLOSE" >/dev/null 2>&1
settle "$REPO2" reject "$R" >/dev/null 2>&1
eq "reject: exit 0" "$?" 0
eq "reject: proposal cleared" "$(jq -c .proposal "$(cardf "$REPO2" "$R")")" null
eq "reject: state unchanged" "$(jq -r .state "$(cardf "$REPO2" "$R")")" blocked
eq "reject: one rejected line" "$(decisions "$REPO2")" '["rejected"]'

M="$(mkcard "$REPO2" "move me" blocked)"
settle "$REPO2" propose "$M" "$CLOSE" >/dev/null 2>&1
inrepo "$REPO2" bash "$SCRIPTS/board-move.sh" "$M" ready >/dev/null 2>&1
eq "a person's move to ready: proposal cleared" "$(jq -c .proposal "$(cardf "$REPO2" "$M")")" null
eq "a person's move to ready: a rejected line" "$(decisions "$REPO2")" '["rejected","rejected"]'
eq "a person's move to ready: stamp by move" "$(jq -r .premise.by "$(cardf "$REPO2" "$M")")" move
eq "a person's move to ready: stamp is the default head" "$(jq -r .premise.sha "$(cardf "$REPO2" "$M")")" "$MAIN_HEAD"

K="$(mkcard "$REPO2" "supervisor move" blocked)"
settle "$REPO2" propose "$K" "$CLOSE" >/dev/null 2>&1
FLEET_BOARD_ACTOR=supervisor inrepo "$REPO2" bash "$SCRIPTS/board-move.sh" "$K" ready >/dev/null 2>&1
eq "the supervisor's move keeps the proposal" "$(jq -r .proposal.kind "$(cardf "$REPO2" "$K")")" close
eq "the supervisor's move adds no line" "$(decisions "$REPO2")" '["rejected","rejected"]'

echo "Test: propose refusals"
P="$(mkcard "$REPO2" "bad proposals" blocked)"
S="$(jq -S 'del(.updated_at)' "$(cardf "$REPO2" "$P")")"
jq -n --arg h "$PROP_HEAD" '{kind: "rewrite", scope: "- `src/x.js`", acceptance: "not a list", summary: "s", head: $h}' > "$WORK/bad-acc.json"
settle "$REPO2" propose "$P" "$WORK/bad-acc.json" >/dev/null 2>&1
eq "propose with an acceptance that is not a list: exit 2" "$?" 2
jq -n --arg h "$PROP_HEAD" '{kind: "demolish", scope: "- `src/x.js`", acceptance: ["a"], summary: "s", head: $h}' > "$WORK/bad-kind.json"
settle "$REPO2" propose "$P" "$WORK/bad-kind.json" >/dev/null 2>&1
eq "propose with an unknown kind: exit 2" "$?" 2
eq "propose refused: nothing written" "$(jq -S 'del(.updated_at)' "$(cardf "$REPO2" "$P")")" "$S"

printf '\npassed: %s  failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
