#!/usr/bin/env bash
#
# Plain-bash tests for stack-land.sh (card 391): a stacked child lands on the default branch
# after its parent merged. Real git with a local bare origin, the fake gh, and a local board.
#
# Usage: bash plugins/fleet-board/tests/test-stack-land.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPTS="$(cd "$SCRIPT_DIR/../scripts" && pwd)"
SCRIPT="$SCRIPTS/stack-land.sh"
unset FLEET_BOARD_CONFIG FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT || true
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export FLEET_BOARD_USER=tester

PASS=0
FAIL=0
CLEANUP_DIRS=()
ORIG_PATH="$PATH"
cleanup() { for d in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do rm -rf "$d" 2>/dev/null || true; done; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi; }

BRANCH=fleet/12-child
PBRANCH=fleet/11-parent
PPR=21
CPR=22

wg() { git -C "$WT" "$@"; }
og() { git --git-dir="$ORIGIN" "$@"; }
note() { (cd "$REPO" && bash "$SCRIPTS/note.sh" get "$1" 2>/dev/null); }
note_stable() { note "$1" | jq -S 'del(.updated_at)'; }
gh_calls() { cat "$GHDIR/calls.log" 2>/dev/null || true; }
count_calls() { gh_calls | grep -cE -- "$1" || true; }
# comments on card 12 other than the manager note
comments() { jq '[.comments[] | select(.body | startswith("<!-- fleet-board:manager-note -->") | not)] | length' "$REPO/.fleet-board/cards/12.json"; }

