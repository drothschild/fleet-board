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

# A ready card waiting on a dependency shows why
# ready_card <n> <title> <body>: puts one ready card on the board (routes prepended)
ready_card() {
  local pre="$FAKE_GH_DIR/pre.txt"
  jq -cn --argjson n "$1" --arg t "$2" --arg b "$3" \
    '{number:$n, title:$t, html_url:"u", body:$b, labels:[{name:"fleet:ready"}]}' > "$FAKE_GH_DIR/issue-$1.json"
  printf '[]\n' > "$FAKE_GH_DIR/comments-$1.json"
  printf '[%s]\n' "$(item "$1" "$2" fleet:ready)" > "$FAKE_GH_DIR/list-ready-dep.json"
  {
    printf 'issue list --repo acme/toy --label fleet:ready --state open --json number,title,url,labels --limit 500\t0\t%s\n' "$FAKE_GH_DIR/list-ready-dep.json"
    printf 'api repos/acme/toy/issues/%s\t0\t%s\n' "$1" "$FAKE_GH_DIR/issue-$1.json"
    printf 'api --paginate repos/acme/toy/issues/%s/comments\t0\t%s\n' "$1" "$FAKE_GH_DIR/comments-$1.json"
    printf '{"state":"OPEN","stateReason":null}\n' > "$FAKE_GH_DIR/dep-open.json"
    printf '{"state":"CLOSED","stateReason":"COMPLETED"}\n' > "$FAKE_GH_DIR/dep-done.json"
    printf 'issue view 22 --repo acme/toy --json state,stateReason\t0\t%s\n' "$FAKE_GH_DIR/dep-open.json"
    printf 'issue view 7 --repo other/repo --json state,stateReason\t0\t%s\n' "$FAKE_GH_DIR/dep-done.json"
    cat "$ROUTES"
  } > "$pre"
  mv "$pre" "$ROUTES"
}
ACC=$'Do it.\n\n## Acceptance\n- works\n\n'

setup_case
ready_card 30 "Needs api" "${ACC}## Depends on
- #22
- other/repo#7
"
run_check "$SCRIPT"
assert_exit "waiting: exit" 0
assert_stdout_contains "waiting: the unmet dependency and its state follow the card" \
  "$(printf 'ready\n  #30 Needs api · round — · PR — · —/— · waits for acme/toy#22 (open)')"

setup_case
ready_card 30 "Needs api" "${ACC}## Depends on
- other/repo#7
"
run_check "$SCRIPT"
assert_exit "dependencies met: exit" 0
assert_stdout_contains "dependencies met: no waiting reason" "$(printf 'ready\n  #30 Needs api · round — · PR — · —/—\n')"
assert_stdout_not_contains "dependencies met: no waiting reason text" "waits for"

setup_case
ready_card 30 "Needs api" "${ACC}## Depends on
- #99
"
printf 'issue view 99 --repo acme/toy --json state,stateReason\t1\t-\n' | cat - "$ROUTES" > "$FAKE_GH_DIR/r2" && mv "$FAKE_GH_DIR/r2" "$ROUTES"
run_check "$SCRIPT"
assert_exit "dependency lookup failure: exit 1" 1
assert_stdout_contains "dependency lookup failure: the card is marked" "  #30 Needs api · round — · PR — · —/— · dependencies unreadable"

# A body bigger than the pipe buffer still shows the waiting reason
setup_case
ready_card 30 "Needs api" "## Depends on
- #22

$(head -c 80000 /dev/zero | tr '\0' 'x')

## Acceptance
- works
"
run_check "$SCRIPT"
assert_stdout_contains "large body: the waiting reason is still shown" "waits for acme/toy#22 (open)"

# The same with ## Acceptance first
setup_case
ready_card 30 "Needs api" "## Acceptance
- works

## Depends on
- #22

$(head -c 80000 /dev/zero | tr '\0' 'x')
"
run_check "$SCRIPT"
assert_stdout_contains "large body, Acceptance first: the waiting reason is still shown" "waits for acme/toy#22 (open)"

