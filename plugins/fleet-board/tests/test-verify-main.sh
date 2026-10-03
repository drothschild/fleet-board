#!/usr/bin/env bash
#
# Plain-bash tests for verify-main.sh (offline: a local bare repo is origin,
# gh is fake-gh.sh). No framework, no dependencies beyond POSIX tools, jq and
# git.
#
# Usage: bash plugins/fleet-board/tests/test-verify-main.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/../scripts/verify-main.sh"
FIXTURES="$SCRIPT_DIR/../fixtures/gh"

unset FLEET_BOARD_CONFIG FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT || true

PASS=0
FAIL=0
LAST_OUT=""
LAST_ERR=""
LAST_EXIT=0
CLEANUP_DIRS=()
ORIG_PATH="$PATH"

if [ -x /bin/bash ]; then
  BASH_EXE="/bin/bash"
else
  BASH_EXE="bash"
fi

cleanup() {
  for dir in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do
    rm -rf "$dir" 2>/dev/null || true
  done
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

assert_exit() {
  if [ "$LAST_EXIT" = "$2" ]; then pass "$1"; else fail "$1" "expected exit $2, got $LAST_EXIT (stderr: $LAST_ERR)"; fi
}

assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}

assert_true() {
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d" "command failed: $*"; fi
}

assert_false() {
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$d" "command succeeded: $*"; else pass "$d"; fi
}

run_check() {
  local script="$1"
  shift
  local tmpout tmperr
  tmpout="$(mktemp)"
  tmperr="$(mktemp)"
  "$BASH_EXE" "$script" "$@" > "$tmpout" 2> "$tmperr"
  LAST_EXIT=$?
  LAST_OUT="$(cat "$tmpout")"
  LAST_ERR="$(cat "$tmperr")"
  rm -f "$tmpout" "$tmperr"
}

jqc() { jq -c "$1" <<<"$LAST_OUT" 2>/dev/null || echo INVALID; }

commit_file() {
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -q -m "$4"
}

# push_main <file> <content>: a new commit on origin's main; prints its sha
push_main() {
  commit_file "$SEED" "$1" "$2" "change $1"
  git -C "$SEED" push -q "$ORIGIN" main 2>/dev/null
  git -C "$SEED" rev-parse HEAD
}

line_count() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

