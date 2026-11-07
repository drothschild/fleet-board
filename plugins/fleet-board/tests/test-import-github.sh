#!/usr/bin/env bash
#
# Plain-bash tests for scripts/import-github.sh: a GitHub board (labels or a
# Projects board) read through a fake gh becomes a local store in the card
# shape (acceptance, blocked_by, pr_url), with the same numbers, the states,
# the comments and the manager note re-authored to the local login. The fake
# logs every call; no write verb may appear.
#
# Usage: bash plugins/fleet-board/tests/test-import-github.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPTS="$SCRIPT_DIR/../scripts"
IMPORT="$SCRIPTS/import-github.sh"
FIX="$SCRIPT_DIR/../fixtures/gh/import"

unset FLEET_BOARD_CONFIG FLEET_BOARD_LOCK_WAIT FLEET_BOARD_LIST_LIMIT || true
export FLEET_BOARD_USER="localme"

PASS=0
FAIL=0
LAST_OUT=""
LAST_ERR=""
LAST_EXIT=0
CLEANUP_DIRS=()
ORIG_PATH="$PATH"

if [ -x /bin/bash ]; then BASH_EXE="/bin/bash"; else BASH_EXE="bash"; fi

cleanup() {
  for dir in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do rm -rf "$dir" 2>/dev/null || true; done
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

assert_exit() {
  if [ "$LAST_EXIT" = "$2" ]; then pass "$1"; else fail "$1" "expected exit $2, got $LAST_EXIT (stderr: '$LAST_ERR')"; fi
}
assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}
assert_stdout_contains() {
  case "$LAST_OUT" in *"$2"*) pass "$1" ;; *) fail "$1" "expected '$2' in stdout: '$LAST_OUT'" ;; esac
}
assert_stderr_contains() {
  case "$LAST_ERR" in *"$2"*) pass "$1" ;; *) fail "$1" "expected '$2' in stderr: '$LAST_ERR'" ;; esac
}

# run_in <dir> <cmd...>
run_in() {
  local dir="$1" tmpout tmperr
  shift
  tmpout="$(mktemp)"; tmperr="$(mktemp)"
  ( unset CDPATH; cd "$dir" && "$@" ) > "$tmpout" 2> "$tmperr"
  LAST_EXIT=$?
  LAST_OUT="$(cat "$tmpout")"; LAST_ERR="$(cat "$tmperr")"
  rm -f "$tmpout" "$tmperr"
}

# setup_repo <routes-dir> [extra YAML]: a git repo with a local config and an
# empty store (next = 1, as init leaves it), and the fake gh on PATH.
setup_repo() {
  REPO="$(mktemp -d)"; CLEANUP_DIRS+=("$REPO")
  git init -q "$REPO"
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test User"
  { printf 'board:\n  repo: acme/toy\n'; [ -n "${2:-}" ] && printf '%s\n' "$2"; printf 'worktrees:\n  dir: .fw\n'; } > "$REPO/.fleet-board.yml"
  git -C "$REPO" add .fleet-board.yml
  git -C "$REPO" commit -q -m "initial"
  mkdir -p "$REPO/.fleet-board/cards"
  printf '1\n' > "$REPO/.fleet-board/next"
  STORE="$REPO/.fleet-board"

  FAKE_GH_DIR="$(mktemp -d)"; CLEANUP_DIRS+=("$FAKE_GH_DIR")
  mkdir -p "$FAKE_GH_DIR/bin"
  ln -s "$SCRIPT_DIR/fake-gh.sh" "$FAKE_GH_DIR/bin/gh"
  FAKE_GH_ROUTES="$FIX/$1/routes"
  PATH="$FAKE_GH_DIR/bin:$ORIG_PATH"
  export FAKE_GH_DIR FAKE_GH_ROUTES PATH
}