# ---------------------------------------------------------------------------
# The dependency graph. chain_case puts A (#40, in progress) <- B (#41) <- C (#42)
# on the board, C also waiting on other/repo#9, plus #43 with no dependency.
chain_case() {
  setup_case
  local pre="$FAKE_GH_DIR/pre.txt" n
  printf '[%s]\n' "$(item 40 "Task A" fleet:in_progress)" > "$FAKE_GH_DIR/list-ip-chain.json"
  printf '[%s,%s,%s]\n' "$(item 41 "Task B" fleet:ready)" "$(item 42 "Task C" fleet:ready)" "$(item 43 "Task D" fleet:ready)" \
    > "$FAKE_GH_DIR/list-ready-chain.json"
  printf '{"state":"OPEN","stateReason":null}\n' > "$FAKE_GH_DIR/dep-open.json"
  jq -cn '{number:40, title:"Task A", html_url:"u", body:"b", labels:[{name:"fleet:in_progress"}]}' > "$FAKE_GH_DIR/issue-40.json"
  printf '[]\n' > "$FAKE_GH_DIR/comments-40.json"
  jq -cn --arg b "${ACC}## Depends on
- #40
" '{number:41, title:"Task B", html_url:"u", body:$b, labels:[{name:"fleet:ready"}]}' > "$FAKE_GH_DIR/issue-41.json"
  jq -cn --arg b "${ACC}## Depends on
- #41
- other/repo#9
" '{number:42, title:"Task C", html_url:"u", body:$b, labels:[{name:"fleet:ready"}]}' > "$FAKE_GH_DIR/issue-42.json"
  jq -cn --arg b "${ACC}" '{number:43, title:"Task D", html_url:"u", body:$b, labels:[{name:"fleet:ready"}]}' > "$FAKE_GH_DIR/issue-43.json"
  {
    printf 'issue list --repo acme/toy --label fleet:in_progress --state open --json number,title,url,labels --limit 500\t0\t%s\n' "$FAKE_GH_DIR/list-ip-chain.json"
    printf 'issue list --repo acme/toy --label fleet:ready --state open --json number,title,url,labels --limit 500\t0\t%s\n' "$FAKE_GH_DIR/list-ready-chain.json"
    for n in 40 41 42 43; do
      [ -f "$FAKE_GH_DIR/comments-$n.json" ] || printf '[]\n' > "$FAKE_GH_DIR/comments-$n.json"
      printf 'api repos/acme/toy/issues/%s\t0\t%s\n' "$n" "$FAKE_GH_DIR/issue-$n.json"
      printf 'api --paginate repos/acme/toy/issues/%s/comments\t0\t%s\n' "$n" "$FAKE_GH_DIR/comments-$n.json"
    done
    printf 'issue view 40 --repo acme/toy --json state,stateReason\t0\t%s\n' "$FAKE_GH_DIR/dep-open.json"
    printf 'issue view 41 --repo acme/toy --json state,stateReason\t0\t%s\n' "$FAKE_GH_DIR/dep-open.json"
    printf 'issue view 9 --repo other/repo --json state,stateReason\t0\t%s\n' "$FAKE_GH_DIR/dep-open.json"
    cat "$ROUTES"
  } > "$pre"
  mv "$pre" "$ROUTES"
}

chain_case
run_check "$SCRIPT"
assert_exit "graph: exit" 0
assert_stdout_contains "graph: B grouped under its blocker A" "$(printf 'blocker #40\n  #41\n')"
assert_stdout_contains "graph: C grouped under its blocker B" "$(printf 'blocker #41\n  #42\n')"
assert_stdout_contains "graph: cross-repo blocker keeps its repo prefix" "$(printf 'blocker other/repo#9\n  #42\n')"
assert_stdout_contains "graph: critical path is the longest chain" "critical path: #40 -> #41 -> #42"
assert_stdout_contains "graph: can start now names the Ready card with no unmet dependency" "can start now: #43"
assert_stdout_not_contains "graph: a waiting card is not startable" "can start now: #41"
GRAPH_CALLS="$(grep -c 'issue list' "$FAKE_GH_DIR/calls.log")"
if [ "$GRAPH_CALLS" = 5 ]; then pass "graph: one gh list call per column (5)"; else fail "graph: one gh list call per column" "expected 5 issue list calls, got $GRAPH_CALLS"; fi
if grep -Eq 'issue (edit|comment|create|close)|-X (POST|PATCH|PUT|DELETE)|--method' "$FAKE_GH_DIR/calls.log"; then
  fail "graph: read-only" "a mutating gh call was made"
else pass "graph: read-only (no mutating gh call)"; fi

# No dependencies: no graph output at all
setup_case
ready_card 30 "Plain" "${ACC}"
run_check "$SCRIPT"
assert_stdout_not_contains "no dependencies: no graph" "blocker"
assert_stdout_not_contains "no dependencies: no critical path" "critical path"
assert_stdout_not_contains "no dependencies: no can-start line" "can start now"

# A dependency cycle among Ready cards: no crash, critical path is (none)
setup_case
cyc_pre="$FAKE_GH_DIR/pre.txt"
printf '[%s,%s]\n' "$(item 50 "Cyc A" fleet:ready)" "$(item 51 "Cyc B" fleet:ready)" > "$FAKE_GH_DIR/list-ready-cyc.json"
printf '{"state":"OPEN","stateReason":null}\n' > "$FAKE_GH_DIR/dep-open.json"
jq -cn --arg b "${ACC}## Depends on
- #51
" '{number:50, title:"Cyc A", html_url:"u", body:$b, labels:[{name:"fleet:ready"}]}' > "$FAKE_GH_DIR/issue-50.json"
jq -cn --arg b "${ACC}## Depends on
- #50
" '{number:51, title:"Cyc B", html_url:"u", body:$b, labels:[{name:"fleet:ready"}]}' > "$FAKE_GH_DIR/issue-51.json"
{
  printf 'issue list --repo acme/toy --label fleet:ready --state open --json number,title,url,labels --limit 500\t0\t%s\n' "$FAKE_GH_DIR/list-ready-cyc.json"
  for n in 50 51; do
    printf '[]\n' > "$FAKE_GH_DIR/comments-$n.json"
    printf 'api repos/acme/toy/issues/%s\t0\t%s\n' "$n" "$FAKE_GH_DIR/issue-$n.json"
    printf 'api --paginate repos/acme/toy/issues/%s/comments\t0\t%s\n' "$n" "$FAKE_GH_DIR/comments-$n.json"
    printf 'issue view %s --repo acme/toy --json state,stateReason\t0\t%s\n' "$n" "$FAKE_GH_DIR/dep-open.json"
  done
  cat "$ROUTES"
} > "$cyc_pre"
mv "$cyc_pre" "$ROUTES"
run_check "$SCRIPT"
assert_exit "cycle: exit 0" 0
assert_stdout_contains "cycle: critical path is (none)" "critical path: (none)"
assert_stdout_contains "cycle: can start now still printed" "can start now: (none)"

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