# argv files (one element per line) whose leading elements are exactly the words
calls_starting() {
  local want f n=0 k=$#
  want="$(printf '%s\n' "$@")"
  for f in "$FAKE_GH_DIR"/argv/*; do
    [ -f "$f" ] || continue
    [ "$(head -n "$k" "$f")" = "$want" ] && n=$((n + 1))
  done
  echo "$n"
}

# The first argv file whose leading elements are exactly the words
first_call() {
  local want f k=$#
  want="$(printf '%s\n' "$@")"
  for f in "$FAKE_GH_DIR"/argv/*; do
    [ -f "$f" ] || continue
    [ "$(head -n "$k" "$f")" = "$want" ] && { echo "$f"; return; }
  done
}

# has_pair <argv-file> <flag> <value>: the flag and value are consecutive elements
has_pair() {
  awk -v f="$2" -v v="$3" 'prev == f && $0 == v { found = 1 } { prev = $0 } END { exit found ? 0 : 1 }' "$1"
}

# The single saved --body-file body
saved_body() {
  local f; f="$(ls "$FAKE_GH_DIR/bodies"/* 2>/dev/null | head -1)"
  [ -n "$f" ] && cat "$f"
}

body_count() { ls "$FAKE_GH_DIR/bodies" 2>/dev/null | grep -c . || true; }

# setup_case <typecheck command> [issue-create exit code] [files route exit code] [issue search exit code]
# The open-issue search returns $FAKE_GH_DIR/search.json ([] unless a case writes it)
setup_case() {
  local tmp; tmp="$(mktemp -d)"
  CLEANUP_DIRS+=("$tmp")
  TMPROOT="$(cd "$tmp" && pwd -P)"
  ORIGIN="$TMPROOT/origin.git"
  SEED="$TMPROOT/seed"
  REPO="$TMPROOT/repo"
  git init -q --bare "$ORIGIN"
  git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
  git init -q "$SEED"
  git -C "$SEED" config user.email "test@example.com"
  git -C "$SEED" config user.name "Test User"
  git -C "$SEED" checkout -q -b main
  commit_file "$SEED" README "toy" "A"
  mkdir -p "$SEED/tests"
  commit_file "$SEED" tests/check.sh "exit 0" "passing test"
  commit_file "$SEED" package-lock.json '{"v":1}' "lockfile"
  git -C "$SEED" push -q "$ORIGIN" main 2>/dev/null

  git clone -q "$ORIGIN" "$REPO" 2>/dev/null
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test User"
  printf '.fw/\n.fleet-board.yml\n' >> "$REPO/.git/info/exclude"
  printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\n  setup: "echo ran >> .setup-ran"\ncommands:\n  typecheck: "%s"\n  test_one: "sh {file}"\n' "$1" \
    > "$REPO/.fleet-board.yml"
  # The user's own checkout carries an uncommitted edit that must survive
  printf 'local edit\n' >> "$REPO/README"
  REPO_HEAD="$(git -C "$REPO" rev-parse HEAD)"

  FAKE_GH_DIR="$TMPROOT/gh"
  mkdir -p "$FAKE_GH_DIR/bin"
  ln -s "$SCRIPT_DIR/fake-gh.sh" "$FAKE_GH_DIR/bin/gh"
  printf '{"files":[{"path":"tests/check.sh"},{"path":"src/calc.js"},{"path":"tests/gone.sh"}]}\n' > "$FAKE_GH_DIR/files.json"
  ROUTES="$FAKE_GH_DIR/routes.txt"
  cat > "$ROUTES" << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
pr view 7 --repo acme/toy --json files	${3:-0}	$FAKE_GH_DIR/files.json
issue create *	${2:-0}	$FIXTURES/labels/issue-created.txt
issue list --repo acme/toy --state open --search *	${4:-0}	$FAKE_GH_DIR/search.json
ROUTESEOF
  printf '[]\n' > "$FAKE_GH_DIR/search.json"

  unset CDPATH FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT FLEET_BOARD_CONFIG || true
  PATH="$FAKE_GH_DIR/bin:$ORIG_PATH"
  FAKE_GH_ROUTES="$ROUTES"
  export FAKE_GH_DIR FAKE_GH_ROUTES PATH
  cd "$REPO"
  BASE="$(mkdir -p "$REPO/.fw" && cd "$REPO/.fw" && pwd -P)"
  MC="$BASE/main-check"
}

reset_gh_log() { rm -rf "$FAKE_GH_DIR/argv" "$FAKE_GH_DIR/bodies" "$FAKE_GH_DIR/calls.log" "$FAKE_GH_DIR/count"; }

# The user's checkout: same HEAD, same branch, the uncommitted edit intact
assert_user_checkout_untouched() {
  assert_eq "$1: user's HEAD unchanged" "$(git -C "$REPO" rev-parse HEAD)" "$REPO_HEAD"
  assert_eq "$1: user's branch unchanged" "$(git -C "$REPO" symbolic-ref --short HEAD 2>/dev/null)" "main"
  assert_eq "$1: user's uncommitted edit intact" "$(git -C "$REPO" status --porcelain)" " M README"
}

echo "Test: verify-main.sh"
echo ""

# ---------------------------------------------------------------------------
# AC4.7 green
setup_case true
run_check "$SCRIPT" 12 7
assert_exit "green: exit" 0
assert_eq "green: ok true" "$(jqc .ok)" "true"
assert_eq "green: commit is origin/main" "$(jqc .commit)" "\"$(git -C "$ORIGIN" rev-parse main)\""
assert_eq "green: results (typecheck, then the touched test that exists on main)" "$(jqc .results)" \
  '[{"cmd":"true","exit":0},{"cmd":"sh tests/check.sh","exit":0}]'
assert_eq "green: no p0_card" "$(jqc 'has("p0_card")')" "false"
assert_false "green: no issue create" grep -q 'issue create' "$FAKE_GH_DIR/calls.log"
assert_eq "green: exact files lookup" "$(calls_starting pr view 7 --repo acme/toy --json files)" 1
assert_eq "green: setup ran in main-check" "$(line_count "$MC/.setup-ran")" 1
assert_false "green: main-check is detached" git -C "$MC" symbolic-ref -q HEAD
assert_eq "green: main-check at origin/main" "$(git -C "$MC" rev-parse HEAD)" "$(git -C "$ORIGIN" rev-parse main)"
assert_user_checkout_untouched "green"

# ---------------------------------------------------------------------------
# AC4.8 red: main moved to a commit whose touched test fails
RED_SHA="$(push_main tests/check.sh "exit 1")"
reset_gh_log
run_check "$SCRIPT" 12 7
assert_exit "red: exit" 0
assert_eq "red: ok false" "$(jqc .ok)" "false"
assert_eq "red: commit is the new origin/main" "$(jqc .commit)" "\"$RED_SHA\""
assert_eq "red: results" "$(jqc .results)" '[{"cmd":"true","exit":0},{"cmd":"sh tests/check.sh","exit":1}]'
assert_eq "red: p0_card" "$(jqc .p0_card)" "77"
assert_eq "red: one issue create" "$(calls_starting issue create)" 1
CREATE="$(first_call issue create)"
if [ -n "$CREATE" ]; then
  assert_true "red: title" has_pair "$CREATE" --title "[P0] main is red after #7"
  assert_true "red: --label fleet:backlog" has_pair "$CREATE" --label fleet:backlog
  assert_true "red: --repo acme/toy" has_pair "$CREATE" --repo acme/toy
else
  fail "red: title" "no issue create call"
  fail "red: --label fleet:backlog" "no issue create call"
  fail "red: --repo acme/toy" "no issue create call"
fi
BODY="$(saved_body)"
case "$BODY" in *"Merged PR: #7"*) pass "red: body names the merged PR" ;; *) fail "red: body names the merged PR" "body: $BODY" ;; esac
case "$BODY" in *"#12"*) pass "red: body links the card" ;; *) fail "red: body links the card" "body: $BODY" ;; esac
case "$BODY" in *"$RED_SHA"*) pass "red: body names the commit" ;; *) fail "red: body names the commit" "body: $BODY" ;; esac
case "$BODY" in *'`sh tests/check.sh` exited 1'*) pass "red: body names the failing command" ;; *) fail "red: body names the failing command" "body: $BODY" ;; esac
case "$BODY" in *'`true`'*) fail "red: body omits the passing command" "body: $BODY" ;; *) pass "red: body omits the passing command" ;; esac
assert_eq "red: setup not re-run (no lockfile change)" "$(line_count "$MC/.setup-ran")" 1
assert_user_checkout_untouched "red"

# A lockfile change between main-check heads re-runs setup
push_main package-lock.json '{"v":2}' >/dev/null
reset_gh_log
run_check "$SCRIPT" 12 7
assert_exit "lockfile-change: exit" 0
assert_eq "lockfile-change: setup re-ran" "$(line_count "$MC/.setup-ran")" 2

# ---------------------------------------------------------------------------
# typecheck-red
setup_case false
run_check "$SCRIPT" 12 7
assert_exit "typecheck-red: exit" 0
assert_eq "typecheck-red: ok false" "$(jqc .ok)" "false"
assert_eq "typecheck-red: results" "$(jqc .results)" '[{"cmd":"false","exit":1},{"cmd":"sh tests/check.sh","exit":0}]'
assert_eq "typecheck-red: p0_card" "$(jqc .p0_card)" "77"
assert_eq "typecheck-red: one issue create" "$(calls_starting issue create)" 1
assert_eq "typecheck-red: one body" "$(body_count)" 1

# ---------------------------------------------------------------------------
# p0-create-fails: a red main whose P0 card cannot be filed does not report success
setup_case false 1
run_check "$SCRIPT" 12 7
assert_exit "p0-create-fails: exit" 1
assert_eq "p0-create-fails: no stdout" "$LAST_OUT" ""

# files-lookup-fails: nothing is run and nothing is filed
setup_case false 0 1
run_check "$SCRIPT" 12 7
assert_exit "files-lookup-fails: exit" 1
assert_eq "files-lookup-fails: no stdout" "$LAST_OUT" ""
assert_eq "files-lookup-fails: no issue create" "$(calls_starting issue create)" 0

# ---------------------------------------------------------------------------
# p0-exists: a retry finds the open P0 card (exact title, any case) and reuses it
SEARCH_ARGS=(issue list --repo acme/toy --state open --search " P0  main is red after  7 in:title" --json number,title --limit 50)
setup_case false
printf '[{"number":70,"title":"[P0] main is red after #70"},{"number":88,"title":"[p0] MAIN is red after #7"}]\n' > "$FAKE_GH_DIR/search.json"
run_check "$SCRIPT" 12 7
assert_exit "p0-exists: exit" 0
assert_eq "p0-exists: p0_card is the existing card" "$(jqc .p0_card)" "88"
assert_eq "p0-exists: ok false" "$(jqc .ok)" "false"
assert_eq "p0-exists: no issue create" "$(calls_starting issue create)" 0
assert_eq "p0-exists: one exact search" "$(calls_starting "${SEARCH_ARGS[@]}")" 1

# p0-near-miss: only "#70" is open; "#7" is filed anew
setup_case false
printf '[{"number":70,"title":"[P0] main is red after #70"}]\n' > "$FAKE_GH_DIR/search.json"
run_check "$SCRIPT" 12 7
assert_exit "p0-near-miss: exit" 0
assert_eq "p0-near-miss: p0_card is the new card" "$(jqc .p0_card)" "77"
assert_eq "p0-near-miss: one issue create" "$(calls_starting issue create)" 1
assert_eq "p0-near-miss: searched first" "$(calls_starting "${SEARCH_ARGS[@]}")" 1

# p0-search-fails: never file blind
setup_case false 0 0 1
run_check "$SCRIPT" 12 7
assert_exit "p0-search-fails: exit 1" 1
assert_eq "p0-search-fails: no stdout" "$LAST_OUT" ""
assert_eq "p0-search-fails: no issue create" "$(calls_starting issue create)" 0

# p0-search-garbage: an unexpected answer is a failure too
setup_case false
printf 'garbage\n' > "$FAKE_GH_DIR/search.json"
run_check "$SCRIPT" 12 7
assert_exit "p0-search-garbage: exit 1" 1
assert_eq "p0-search-garbage: no issue create" "$(calls_starting issue create)" 0

# ---------------------------------------------------------------------------
# Projects backend: a reused P0 issue must be on the board. A previous run can
# have created the issue and then failed to add it to the project; a search
# finds it, so without this check it would never reach the Backlog column.
# use_projects <status of #88 on project 1, or "" for no item> [graphql exit]
use_projects() {
  printf 'board:\n  backend: github-projects\n  repo: acme/toy\n  project_number: 1\nworktrees:\n  dir: .fw\n  setup: "echo ran >> .setup-ran"\ncommands:\n  typecheck: "false"\n  test_one: "sh {file}"\n' \
    > "$REPO/.fleet-board.yml"
  printf '{"number":88,"title":"[p0] MAIN is red after #7","html_url":"https://github.com/acme/toy/issues/88","body":"","labels":[]}\n' \
    > "$FAKE_GH_DIR/issue-88.json"
  if [ -n "$1" ]; then
    jq -nc --arg s "$1" '{data:{repository:{issue:{projectItems:{nodes:[{id:"PVTI_88",project:{number:1},fieldValueByName:{name:$s}}]}}}}}'
  else
    jq -nc '{data:{repository:{issue:{projectItems:{nodes:[]}}}}}'
  fi > "$FAKE_GH_DIR/items-88.json"
  cat >> "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
project view 1 --owner acme --format json	0	$FIXTURES/projects/project-view.json
project field-list 1 --owner acme --format json*	0	$FIXTURES/projects/field-list.json
api repos/acme/toy/issues/88	0	$FAKE_GH_DIR/issue-88.json
api --paginate repos/acme/toy/issues/88/comments	0	$FIXTURES/tick/common/empty.json
api graphql*	${2:-0}	$FAKE_GH_DIR/items-88.json
project item-add *	0	$FIXTURES/projects/item-add.json
project item-edit *	0	$FIXTURES/projects/item-edit-ok.json
ROUTESEOF
  printf '[{"number":88,"title":"[p0] MAIN is red after #7"}]\n' > "$FAKE_GH_DIR/search.json"
}

# p0-reuse-off-board: added to the project and put in Backlog
setup_case false
use_projects ""
run_check "$SCRIPT" 12 7
assert_exit "p0-reuse-off-board: exit" 0
assert_eq "p0-reuse-off-board: p0_card is the existing card" "$(jqc .p0_card)" "88"
assert_eq "p0-reuse-off-board: no issue create" "$(calls_starting issue create)" 0
assert_eq "p0-reuse-off-board: added to project 1" \
  "$(calls_starting project item-add 1 --owner acme --url https://github.com/acme/toy/issues/88)" 1
EDIT="$(first_call project item-edit)"
if [ -n "$EDIT" ]; then
  assert_true "p0-reuse-off-board: status set to Backlog" has_pair "$EDIT" --single-select-option-id f75ad846
else
  fail "p0-reuse-off-board: status set to Backlog" "no item-edit call"
fi

# p0-reuse-on-board: already an item of the project, in any column: left alone
setup_case false
use_projects "In progress"
run_check "$SCRIPT" 12 7
assert_exit "p0-reuse-on-board: exit" 0
assert_eq "p0-reuse-on-board: p0_card" "$(jqc .p0_card)" "88"
assert_eq "p0-reuse-on-board: not re-added" "$(calls_starting project item-add)" 0
assert_eq "p0-reuse-on-board: not moved" "$(calls_starting project item-edit)" 0

# p0-reuse-board-check-fails: never reports a P0 card it could not confirm
setup_case false
use_projects "" 1
run_check "$SCRIPT" 12 7
assert_exit "p0-reuse-board-check-fails: exit 1" 1
assert_eq "p0-reuse-board-check-fails: no stdout" "$LAST_OUT" ""
assert_eq "p0-reuse-board-check-fails: no issue create" "$(calls_starting issue create)" 0

# p0-create-projects: a newly created P0 is not read back for the board check
# (board-create.sh just added it to the project and set Backlog)
setup_case false
use_projects ""
printf '[]\n' > "$FAKE_GH_DIR/search.json"
printf '{"number":77,"title":"[P0] main is red after #7","html_url":"https://github.com/acme/toy/issues/77","body":"","labels":[]}\n' \
  > "$FAKE_GH_DIR/issue-77.json"
printf 'api repos/acme/toy/issues/77\t0\t%s\napi --paginate repos/acme/toy/issues/77/comments\t0\t%s\n' \
  "$FAKE_GH_DIR/issue-77.json" "$FIXTURES/tick/common/empty.json" >> "$ROUTES"
run_check "$SCRIPT" 12 7
assert_exit "p0-create-projects: exit" 0
assert_eq "p0-create-projects: p0_card is the new card" "$(jqc .p0_card)" "77"
assert_eq "p0-create-projects: one issue create" "$(calls_starting issue create)" 1
assert_eq "p0-create-projects: no read of the new P0" "$(calls_starting api repos/acme/toy/issues/77)" 0
assert_eq "p0-create-projects: added to the project once (by the create)" "$(calls_starting project item-add)" 1

# p0-reuse-env-created: a CREATED variable in the caller's environment must
# not make a reused P0 look newly created and skip the board check
setup_case false
use_projects ""
export CREATED='{"number":1}'
run_check "$SCRIPT" 12 7
unset CREATED
assert_exit "p0-reuse-env-created: exit" 0
assert_eq "p0-reuse-env-created: p0_card is the existing card" "$(jqc .p0_card)" "88"
assert_eq "p0-reuse-env-created: still added to project 1" \
  "$(calls_starting project item-add 1 --owner acme --url https://github.com/acme/toy/issues/88)" 1

# The labels backend reuses without a board read: there, one gh issue create
# both files the P0 and labels it fleet:backlog, so no run can leave it off the
# board
setup_case false
printf '[{"number":88,"title":"[P0] main is red after #7"}]\n' > "$FAKE_GH_DIR/search.json"
run_check "$SCRIPT" 12 7
assert_eq "p0-reuse-labels: no card read" "$(calls_starting api repos/acme/toy/issues/88)" 0

# green never searches
setup_case true
run_check "$SCRIPT" 12 7
assert_eq "green: no issue search" "$(calls_starting issue list)" 0

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
