#!/usr/bin/env bash
#
# Plain-bash tests for the stacked start (tick-plan.sh, the scheduler and State.reserve).
# Offline: the fake gh and the local store built from generated routes, as the test-tick-plan-*.sh suites do.
# No framework, no dependencies beyond POSIX tools, jq, git and python3.
#
# Usage: bash plugins/fleet-board/tests/test-stack-plan.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SCRIPT_DIR/store-sync.sh" # the local store, rebuilt from the routes before each run
SCRIPT="${SCRIPT_DIR}/../scripts/tick-plan.sh"
TICK="$SCRIPT_DIR/../fixtures/gh/tick"
SCRIPTS_ABS="$(cd "$SCRIPT_DIR/../scripts" && pwd)"

unset FLEET_BOARD_CONFIG FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT || true

PASS=0
FAIL=0
LAST_OUT=""
LAST_ERR=""
LAST_EXIT=0
CLEANUP_DIRS=()
ORIG_PATH="$PATH"
BASH_EXE=bash
[ -x /bin/bash ] && BASH_EXE=/bin/bash

cleanup() {
  for dir in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do
    rm -rf "$dir" 2>/dev/null || true
  done
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi; }
assert_exit() { if [ "$LAST_EXIT" = "$2" ]; then pass "$1"; else fail "$1" "expected exit $2, got $LAST_EXIT (stderr: $LAST_ERR)"; fi; }

run_check() {
  local script="$1" tmpout tmperr
  shift
  store_sync
  tmpout="$(mktemp)"
  tmperr="$(mktemp)"
  "$BASH_EXE" "$script" "$@" > "$tmpout" 2> "$tmperr"
  LAST_EXIT=$?
  LAST_OUT="$(cat "$tmpout")"
  LAST_ERR="$(cat "$tmperr")"
  rm -f "$tmpout" "$tmperr"
}

jqc() { jq -c "$1" <<<"$LAST_OUT" 2>/dev/null || echo INVALID; }
assert_jq() { assert_eq "$1" "$(jqc "$2")" "$3"; }
card() { printf '(.cards[] | select(.number == %d)).%s' "$1" "$2"; }