# no_write_calls <desc>: the fake logged no GitHub write verb
no_write_calls() {
  local bad
  bad="$(cut -f2- "$FAKE_GH_DIR/calls.log" 2>/dev/null \
    | grep -E 'issue (edit|create|comment|close|delete|reopen|transfer)|label (create|edit|delete)|project item-(edit|add|archive|delete)|-X (POST|PATCH|PUT|DELETE)|--method' )"
  assert_eq "$1" "$bad" ""
}

# ---------------------------------------------------------------- labels board
echo "import-github: labels board"
setup_repo labels
run_in "$REPO" "$BASH_EXE" "$IMPORT" --repo acme/toy
assert_exit "labels: exits 0" 0
assert_eq "labels: one line per imported card" "$(printf '%s\n' "$LAST_OUT" | grep -c .)" "3"
assert_stdout_contains "labels: line for #12" "imported #12 in_review"
assert_stdout_contains "labels: line for #13" "imported #13 done"
assert_stdout_contains "labels: line for #14" "imported #14 human_qa"
assert_eq "labels: an issue with no state label is not imported" "$([ -e "$STORE/cards/15.json" ] && echo yes)" ""
assert_stderr_contains "labels: the skipped issue is named" "#15"
assert_stderr_contains "labels: the outside dependency is warned about" "other/repo#3"
assert_eq "labels: next is the highest number plus one" "$(tr -d '[:space:]' < "$STORE/next")" "15"
C12="$(cat "$STORE/cards/12.json" 2>/dev/null)"
assert_eq "labels: #12 keeps its number" "$(jq -r .number <<<"$C12" 2>/dev/null)" "12"
assert_eq "labels: #12 title" "$(jq -r .title <<<"$C12" 2>/dev/null)" "Add subtract"
assert_eq "labels: #12 state from the fleet label" "$(jq -r .state <<<"$C12" 2>/dev/null)" "in_review"
assert_eq "labels: #12 state label dropped, others kept" "$(jq -c .labels <<<"$C12" 2>/dev/null)" '["bug"]'
assert_eq "labels: #12 acceptance field" "$(jq -c .acceptance <<<"$C12" 2>/dev/null)" '["subtract(2,5) returns -3","subtract(0,0) returns 0"]'
assert_eq "labels: #12 blocked_by field" "$(jq -c .blocked_by <<<"$C12" 2>/dev/null)" '[13]'
assert_eq "labels: #12 body keeps only the prose" "$(jq -r .body <<<"$C12" 2>/dev/null)" "Do it."
assert_eq "labels: #12 pr_url from the note's pr" "$(jq -r .pr_url <<<"$C12" 2>/dev/null)" "https://github.com/acme/toy/pull/34"
assert_eq "labels: #12 pr_url_source is note" "$(jq -r .pr_url_source <<<"$C12" 2>/dev/null)" "note"
assert_eq "labels: #12 created_at kept" "$(jq -r .created_at <<<"$C12" 2>/dev/null)" "2026-10-01T10:00:00Z"
assert_eq "labels: #12 updated_at kept" "$(jq -r .updated_at <<<"$C12" 2>/dev/null)" "2026-10-02T11:00:00Z"
assert_eq "labels: #12 local comment ids" "$(jq -c '[.comments[].id]' <<<"$C12" 2>/dev/null)" "[1,2,3]"
assert_eq "labels: #12 next_comment_id follows" "$(jq -r .next_comment_id <<<"$C12" 2>/dev/null)" "4"
assert_eq "labels: plain comment keeps its author" "$(jq -r '.comments[0].author' <<<"$C12" 2>/dev/null)" "alice"
assert_eq "labels: note re-authored to the local login" "$(jq -r '.comments[1].author' <<<"$C12" 2>/dev/null)" "localme"
assert_eq "labels: a marker comment by another login keeps its author" "$(jq -r '.comments[2].author' <<<"$C12" 2>/dev/null)" "mallory"
C14="$(cat "$STORE/cards/14.json" 2>/dev/null)"
assert_eq "labels: #14 outside dependency kept as prose" "$(jq -r .body <<<"$C14" 2>/dev/null | grep -c 'other/repo#3')" "1"
assert_eq "labels: #14 blocked_by empty" "$(jq -c .blocked_by <<<"$C14" 2>/dev/null)" "[]"
assert_eq "labels: #14 has no pr_url" "$(jq -r .pr_url <<<"$C14" 2>/dev/null)" "null"
no_write_calls "labels: the fake logged no write verb"
assert_eq "labels: issues were listed (open and closed)" "$(grep -c 'issue list --repo acme/toy --state all' "$FAKE_GH_DIR/calls.log")" "1"
assert_eq "labels: no comments read for the skipped issue" "$(grep -c 'issues/15/comments' "$FAKE_GH_DIR/calls.log")" "0"