# build <variants>: variants (space separated): later-parent (the parent gets a commit after the child was cut),
# gone (the parent's branch is deleted from origin; its head lives on refs/pull/21/head only),
# main-line10 (main also changes line 10, which the child changed: the bridge conflicts),
# never-merged (the child merged a parent-branch commit the final head does not hold),
# open (the parent PR is still OPEN), no-squash (origin's main lacks the squash commit),
# reject (origin refuses updates of the child branch), nostack (the child's note has no stack)
# Leaves REPO (board, cwd), ORIGIN, WT (child worktree on $BRANCH), PH (final parent head), SQ (squash).
build() {
  local v=" $1 " i
  T="$(mktemp -d)"; CLEANUP_DIRS+=("$T")
  ORIGIN="$T/origin.git"; REPO="$T/repo"; SEED="$T/seed"; WT="$T/wt"; GHDIR="$T/gh"
  mkdir -p "$GHDIR/bin"
  git init -q --bare -b main "$ORIGIN"
  git init -q -b main "$SEED"
  git -C "$SEED" remote add origin "$ORIGIN"
  for i in 1 2 3 4 5 6 7 8 9 10; do echo "line $i"; done > "$SEED/a.txt"
  git -C "$SEED" add a.txt; git -C "$SEED" commit -q -m base
  git -C "$SEED" push -q origin main
  og symbolic-ref HEAD refs/heads/main
  git -C "$SEED" checkout -q -b "$PBRANCH"
  sed -i.bak '1s/.*/P/' "$SEED/a.txt"; rm -f "$SEED/a.txt.bak"
  git -C "$SEED" commit -q -am "parent change"
  START="$(git -C "$SEED" rev-parse HEAD)"
  git -C "$SEED" checkout -q -b "$BRANCH"
  sed -i.bak '10s/.*/C/' "$SEED/a.txt"; rm -f "$SEED/a.txt.bak"
  git -C "$SEED" commit -q -am "child change"
  case "$v" in
    *" never-merged "*)
      git -C "$SEED" checkout -q "$PBRANCH"; git -C "$SEED" checkout -q -b parent-x
      sed -i.bak '5s/.*/X/' "$SEED/a.txt"; rm -f "$SEED/a.txt.bak"
      git -C "$SEED" commit -q -am "parent commit that is dropped"
      git -C "$SEED" checkout -q "$BRANCH"
      git -C "$SEED" merge -q --no-edit parent-x >/dev/null 2>&1
      ;;
  esac
  case "$v" in
    *" later-parent "*)
      git -C "$SEED" checkout -q "$PBRANCH"
      sed -i.bak '3s/.*/Q/' "$SEED/a.txt"; rm -f "$SEED/a.txt.bak"
      git -C "$SEED" commit -q -am "parent later"
      git -C "$SEED" checkout -q "$BRANCH"
      ;;
  esac
  PH="$(git -C "$SEED" rev-parse "$PBRANCH")"
  git -C "$SEED" push -q origin "$PBRANCH" "$BRANCH"
  git -C "$SEED" push -q origin "$PBRANCH:refs/pull/$PPR/head"
  case "$v" in *" gone "*) og update-ref -d "refs/heads/$PBRANCH" ;; esac
  git -C "$SEED" checkout -q main
  case "$v" in
    *" main-line10 "*)
      sed -i.bak '10s/.*/M/' "$SEED/a.txt"; rm -f "$SEED/a.txt.bak"
      git -C "$SEED" commit -q -am "main line 10" ;;
  esac
  git -C "$SEED" merge -q --squash "$PBRANCH" >/dev/null 2>&1
  git -C "$SEED" commit -q -m "squash parent"
  SQ="$(git -C "$SEED" rev-parse HEAD)"
  case "$v" in
    *" no-squash "*) git -C "$SEED" push -q origin main:refs/heads/side ;;
    *) git -C "$SEED" push -q origin main ;;
  esac
  git clone -q "$ORIGIN" "$WT" 2>/dev/null
  git -C "$WT" checkout -q "$BRANCH"
  git -C "$WT" remote set-head origin main >/dev/null 2>&1

  # the local board
  mkdir -p "$REPO"; git init -q -b main "$REPO"
  printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\n' > "$REPO/.fleet-board.yml"
  mkdir -p "$REPO/.fleet-board/cards"; echo 11 > "$REPO/.fleet-board/next"
  printf 'Work\n' > "$T/body.md"
  (cd "$REPO" && bash "$SCRIPTS/board-create.sh" "Parent" "$T/body.md" >/dev/null 2>&1 && bash "$SCRIPTS/board-create.sh" "Child" "$T/body.md" >/dev/null 2>&1)
  printf '{"branch":"%s","pr":%s}\n' "$PBRANCH" "$PPR" > "$T/p11.json"
  (cd "$REPO" && bash "$SCRIPTS/note.sh" merge 11 "$T/p11.json")
  case "$v" in
    *" nostack "*) printf '{"branch":"%s","pr":%s}\n' "$BRANCH" "$CPR" > "$T/p12.json" ;;
    *) printf '{"branch":"%s","pr":%s,"stack":{"parent":11,"base":"%s","start":"%s","attention":null}}\n' "$BRANCH" "$CPR" "$PBRANCH" "$START" > "$T/p12.json" ;;
  esac
  (cd "$REPO" && bash "$SCRIPTS/note.sh" merge 12 "$T/p12.json")

  # the fake gh: pr edit records origin's child branch head at the moment of the call
  local state=MERGED
  case "$v" in *" open "*) state=OPEN ;; esac
  jq -cn --arg s "$state" --arg h "$PH" --arg q "$SQ" '{state: $s, headRefOid: $h, mergeCommit: (if $s == "MERGED" then {oid: $q} else null end)}' > "$GHDIR/parent-view.json"
  printf 'main\n' > "$GHDIR/base.txt"
  cat > "$GHDIR/routes" <<ROUTES
pr view $PPR --repo acme/toy --json state,headRefOid,mergeCommit	0	$GHDIR/parent-view.json
pr view $CPR --repo acme/toy --json baseRefName*	0	$GHDIR/base.txt
pr edit $CPR --repo acme/toy --base main	0	-
ROUTES
  cat > "$GHDIR/bin/gh" <<WRAP
#!/usr/bin/env bash
if [ "\$1 \$2" = "pr edit" ]; then
  git --git-dir="$ORIGIN" rev-parse "refs/heads/$BRANCH" > "$GHDIR/origin-at-edit" 2>/dev/null