# call_count <gh words...>: the fake gh calls whose argv is exactly these words
call_count() {
  local want f n=0
  want="$(printf '%s\n' "$@")"
  for f in "$FAKE_GH_DIR"/argv/*; do
    [ -f "$f" ] || continue
    [ "$(cat "$f")" = "$want" ] && n=$((n + 1))
  done
  echo "$n"
}

# setup_case <routes case> [extra YAML]: a repo with the config and the fake gh on PATH
setup_case() {
  REPO="$(mktemp -d)"
  git init -q "$REPO"
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test User"
  {
    printf 'board:\n  repo: acme/toy\n'
    printf 'worktrees:\n  dir: .fw\n'
    [ -n "${2:-}" ] && printf '%s\n' "$2"
    printf 'review:\n  stages:\n    - name: documentation\n      enabled: false\n    - name: blast_radius\n      enabled: false\n'
  } > "$REPO/.fleet-board.yml"
  git -C "$REPO" add .fleet-board.yml
  git -C "$REPO" commit -q -m "initial"

  FAKE_GH_DIR="$(mktemp -d)"
  BIN="$FAKE_GH_DIR/bin"
  mkdir -p "$BIN"
  ln -s "$SCRIPT_DIR/fake-gh.sh" "$BIN/gh"
  unset CDPATH FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT FLEET_BOARD_CONFIG || true
  PATH="$BIN:$ORIG_PATH"
  FAKE_GH_ROUTES="$TICK/$1/routes"
  export FAKE_GH_DIR FAKE_GH_ROUTES PATH
  cd "$REPO"
  CLEANUP_DIRS+=("$REPO" "$FAKE_GH_DIR")
  DIR="$FAKE_GH_DIR/stack"
  mkdir -p "$DIR"
  : > "$DIR/cards"
}

FENCE='```'
START40=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

# mk <n> <column> <scope paths, space separated or -> <deps, space separated or -> [<note JSON>]
# The card file, its comments and (when the note names a PR) the PR's routes data. A PR number is card + 22.
mk() {
  local n="$1" col="$2" scope="$3" deps="$4" note="${5:-}" body p d
  body="Work."$'\n\n'
  if [ "$scope" != "-" ]; then
    body="$body## Scope"$'\n'
    for p in $scope; do body="$body- \`$p\`"$'\n'; done
    body="$body"$'\n'
  fi
  body="$body## Acceptance"$'\n'"- it works"$'\n'
  if [ "$deps" != "-" ]; then
    body="$body"$'\n'"## Depends on"$'\n'
    for d in $deps; do body="$body- #$d"$'\n'; done
  fi
  jq -n --argjson n "$n" --arg l "fleet:$col" --arg b "$body" \
    '{number: $n, title: "Card \($n)", html_url: "https://github.com/acme/toy/issues/\($n)", body: $b, labels: [{name: $l}]}' \
    > "$DIR/issue-$n.json"
  if [ -n "$note" ]; then
    jq -n --arg b "<!-- fleet-board:manager-note -->"$'\n'"### fleet-board manager note"$'\n\n'"${FENCE}json"$'\n'"$note"$'\n'"${FENCE}"$'\n' \
      '[{id: 1, user: {login: "fleet-bot"}, body: $b, created_at: "2026-01-01T00:00:00Z"}]' > "$DIR/comments-$n.json"
    jq -r '.pr // empty' <<<"$note" > "$DIR/pr-$n"
  fi
  printf '%s\n' "$n" >> "$DIR/cards"
  printf '%s\n' "$col" > "$DIR/col-$n"
}

# note <state> <n> [extra JSON members, e.g. ,"stack":{...}]: a manager note for card n on its branch and PR
note() { printf '{"state":"%s","branch":"fleet/%s-card","pr":%s,"round":1%s}' "$1" "$2" "$(($2 + 22))" "${3:-}"; }
stack_of() { printf ',"stack":{"parent":%s,"base":"fleet/%s-card","start":"%s"}' "$1" "$1" "$START40"; }

# files <n> <paths...>: the files card n's PR touches (default: src/parent-only.sh)
files() {
  local n="$1" arr
  shift
  arr="$(printf '%s\n' "$@" | jq -Rsc '[split("\n")[] | select(length > 0) | {path: .}]')"
  jq -cn --argjson f "$arr" '{files: $f, changedFiles: ($f | length)}' > "$DIR/files-$n.json"
}
prstate() { printf '%s\n' "$2" > "$DIR/prstate-$1"; }

# routes: write the routes file from the cards made with mk
routes() {
  local n pr col st
  {
    printf 'api user\t0\t%s/labels/user.json\n' "$TICK/.."
    for n in $(cat "$DIR/cards"); do
      printf 'api repos/acme/toy/issues/%s\t0\t%s/issue-%s.json\n' "$n" "$DIR" "$n"
      if [ -f "$DIR/comments-$n.json" ]; then
        printf 'api --paginate repos/acme/toy/issues/%s/comments\t0\t%s/comments-%s.json\n' "$n" "$DIR" "$n"
      else
        printf 'api --paginate repos/acme/toy/issues/%s/comments\t0\t%s/common/empty.json\n' "$n" "$TICK"
      fi
      pr="$(cat "$DIR/pr-$n" 2>/dev/null)"
      if [ -n "$pr" ]; then
        st="$(cat "$DIR/prstate-$n" 2>/dev/null)"; st="${st:-OPEN}"
        jq -cn --arg s "$st" --arg h "$(cat "$DIR/head-$n" 2>/dev/null || echo abc1234)" --argjson d "$(cat "$DIR/draft-$n" 2>/dev/null || echo false)" \
          '{isDraft: $d, state: $s, mergedAt: null, statusCheckRollup: [{__typename: "CheckRun", conclusion: "SUCCESS"}], headRefOid: $h}' > "$DIR/prview-$n.json"
        jq -cn --arg s "$st" '{state: $s}' > "$DIR/prstate-json-$n.json"
        [ -f "$DIR/files-$n.json" ] || files "$n" src/parent-only.sh
        printf 'pr view %s --repo acme/toy --json isDraft,state,mergedAt,statusCheckRollup,headRefOid\t0\t%s/prview-%s.json\n' "$pr" "$DIR" "$n"
        printf 'pr view %s --repo acme/toy --json state\t0\t%s/prstate-json-%s.json\n' "$pr" "$DIR" "$n"
        printf 'pr view %s --repo acme/toy --json files*\t0\t%s/files-%s.json\n' "$pr" "$DIR" "$n"
      fi
    done
    printf 'issue view 9 --repo acme/toy --json state,stateReason\t0\t%s/common/dep-completed.json\n' "$TICK"
    for col in ready in_progress in_review blocked human_qa; do
      for n in $(cat "$DIR/cards"); do
        [ "$(cat "$DIR/col-$n")" = "$col" ] \
          && jq -cn --argjson n "$n" --arg l "fleet:$col" '{number: $n, title: "Card \($n)", url: "u", labels: [{name: $l}]}'
      done | jq -cs '.' > "$DIR/list-$col.json"
      printf 'issue list --repo acme/toy --label fleet:%s *\t0\t%s/list-%s.json\n' "$col" "$DIR" "$col"
    done
  } > "$DIR/routes"
  FAKE_GH_ROUTES="$DIR/routes"; export FAKE_GH_ROUTES
}

ON="$(printf 'stacking:\n  enabled: true')"
WAIT11='"waits for acme/toy#11 (in_review)"'

echo "Test: stacked start plan"

# Parent 11 in review with an open PR; child 12 depends on it.
board() {
  setup_case ready-start "$1"
  mk 11 in_review - - "$(note in_review 11)"
  mk 12 ready 'src/child.sh' '11'
  routes
}

board ""
run_check "$SCRIPT"
assert_exit "no stacking key: exit" 0
assert_jq "no stacking key: card 12 is a stacked start" "$(card 12 action)+\" \"+$(card 12 reason)" '"start ready, stacked on #11"'
assert_jq "no stacking key: stack names the parent" "$(card 12 stack)" '{"parent":11,"base":"fleet/11-card","ancestors":[11]}'
assert_jq "no stacking key: every row carries the stack key" '[.cards[] | has("stack")] | all' 'true'

board "$(printf 'stacking:\n  enabled: false')"
run_check "$SCRIPT"
assert_exit "stacking enabled false still in config: exit" 0
assert_jq "stacking enabled false still in config: card 12 is a stacked start" "$(card 12 action)+\" \"+$(card 12 reason)" '"start ready, stacked on #11"'

board "$ON"
run_check "$SCRIPT"
assert_exit "on: exit" 0
assert_jq "on: row 12 is start" "$(card 12 action)" '"start"'
assert_jq "on: reason names the parent" "$(card 12 reason)" '"ready, stacked on #11"'
assert_jq "on: stack holds parent, base and ancestors" "$(card 12 stack)" '{"parent":11,"base":"fleet/11-card","ancestors":[11]}'
assert_jq "on: the parent's row has stack null" "$(card 11 stack)" 'null'
assert_jq "on: no waiting_on on a stacked start" "$(card 12 waiting_on)" 'null'
assert_eq "on: one parent PR state lookup" "$(call_count pr view 33 --repo acme/toy --json state)" 1

# --candidates carries the same key
run_check "$SCRIPT" --candidates
assert_jq "candidates: row 12 stack" "(.candidates[] | select(.number == 12)).stack" '{"parent":11,"base":"fleet/11-card","ancestors":[11]}'
assert_jq "candidates: every row has the stack key" '[.candidates[] | has("stack")] | all' 'true'
assert_jq "candidates: the parent's row has stack null" "(.candidates[] | select(.number == 11)).stack" 'null'

# The card waits, with today's reason, when the rule is not met
waits() { # waits <description>
  run_check "$SCRIPT"
  assert_jq "$1: waits" "$(card 12 action)" '"wait"'
  assert_jq "$1: stack null" "$(card 12 stack)" 'null'
}

setup_case ready-start "$ON"
mk 11 in_progress - - "$(note in_progress 11)"
mk 12 ready 'src/child.sh' '11'
routes
waits "parent in_progress"
assert_jq "parent in_progress: today's reason" "$(card 12 reason)" '"waits for acme/toy#11 (in_progress)"'

setup_case ready-start "$ON"
mk 11 in_review - - "$(note in_review 11)"
mk 13 in_review - - "$(note in_review 13)"
mk 12 ready 'src/child.sh' '11 13'
routes
waits "two dependencies unmet"
assert_jq "two dependencies unmet: reason lists both" "$(card 12 reason)" '"waits for acme/toy#11 (in_review), acme/toy#13 (in_review)"'
assert_eq "two dependencies unmet: no parent PR state lookup" "$(call_count pr view 33 --repo acme/toy --json state)" 0

setup_case ready-start "$ON"
mk 11 in_review - - "$(note in_review 11)"
prstate 11 CLOSED
mk 12 ready 'src/child.sh' '11'
routes
waits "parent PR CLOSED"
assert_jq "parent PR CLOSED: today's reason" "$(card 12 reason)" "$WAIT11"

setup_case ready-start "$ON"
mk 11 in_review - - '{"state":"in_review","branch":null,"pr":33,"round":1}'
mk 12 ready 'src/child.sh' '11'
routes
waits "parent note has no branch"
assert_jq "parent note has no branch: today's reason" "$(card 12 reason)" "$WAIT11"

setup_case ready-start "$ON"
mk 11 ready 'src/a.sh' '12'
mk 12 ready 'src/child.sh' '11'
routes
run_check "$SCRIPT"
assert_jq "two cards blocking each other: 11 waits" "$(card 11 action)" '"wait"'
assert_jq "two cards blocking each other: 12 waits" "$(card 12 action)" '"wait"'
assert_jq "two cards blocking each other: no stack on either" '[.cards[].stack] | all(. == null)' 'true'

# One dependency done, one in review: stacked on the one in review
setup_case ready-start "$ON"
mk 11 in_review - - "$(note in_review 11)"
mk 12 ready 'src/child.sh' '9 11'
routes
run_check "$SCRIPT"
assert_jq "one done, one in review: start" "$(card 12 action)" '"start"'
assert_jq "one done, one in review: stacked on the one in review" "$(card 12 stack)" '{"parent":11,"base":"fleet/11-card","ancestors":[11]}'

# A card depending on a stacked child in review: ancestors list the child, then its parent
setup_case ready-start "$ON"
mk 10 in_review - - "$(note in_review 10)"
mk 11 in_review - 10 "$(note in_review 11 "$(stack_of 10)")"
mk 12 ready 'src/child.sh' '11'
files 11 src/mid.sh
routes
run_check "$SCRIPT"
assert_jq "chain: start" "$(card 12 action)" '"start"'
assert_jq "chain: ancestors are the child, then its parent" "$(card 12 stack)" '{"parent":11,"base":"fleet/11-card","ancestors":[11,10]}'

# Scope: the parent's PR files do not hold the child
setup_case ready-start "$ON"
mk 11 in_review - - "$(note in_review 11)"
files 11 src/a.sh
mk 12 ready 'src/a.sh' '11'
routes
run_check "$SCRIPT"
assert_jq "scope: a child naming a file the parent's PR touches starts" "$(card 12 action)" '"start"'

# ... but an unrelated in-progress card touching the file does
setup_case ready-start "$ON"
mk 11 in_review - - "$(note in_review 11)"
files 11 src/a.sh
mk 20 in_progress 'src/a.sh' -
mk 12 ready 'src/a.sh' '11'
routes
run_check "$SCRIPT"
assert_jq "scope: waits when unrelated card 20 touches the file" "$(card 12 action)" '"wait"'
assert_jq "scope: the reason names card 20" "$(card 12 reason)" '"Scope overlaps #20 on src/a.sh"'
assert_jq "scope: a waiting child has stack null" "$(card 12 stack)" 'null'

# Two Ready children of one parent naming the same file: the lower number starts
setup_case ready-start "$ON"
mk 11 in_review - - "$(note in_review 11)"
files 11 src/a.sh
mk 12 ready 'src/a.sh' '11'
mk 13 ready 'src/a.sh' '11'
routes
run_check "$SCRIPT"
assert_jq "siblings: the lower number starts" "$(card 12 action)" '"start"'
assert_jq "siblings: the other waits" "$(card 13 action)" '"wait"'
assert_jq "siblings: the reason names the lower card" "$(card 13 reason)" '"Scope overlaps #12 on src/a.sh"'
assert_jq "siblings: the waiting sibling has stack null" "$(card 13 stack)" 'null'

# No Ready card with exactly one unmet dependency: no parent PR state call
setup_case ready-start "$ON"
mk 11 in_review - - "$(note in_review 11)"
mk 12 ready 'src/child.sh' -
routes
run_check "$SCRIPT"
assert_jq "no candidate: a plain ready card starts" "$(card 12 action)" '"start"'
assert_eq "no candidate: the fake gh log holds no pr view --json state call" "$(call_count pr view 33 --repo acme/toy --json state)" 0

echo "Test: land row (card 391)"
# land_board <child column> <child note JSON> [<parent column>] [<config>]: parent 11, stacked child 12
land_board() {
  setup_case ready-start "${4-$ON}"
  mk 11 "${3:-done}" - - "$(note "${3:-done}" 11)"
  mk 12 "$1" 'src/child.sh' - "$2"
  routes
}
LAND_REASON='"land #11 merged; land on main"'
land_of() { printf '%s+" "+%s' "$(card 12 action)" "$(card 12 reason)"; }

land_board in_review "$(note in_review 12 "$(stack_of 11)")"
run_check "$SCRIPT"
assert_exit "land: exit" 0
assert_jq "land: a stacked child whose parent card is done" "$(land_of)" "$LAND_REASON"

land_board in_review "$(note in_review 12 "$(stack_of 11),\"conflicted_files\":[\"src/child.sh\"]")"
run_check "$SCRIPT"
assert_jq "land: a stale conflicted_files does not stop it" "$(land_of)" "$LAND_REASON"

land_board in_progress "{\"state\":\"in_progress\",\"branch\":\"fleet/12-card\",\"pr\":null,\"round\":1$(stack_of 11)}"
printf 'pr list --repo acme/toy --head fleet/12-card --state open --json number\t0\t%s/common/empty.json\n' "$TICK" >> "$DIR/routes"
run_check "$SCRIPT"
assert_jq "land: in in_progress with no PR" "$(land_of)" "$LAND_REASON"

stack_attn() { printf ',"stack":{"parent":11,"base":"fleet/11-card","start":"%s","attention":"%s"}' "$START40" "the child followed commits of #11 that never merged"; }
land_board in_review "$(note in_review 12 "$(stack_attn)")"
run_check "$SCRIPT"
assert_jq "land: not planned while stack.attention is set" "$(card 12 action) != \"land\"" 'true'

land_board in_review "$(note in_review 12 "$(stack_of 11)")" in_review
run_check "$SCRIPT"
assert_jq "land: not planned while the parent card is in review" "$(card 12 action) != \"land\"" 'true'

land_board in_review "$(note in_review 12 "$(stack_of 11)")" done ""
run_check "$SCRIPT"
assert_jq "land: with no stacking key the row is planned" "$(card 12 action)" '"land"'

assert_eq "tick-plan.sh passes --landing to review-drift.sh" "$([ "$(grep -c -- '--landing' "$SCRIPTS_ABS/tick-plan.sh")" -ge 1 ] && echo yes || echo no)" yes
assert_eq "the gate passes --landing to review-drift.sh" "$([ "$(grep -c -- '--landing' "$SCRIPTS_ABS/../hooks/gate.sh")" -ge 1 ] && echo yes || echo no)" yes

# --- Rows for a card whose note has stack (390) ---
CLEAN_LR=',"last_review":{"round":1,"sha":"abc1234","critical":0,"important":0,"findings":[]}'
stack_att() { printf ',"stack":{"parent":%s,"base":"fleet/%s-card","start":"%s","attention":"%s"}' "$1" "$1" "$START40" "$2"; }

# stack_git <yes|no>: an origin with the default branch and fleet/11-card; child head is written for card 12 and
# contains the parent branch head when the argument is yes
stack_git() {
  local org def p c
  org="$(mktemp -d)"; CLEANUP_DIRS+=("$org")
  git init -q --bare "$org"
  git -C "$REPO" remote add origin "$org"
  def="$(git -C "$REPO" symbolic-ref --short HEAD)"
  git -C "$REPO" checkout -q -b fleet/11-card
  printf 'p\n' > "$REPO/parent.txt"; git -C "$REPO" add parent.txt; git -C "$REPO" commit -q -m "parent work"
  p="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q "$def"
  git -C "$REPO" checkout -q -b fleet/12-card
  printf 'c\n' > "$REPO/child.txt"; git -C "$REPO" add child.txt; git -C "$REPO" commit -q -m "child work"
  if [ "$1" = yes ]; then git -C "$REPO" merge -q --no-edit -m "Merge origin/fleet/11-card into fleet/12-card" fleet/11-card >/dev/null; fi
  c="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" push -q origin "$def" fleet/11-card fleet/12-card 2>/dev/null
  git -C "$REPO" fetch -q origin 2>/dev/null
  printf '%s\n' "$c" > "$DIR/head-12"
}

# child_board <config yaml> <parent column> <child note extras> [<child column>]: parent 11 and stacked child 12
child_board() {
  setup_case ready-start "$1"
  mk 11 "$2" - - "$(note "$2" 11)"
  mk "${5:-12}" "${4:-in_review}" 'src/child.sh' - "$(note "${4:-in_review}" 12 "$3")"
}

echo "Test: rows for a stacked child"
for mode in on off; do
  if [ "$mode" = on ]; then CFG="$ON"; else CFG=""; fi
  child_board "$CFG" wont_do "$(stack_of 11)"
  routes
  run_check "$SCRIPT"
  assert_jq "$mode: parent wont_do: child skips" "$(card 12 action)+\" \"+$(card 12 reason)" '"skip stacked on #11, which was closed without merging; a person decides"'

  child_board "$CFG" in_review "$(stack_of 11)"
  prstate 11 CLOSED
  routes
  run_check "$SCRIPT"
  assert_jq "$mode: parent PR CLOSED: child skips" "$(card 12 action)+\" \"+$(card 12 reason)" '"skip stacked on #11, which was closed without merging; a person decides"'

  child_board "$CFG" in_review "$CLEAN_LR$(stack_att 11 'parent head moved twice')"
  routes
  run_check "$SCRIPT"
  assert_jq "$mode: attention set: child skips" "$(card 12 action)+\" \"+$(card 12 reason)" '"skip landing needs attention: parent head moved twice; a person decides"'

  child_board "$CFG" in_review "$(stack_of 11)"
  stack_git no
  routes
  run_check "$SCRIPT"
  assert_jq "$mode: PR head lacks the parent branch head: update_branch" "$(card 12 action)+\" \"+$(card 12 reason)" '"update_branch parent branch fleet/11-card moved"'

  child_board "$CFG" in_review "$(stack_of 11)"
  stack_git yes
  routes
  run_check "$SCRIPT"
  assert_jq "$mode: PR head contains the parent branch head: not update_branch" "$(card 12 action)" '"review"'

  child_board "$CFG" blocked "$(stack_of 11)"
  routes
  run_check "$SCRIPT"
  assert_jq "$mode: no review yet, parent blocked: child is still planned review" "$(card 12 action)" '"review"'
done

echo "Test: a clean current review of a stacked child waits for the parent"
POLICY="$(printf 'stacking:\n  enabled: true\nmerge:\n  policy: auto\nhuman_qa_paths:\n  - "src/qa/**"')"
# review_case <stacked|plain> <to_human_qa|mark_ready|merge>
review_case() {
  local extra="$CLEAN_LR"
  [ "$1" = stacked ] && extra="$CLEAN_LR$(stack_of 11)"
  setup_case ready-start "$POLICY"
  mk 11 in_review - - "$(note in_review 11)"
  mk 12 in_review 'src/child.sh' - "$(note in_review 12 "$extra")"
  case "$2" in
    to_human_qa) files 12 src/qa/x.sh ;;
    mark_ready) files 12 src/child.sh; printf 'true\n' > "$DIR/draft-12" ;;
    merge) files 12 src/child.sh ;;
  esac
  routes
  run_check "$SCRIPT"
}
for act in to_human_qa mark_ready merge; do
  review_case plain "$act"
  assert_jq "unstacked: $act" "$(card 12 action)" "\"$act\""
  review_case stacked "$act"
  assert_jq "stacked: clean review where an unstacked card plans $act: wait" "$(card 12 action)+\" \"+$(card 12 reason)" '"wait waits for #11 to merge"'
done

echo "Test: a stacked child in merging"
setup_case ready-start "$POLICY"
mk 11 in_review - - "$(note in_review 11)"
mk 12 merging 'src/child.sh' - "$(note merging 12 "$CLEAN_LR$(stack_of 11)")"
routes
run_check "$SCRIPT"
assert_jq "merging: skip until the parent merges" "$(card 12 action)+\" \"+$(card 12 reason)" '"skip waits for #11 to merge"'

# Scheduler and State: python snippets (the suites' own cases live in fixtures/supervisor)
py_check() {
  local desc="$1" out rc
  out="$(PYTHONDONTWRITEBYTECODE=1 python3 -B -c "$2" "$SCRIPTS_ABS" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then pass "$desc"; else fail "$desc" "$out"; fi
}

PY_HEAD='
import sys
sys.path.insert(0, sys.argv[1])
from supervisor.scheduler import Scheduler
from supervisor.state import State
LIMITS = {"global": 4, "providers": {"claude": 4}, "per_card": 1}
def cand(**extra):
    row = {"number": 12, "action": "start", "provider": "claude", "declared_paths": ["src/a.py"], "actual_paths": [],
           "scope_complete": True, "priority": "normal", "eligible_since": 0, "preconditions": {"state": "ready", "head_sha": None},
           "stack": {"parent": 11, "base": "fleet/11-card", "ancestors": [11]}}
    row.update(extra)
    return row
'

py_check "scheduler: a candidate with ancestors [11] is admitted over card 11's reservation" "$PY_HEAD"'
r = Scheduler(clock=lambda: 0).admit([cand()], reservations=[{"card": 11, "paths": ["src/a.py"]}], limits=LIMITS)
assert [x["number"] for x in r["admitted"]] == [12], r["waits"]
'
py_check "scheduler: the same candidate waits when card 20 holds the reservation" "$PY_HEAD"'
r = Scheduler(clock=lambda: 0).admit([cand()], reservations=[{"card": 20, "paths": ["src/a.py"]}], limits=LIMITS)
assert r["admitted"] == [] and r["waits"][0]["reason"] == "scope reserved by #20", r
'
py_check "scheduler: an active claim of card 11 does not hold the child, one of card 20 does" "$PY_HEAD"'
mine = Scheduler(clock=lambda: 0).admit([cand()], active=[{"number": 11, "provider": "claude", "paths": ["src/a.py"], "action": "start"}], limits=LIMITS)
assert [x["number"] for x in mine["admitted"]] == [12], mine["waits"]
other = Scheduler(clock=lambda: 0).admit([cand()], active=[{"number": 20, "provider": "claude", "paths": ["src/a.py"], "action": "start"}], limits=LIMITS)
assert other["admitted"] == [] and other["waits"][0]["reason"] == "scope or card conflict", other
'
py_check "scheduler: a candidate with no stack still waits on card 11's reservation" "$PY_HEAD"'
r = Scheduler(clock=lambda: 0).admit([cand(stack=None)], reservations=[{"card": 11, "paths": ["src/a.py"]}], limits=LIMITS)
assert r["admitted"] == [] and r["waits"][0]["reason"] == "scope reserved by #11", r
'
py_check "state: reserve(12, paths, exempt=(11,)) succeeds over card 11 and fails over card 20" "$PY_HEAD"'
s = State("run1")
assert s.reserve(11, ["src/a"]) is None
assert s.reserve(12, ["src/a/x"], exempt=(11,)) is None
assert 12 in s.reservations
t = State("run2")
assert t.reserve(20, ["src/a"]) is None
assert t.reserve(12, ["src/a/x"], exempt=(11,)) == 20
assert 12 not in t.reservations
assert State("run3").reserve(12, ["src/a"]) is None
u = State("run4")
u.reserve(11, ["src/a"])
assert u.reserve(12, ["src/a"]) == 11, "no exempt: card 11 still holds it"
'

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