run_in "$REPO" "$BASH_EXE" "$SCRIPTS/note.sh" get 12
assert_exit "labels: note.sh get on the imported card exits 0" 0
assert_eq "labels: note.sh get finds the re-authored note" "$(jq -r .branch <<<"$LAST_OUT" 2>/dev/null)" "fleet/12-add-subtract"

echo "import-github: refuses a store that has cards"
BEFORE="$(cat "$STORE/cards/12.json")"
run_in "$REPO" "$BASH_EXE" "$IMPORT" --repo acme/toy
assert_exit "refusal: second run without --force exits 1" 1
assert_stderr_contains "refusal: names --force" "--force"
assert_eq "refusal: existing card untouched" "$(cat "$STORE/cards/12.json")" "$BEFORE"
printf '40\n' > "$STORE/next"
run_in "$REPO" "$BASH_EXE" "$IMPORT" --repo acme/toy --force
assert_exit "refusal: --force run exits 0" 0
assert_eq "refusal: --force keeps a higher next" "$(tr -d '[:space:]' < "$STORE/next")" "40"

echo "import-github: --dry-run writes nothing"
setup_repo labels
run_in "$REPO" "$BASH_EXE" "$IMPORT" --repo acme/toy --dry-run
assert_exit "dry-run: exits 0" 0
assert_stdout_contains "dry-run: prints the line for #12" "imported #12 in_review"
assert_eq "dry-run: same number of lines" "$(printf '%s\n' "$LAST_OUT" | grep -c .)" "3"
assert_eq "dry-run: no card written" "$(find "$STORE/cards" -name '*.json' | wc -l | tr -d ' ')" "0"
assert_eq "dry-run: next untouched" "$(tr -d '[:space:]' < "$STORE/next")" "1"
no_write_calls "dry-run: the fake logged no write verb"

echo "import-github: usage and validation"
setup_repo labels
run_in "$REPO" "$BASH_EXE" "$IMPORT"
assert_exit "usage: --repo is required" 2
run_in "$REPO" "$BASH_EXE" "$IMPORT" --repo "not a repo"
assert_exit "usage: a malformed --repo" 2
run_in "$REPO" "$BASH_EXE" "$IMPORT" --repo acme/toy --owner acme
assert_exit "usage: --owner without --project" 2
FLEET_BOARD_LIST_LIMIT=4 run_in "$REPO" "$BASH_EXE" "$IMPORT" --repo acme/toy
assert_exit "truncation: a listing of exactly the limit exits 1" 1
assert_stderr_contains "truncation: names the remedy" "FLEET_BOARD_LIST_LIMIT"
assert_eq "truncation: nothing written" "$(find "$STORE/cards" -name '*.json' | wc -l | tr -d ' ')" "0"
# A failed comments read stops the run before any card is written
BROKEN="$(mktemp -d)"; CLEANUP_DIRS+=("$BROKEN")
{
  printf 'api --paginate repos/acme/toy/issues/13/comments\t1\t-\n'
  printf 'api user\t0\t%s\n' "$FIX/../labels/user.json"
  printf 'issue list --repo acme/toy --state all *\t0\t%s\n' "$FIX/labels/issues.json"
  printf 'api --paginate repos/acme/toy/issues/12/comments\t0\t%s\n' "$FIX/labels/comments-12.json"
  printf 'api --paginate repos/acme/toy/issues/14/comments\t0\t%s\n' "$FIX/../labels/comments-none.json"
} > "$BROKEN/routes"
FAKE_GH_ROUTES="$BROKEN/routes" run_in "$REPO" "$BASH_EXE" "$IMPORT" --repo acme/toy
assert_exit "validation: a failed comments read exits 1" 1
assert_eq "validation: nothing written after a failed read" "$(find "$STORE/cards" -name '*.json' | wc -l | tr -d ' ')" "0"