fi
exec bash "$SCRIPT_DIR/fake-gh.sh" "\$@"
WRAP
  chmod +x "$GHDIR/bin/gh"
  case "$v" in
    *" reject "*)
      printf '#!/bin/sh\nexit 1\n' > "$ORIGIN/hooks/pre-receive"; chmod +x "$ORIGIN/hooks/pre-receive" ;;
  esac
  export FAKE_GH_DIR="$GHDIR" FAKE_GH_ROUTES="$GHDIR/routes"
  PATH="$GHDIR/bin:$ORIG_PATH"
  HEAD0="$(wg rev-parse HEAD)"
  ORIGIN0="$(og rev-parse "refs/heads/$BRANCH")"
  NOTE0="$(note_stable 12)"
  COMMENTS0="$(comments)"
}

run() { # run <pr or -> : runs stack-land.sh for card 12 from the board repo
  local out err
  out="$(mktemp)"; err="$(mktemp)"
  (cd "$REPO" && bash "$SCRIPT" 12 "$1" "$BRANCH" "$WT") > "$out" 2> "$err"
  RC=$?
  OUT="$(cat "$out")"; ERR="$(cat "$err")"
  rm -f "$out" "$err"
}

unchanged() { # unchanged <label>: no commit, no push, no pr edit, the note as it was
  assert_eq "$1: branch head unchanged" "$(wg rev-parse HEAD)" "$HEAD0"
  assert_eq "$1: origin branch unchanged" "$(og rev-parse "refs/heads/$BRANCH")" "$ORIGIN0"
  assert_eq "$1: no pr edit" "$(count_calls '^[0-9]+	pr edit ')" 0
  assert_eq "$1: note unchanged" "$(note_stable 12)" "$NOTE0"
}

echo "Test: lands after the parent was squash-merged"
build ""
run "$CPR"
assert_eq "exit 0" "$RC" 0
NEW="$(wg rev-parse HEAD)"
assert_eq "origin's child branch holds the bridge commit" "$(og rev-parse "refs/heads/$BRANCH")" "$NEW"
assert_eq "the bridge commit has the squash as its second parent" "$(wg rev-parse "$NEW^2")" "$SQ"
assert_eq "the bridge commit sits on the old head" "$(wg rev-parse "$NEW^1")" "$HEAD0"
assert_eq "gh log holds pr edit <pr> --base main" "$(count_calls "pr edit $CPR --repo acme/toy --base main")" 1
assert_eq "pr edit came after the push: origin held the new head" "$(cat "$GHDIR/origin-at-edit" 2>/dev/null)" "$NEW"
assert_eq "note: stack is null" "$(note 12 | jq -c .stack)" null
assert_eq "note: landed holds the four values" "$(note 12 | jq -c '.landed')" "{\"parent\":11,\"parent_head\":\"$PH\",\"squash\":\"$SQ\",\"sha\":\"$NEW\"}"
assert_eq "update-branch.sh ran (the base was read)" "$(count_calls "pr view $CPR --repo acme/toy --json baseRefName")" 1
assert_eq "update-branch.sh recorded last_update" "$(note 12 | jq -r '.last_update.base')" main

echo "Test: a second run after landing, and a card without stack"
HEAD1="$(wg rev-parse HEAD)"
run "$CPR"
assert_eq "second run exits 0" "$RC" 0
assert_eq "second run adds no commit" "$(wg rev-parse HEAD)" "$HEAD1"
build "nostack"
run "$CPR"
assert_eq "no stack: exit 0" "$RC" 0
unchanged "no stack"

echo "Test: the parent PR is still OPEN"
build "open"
run "$CPR"
assert_eq "exit 3" "$RC" 3
unchanged "open parent"

echo "Test: origin's main does not hold the squash commit"
build "no-squash"
run "$CPR"
assert_eq "exit 3" "$RC" 3
unchanged "no squash on main"

echo "Test: the parent's branch is gone from origin"
build "later-parent gone"
assert_eq "setup: the parent's branch is gone" "$(og rev-parse -q --verify "refs/heads/$PBRANCH" >/dev/null 2>&1; echo $?)" 1
run "$CPR"
assert_eq "exit 0" "$RC" 0
assert_eq "origin has the landed head" "$(og rev-parse "refs/heads/$BRANCH")" "$(wg rev-parse HEAD)"
assert_eq "note: landed" "$(note 12 | jq -r '.landed.parent_head')" "$PH"

