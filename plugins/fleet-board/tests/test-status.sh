#!/usr/bin/env bash
#
# Plain-bash tests for status.sh (offline, fake gh). Routes files are written
# at run time, so their fixture paths are absolute.
# No framework, no dependencies beyond POSIX tools, jq and git.
#
# Usage: bash plugins/fleet-board/tests/test-status.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/../scripts/status.sh"
FIXTURES="$SCRIPT_DIR/../fixtures/gh"
MARK='<!-- fleet-board:manager-note -->'

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

assert_stdout_exact() {
  if [ "$LAST_OUT" = "$2" ]; then pass "$1"; else fail "$1" "expected stdout: '$2', got: '$LAST_OUT'"; fi
}

assert_stdout_contains() {
  case "$LAST_OUT" in
    *"$2"*) pass "$1" ;;
    *) fail "$1" "expected '$2' in stdout, got: '$LAST_OUT'" ;;
  esac
}

assert_stdout_not_contains() {
  case "$LAST_OUT" in
    *"$2"*) fail "$1" "did not expect '$2' in stdout" ;;
    *) pass "$1" ;;
  esac
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

# list_route <label> <state> <cards json>: a column listing
list_route() {
  printf '%s\n' "$3" > "$FAKE_GH_DIR/list-$1.json"
  printf 'issue list --repo acme/toy --label fleet:%s --state %s --json number,title,url,labels --limit 500\t0\t%s\n' \
    "$1" "$2" "$FAKE_GH_DIR/list-$1.json" >> "$ROUTES"
}

# card <n> <title> <label> <note json or empty>: the card's read routes
card() {
  jq -cn --argjson n "$1" --arg t "$2" --arg l "$3" \
    '{number:$n, title:$t, html_url:"https://github.com/acme/toy/issues/\($n)", body:"b", labels:[{name:$l}]}' \
    > "$FAKE_GH_DIR/issue-$1.json"
  if [ -n "$4" ]; then
    jq -cn --arg m "$MARK" --arg j "$4" '
      [{id:555,user:{login:"fleet-bot"},
        body:($m + "\n### fleet-board manager note\nState: x\n\n```json\n" + $j + "\n```\n"),
        created_at:"2026-09-28T00:01:00Z"}]' > "$FAKE_GH_DIR/comments-$1.json"
  else
    printf '[]\n' > "$FAKE_GH_DIR/comments-$1.json"
  fi
  printf 'api repos/acme/toy/issues/%s\t0\t%s\n' "$1" "$FAKE_GH_DIR/issue-$1.json" >> "$ROUTES"
  printf 'api --paginate repos/acme/toy/issues/%s/comments\t0\t%s\n' "$1" "$FAKE_GH_DIR/comments-$1.json" >> "$ROUTES"
}

# item <n> <title> <label>: one listing row
item() { jq -cn --argjson n "$1" --arg t "$2" --arg l "$3" '{number:$n, title:$t, url:"u", labels:[{name:$l}]}'; }

# setup_case [extra routes, prepended]
setup_case() {
  REPO="$(mktemp -d)"
  git init -q "$REPO"
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test User"
  printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\n' > "$REPO/.fleet-board.yml"
  git -C "$REPO" add .fleet-board.yml
  git -C "$REPO" commit -q -m "initial"

  FAKE_GH_DIR="$(mktemp -d)"
  BIN="$FAKE_GH_DIR/bin"
  mkdir -p "$BIN"
  ln -s "$SCRIPT_DIR/fake-gh.sh" "$BIN/gh"
  ROUTES="$FAKE_GH_DIR/routes.txt"
  printf '%s' "${1:-}" > "$ROUTES"
  printf 'api user\t0\t%s\n' "$FIXTURES/labels/user.json" >> "$ROUTES"

  list_route ready open '[]'
  list_route in_progress open '[]'
  list_route in_review open "[$(item 12 "Add subtract" fleet:in_review),$(item 14 "Fix divide" fleet:in_review)]"
  list_route human_qa open '[]'
  list_route blocked open "[$(item 15 "Parse flags" fleet:blocked)]"
  list_route backlog open "[$(item 20 "Later thing" fleet:backlog)]"
  list_route done all '[]'
  list_route wont_do all '[]'
  card 12 "Add subtract" fleet:in_review \
    '{"state":"in_review","round":2,"pr":34,"models":{"implementor":"sonnet","reviewer":"opus","fixer":"sonnet"}}'
  card 14 "Fix divide" fleet:in_review \
    '{"state":"in_review","round":1,"pr":40,"models":{"implementor":"opus","reviewer":"opus","fixer":"opus"}}'
  card 15 "Parse flags" fleet:blocked ""
  card 20 "Later thing" fleet:backlog ""

  unset CDPATH FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT FLEET_BOARD_CONFIG || true
  PATH="$BIN:$ORIG_PATH"
  export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH
  cd "$REPO"

  CLEANUP_DIRS+=("$REPO")
  CLEANUP_DIRS+=("$FAKE_GH_DIR")
}

echo "Test: status.sh"
echo ""

LINE12='  #12 Add subtract · round 2 · PR #34 · sonnet/opus'
LINE14='  #14 Fix divide · round 1 · PR #40 · opus/opus'
LINE15='  #15 Parse flags · round — · PR — · —/—'
LINE20='  #20 Later thing · round — · PR — · —/—'

# ---------------------------------------------------------------------------
setup_case
run_check "$SCRIPT"
assert_exit "default: exit" 0
assert_stdout_contains "two-in-review: #12 with its round and PR" "$LINE12"
assert_stdout_contains "two-in-review: #14 with its round and PR" "$LINE14"
assert_stdout_contains "empty-ready: (none)" "$(printf 'ready\n  (none)\n')"
assert_stdout_not_contains "backlog absent without --all: no section" "backlog"
assert_stdout_not_contains "backlog absent without --all: no card" "#20"
assert_stdout_exact "default: exact output" "$(printf '%s\n' \
  ready '  (none)' \
  in_progress '  (none)' \
  in_review "$LINE12" "$LINE14" \
  human_qa '  (none)' \
  blocked "$LINE15")"

run_check "$SCRIPT" --all
assert_exit "--all: exit" 0
assert_stdout_contains "backlog present with --all" "$(printf 'backlog\n%s' "$LINE20")"
assert_stdout_exact "--all: exact output" "$(printf '%s\n' \
  ready '  (none)' \
  in_progress '  (none)' \
  in_review "$LINE12" "$LINE14" \
  human_qa '  (none)' \
  blocked "$LINE15" \
  backlog "$LINE20" \
  done '  (none)' \
  wont_do '  (none)')"

run_check "$SCRIPT" --bogus
assert_exit "unknown flag: exit 2" 2

# A column that cannot be listed fails the command
setup_case "$(printf 'issue list --repo acme/toy --label fleet:blocked *\t1\t-\n')
"
run_check "$SCRIPT"
assert_exit "list-failure: exit 1" 1

# A note that cannot be read is shown as such, and the command fails
setup_case "$(printf 'api --paginate repos/acme/toy/issues/14/comments\t1\t-\n')
"
run_check "$SCRIPT"
assert_exit "note-failure: exit 1" 1
assert_stdout_contains "note-failure: other cards still listed" "$LINE12"
assert_stdout_contains "note-failure: the card is marked" "  #14 Fix divide · note unreadable"

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