# ---------------------------------------------------------------- Projects board
echo "import-github: Projects board"
setup_repo projects "$(printf '  states: { in_progress: "In progress" }\nreview:\n  stages:\n    - name: security\n      agent: "acme:security-reviewer"')"
run_in "$REPO" "$BASH_EXE" "$IMPORT" --repo acme/toy --project 1
assert_exit "projects: exits 0" 0
assert_eq "projects: one line per imported card" "$(printf '%s\n' "$LAST_OUT" | grep -c .)" "3"
assert_eq "projects: #21 state from Review: <stage>" "$(jq -r .state "$STORE/cards/21.json" 2>/dev/null)" "review_security"
assert_eq "projects: #20 state Done" "$(jq -r .state "$STORE/cards/20.json" 2>/dev/null)" "done"
assert_eq "projects: #19 state from a configured column name" "$(jq -r .state "$STORE/cards/19.json" 2>/dev/null)" "in_progress"
assert_eq "projects: an issue off the project is not imported" "$([ -e "$STORE/cards/22.json" ] && echo yes)" ""
assert_eq "projects: #21 labels kept" "$(jq -c .labels "$STORE/cards/21.json" 2>/dev/null)" '["needs-security-review"]'
assert_eq "projects: #21 acceptance" "$(jq -c .acceptance "$STORE/cards/21.json" 2>/dev/null)" '["bad passwords are refused"]'
assert_eq "projects: #19 blocked_by from the board-repo ref" "$(jq -c .blocked_by "$STORE/cards/19.json" 2>/dev/null)" '[20]'
assert_stderr_contains "projects: a dependency on an issue not imported is warned about" "#22"
assert_eq "projects: #21 foreign marker comment is not the note" "$(jq -r '.comments[0].author' "$STORE/cards/21.json" 2>/dev/null)" "mallory"
assert_eq "projects: #21 no pr_url from an untrusted note" "$(jq -r .pr_url "$STORE/cards/21.json" 2>/dev/null)" "null"
assert_eq "projects: next" "$(tr -d '[:space:]' < "$STORE/next")" "22"
assert_eq "projects: owner defaults to the repo owner" "$(grep -c 'project item-list 1 --owner acme --format json' "$FAKE_GH_DIR/calls.log")" "1"
no_write_calls "projects: the fake logged no write verb"
run_in "$REPO" "$BASH_EXE" "$SCRIPTS/board-list.sh" review_security
assert_eq "projects: the imported card lists in its stage column" "$(jq -c '[.[].number]' <<<"$LAST_OUT" 2>/dev/null)" "[21]"

echo "import-github: an unknown Projects column stops the run"
setup_repo projects
run_in "$REPO" "$BASH_EXE" "$IMPORT" --repo acme/toy --project 1
assert_exit "projects: an unmapped column exits 1" 1
assert_stderr_contains "projects: names the column" "In progress"
assert_eq "projects: nothing written on an unmapped column" "$(find "$STORE/cards" -name '*.json' | wc -l | tr -d ' ')" "0"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