echo "Test: the child had not merged the parent's last commit"
build "later-parent"
run "$CPR"
assert_eq "exit 0" "$RC" 0
assert_eq "the final head is an ancestor of the landed head" "$(wg merge-base --is-ancestor "$PH" HEAD; echo $?)" 0
assert_eq "the landed tree holds the last parent commit's change" "$(wg show HEAD:a.txt | sed -n 3p)" Q
assert_eq "the landed tree keeps the child's change" "$(wg show HEAD:a.txt | sed -n 10p)" C
assert_eq "the push reached origin" "$(og rev-parse "refs/heads/$BRANCH")" "$(wg rev-parse HEAD)"

echo "Test: the child merged a parent commit that is not in the final head"
build "never-merged"
run "$CPR"
assert_eq "exit 4" "$RC" 4
assert_eq "attention names the reason" "$(note 12 | jq -r '.stack.attention')" "the child followed commits of #11 that never merged"
assert_eq "one comment posted" "$(( $(comments) - COMMENTS0 ))" 1
assert_eq "branch head unchanged" "$(wg rev-parse HEAD)" "$HEAD0"
assert_eq "nothing pushed" "$(og rev-parse "refs/heads/$BRANCH")" "$ORIGIN0"
assert_eq "no pr edit" "$(count_calls '^[0-9]+	pr edit ')" 0
assert_eq "landed stays null" "$(note 12 | jq -c .landed)" null

echo "Test: the bridge conflicts"
build "main-line10"
run "$CPR"
assert_eq "exit 4" "$RC" 4
assert_eq "attention names the file" "$(note 12 | jq -r '.stack.attention')" "landing on main conflicts in a.txt"
assert_eq "branch head unchanged" "$(wg rev-parse HEAD)" "$HEAD0"
assert_eq "nothing pushed" "$(og rev-parse "refs/heads/$BRANCH")" "$ORIGIN0"
assert_eq "no pr edit" "$(count_calls '^[0-9]+	pr edit ')" 0
assert_eq "one comment posted" "$(( $(comments) - COMMENTS0 ))" 1

echo "Test: a dash for the PR"
build ""
run -
assert_eq "exit 0" "$RC" 0
assert_eq "origin holds the landed head" "$(og rev-parse "refs/heads/$BRANCH")" "$(wg rev-parse HEAD)"
assert_eq "no pr edit call" "$(count_calls '^[0-9]+	pr edit ')" 0
assert_eq "update-branch.sh did not run (no base read)" "$(count_calls 'baseRefName')" 0
assert_eq "note: landed" "$(note 12 | jq -r '.landed.squash')" "$SQ"
assert_eq "note: stack is null" "$(note 12 | jq -c .stack)" null

echo "Test: a rejected push"
build "reject"
run "$CPR"
assert_eq "exit 1" "$RC" 1
assert_eq "the local branch is back at its starting head" "$(wg rev-parse HEAD)" "$HEAD0"
assert_eq "origin unchanged" "$(og rev-parse "refs/heads/$BRANCH")" "$ORIGIN0"
assert_eq "note unchanged" "$(note_stable 12)" "$NOTE0"
assert_eq "no pr edit" "$(count_calls '^[0-9]+	pr edit ')" 0

echo "Test: the parent's final head reaches the worktree only through refs/pull/<pr>/head"
build "later-parent gone"
rm -rf "$WT"
git clone -q --no-local "$ORIGIN" "$WT" 2>/dev/null
git -C "$WT" checkout -q "$BRANCH"
git -C "$WT" remote set-head origin main >/dev/null 2>&1
assert_eq "setup: the final head is not in the worktree" "$(wg cat-file -e "$PH^{commit}" >/dev/null 2>&1 && echo present || echo missing)" missing
run "$CPR"
assert_eq "exit 0" "$RC" 0
assert_eq "the final head was fetched and is an ancestor of the landed head" "$(wg merge-base --is-ancestor "$PH" HEAD; echo $?)" 0
assert_eq "origin has the landed head" "$(og rev-parse "refs/heads/$BRANCH")" "$(wg rev-parse HEAD)"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
