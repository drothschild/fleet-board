#!/usr/bin/env bash
#
# Plain-bash tests for deps.sh (offline, fake gh): parse reads a card body's
# "## Depends on" section, check looks each dependency up.
# No framework, no dependencies beyond POSIX tools, jq and git.
#
# Usage: bash plugins/fleet-board/tests/test-deps.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/../scripts/deps.sh"

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

# jq -c of the last stdout; INVALID when it does not parse
jqc() { jq -c "$1" <<<"$LAST_OUT" 2>/dev/null || echo INVALID; }

# assert_jq <desc> <filter> <expected compact JSON>
assert_jq() { assert_eq "$1" "$(jqc "$2")" "$3"; }

# setup_repo [extra lines for the board: section]: a repo for acme/toy
setup_repo() {
  REPO="$(mktemp -d)"
  git init -q "$REPO"
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test User"
  {
    printf 'board:\n  repo: acme/toy\n'
    [ -n "${1:-}" ] && printf '%s\n' "$1"
    printf 'worktrees:\n  dir: .fw\n'
  } > "$REPO/.fleet-board.yml"
  git -C "$REPO" add .fleet-board.yml
  git -C "$REPO" commit -q -m "initial"
  CLEANUP_DIRS+=("$REPO")
  unset CDPATH FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT FLEET_BOARD_CONFIG || true
  cd "$REPO"
}

# parse_body <body text>: runs deps.sh parse on the body
parse_body() {
  local f
  setup_repo
  f="$(mktemp)"
  CLEANUP_DIRS+=("$f")
  printf '%s\n' "$1" > "$f"
  run_check "$SCRIPT" parse "$f"
}

echo "Test: deps.sh"
echo ""

# ---------------------------------------------------------------------------
# parse
echo "parse"

parse_body "Do the thing.

## Acceptance
- it works

## Depends on
- #22
- other/repo#7

* acme/toy#5
## Notes
- #99"
assert_exit "parse: exit" 0
assert_jq "parse: same-repo, other-repo and star bullets; the next section is not read" '.refs' \
  '[{"repo":"acme/toy","number":22,"ref":"acme/toy#22"},{"repo":"other/repo","number":7,"ref":"other/repo#7"},{"repo":"acme/toy","number":5,"ref":"acme/toy#5"}]'
assert_jq "parse: no warnings" '.warnings' '[]'

parse_body "Body.

## Acceptance
- ok"
assert_exit "parse: no section, exit" 0
assert_jq "parse: no section gives no refs and no warnings" '.' '{"refs":[],"warnings":[]}'

parse_body "## Depends on
- #22
- not a dependency
- #22 (and a note)
see the other card
- acme/toy#22
- #x1
- Other/Repo#3"
assert_exit "parse: bad lines, exit" 0
assert_jq "parse: only the valid bullets count, duplicates dropped" '[.refs[].ref]' '["acme/toy#22","Other/Repo#3"]'
assert_jq "parse: every other nonblank line is a warning naming the line" '.warnings' \
  '["unrecognized dependency line: - not a dependency","unrecognized dependency line: - #22 (and a note)","unrecognized dependency line: see the other card","unrecognized dependency line: - #x1"]'

parse_body "## depends on
- #4"
assert_jq "parse: the heading is case-insensitive" '[.refs[].ref]' '["acme/toy#4"]'

parse_body "## Depends on
- #4

## Depends on
- #5"
assert_jq "parse: a repeated section is read too" '[.refs[].ref]' '["acme/toy#4","acme/toy#5"]'

parse_body "## Dependson
- #4"
assert_jq "parse: a different heading is not the section" '.refs' '[]'

setup_repo
run_check "$SCRIPT" parse "$REPO/no-such-file"
assert_exit "parse: missing file is a usage error" 2
run_check "$SCRIPT" parse
assert_exit "parse: no file is a usage error" 2
run_check "$SCRIPT" frobnicate
assert_exit "unknown subcommand is a usage error" 2

# ---------------------------------------------------------------------------
# check
echo ""
echo "check"

# setup_check [extra YAML]: a repo plus a fake gh with an empty routes file
setup_check() {
  setup_repo "${1:-}"
  FAKE_GH_DIR="$(mktemp -d)"
  CLEANUP_DIRS+=("$FAKE_GH_DIR")
  BIN="$FAKE_GH_DIR/bin"
  mkdir -p "$BIN"
  ln -s "$SCRIPT_DIR/fake-gh.sh" "$BIN/gh"
  FAKE_GH_ROUTES="$FAKE_GH_DIR/routes.txt"
  : > "$FAKE_GH_ROUTES"
  PATH="$BIN:$ORIG_PATH"
  export FAKE_GH_DIR FAKE_GH_ROUTES PATH
  ROUTE_SEQ=0
}

# route <glob> <exit code> [response body]
route() {
  local f
  ROUTE_SEQ=$((ROUTE_SEQ + 1))
  f="$FAKE_GH_DIR/resp-$ROUTE_SEQ"
  printf '%s\n' "${3:-}" > "$f"
  printf '%s\t%s\t%s\n' "$1" "$2" "$f" >> "$FAKE_GH_ROUTES"
}

# issue_route <repo> <n> <state> <reason>: gh issue view <n> --repo <repo> --json state,stateReason
issue_route() {
  route "issue view $2 --repo $1 --json state,stateReason" 0 \
    "$(jq -cn --arg s "$3" --arg r "$4" '{state: $s, stateReason: (if $r == "" then null else $r end)}')"
}

# item_route <n> <Status name, "" for no Status, "-" for not on the project>
item_route() {
  local nodes='[]'
  case "$2" in
    -) ;;
    "") nodes='[{"id":"PVTI_x","project":{"number":1},"fieldValueByName":null}]' ;;
    *) nodes="$(jq -cn --arg s "$2" '[{id: "PVTI_x", project: {number: 1}, fieldValueByName: {name: $s}}]')" ;;
  esac
  route "api graphql *-F n=$1" 0 \
    "$(jq -cn --argjson nodes "$nodes" '{data: {repository: {issue: {projectItems: {nodes: $nodes}}}}}')"
}

# lookup_cmd: the command a failed lookup named on stderr
lookup_cmd() { sed -n 's/^deps-lookup-failed: //p' <<<"$LAST_ERR"; }

PROJECTS_YML="$(printf '  backend: github-projects\n  project_number: 1')"

setup_check
issue_route acme/toy 22 CLOSED COMPLETED
issue_route other/repo 7 OPEN ""
run_check "$SCRIPT" check 12 '[{"repo":"acme/toy","number":22,"ref":"acme/toy#22"},{"repo":"other/repo","number":7,"ref":"other/repo#7"}]'
assert_exit "check: exit" 0
assert_jq "check: closed completed is met; an open issue is unmet" '.unmet' '[{"ref":"other/repo#7","status":"open"}]'
assert_jq "check: no warnings" '.warnings' '[]'
assert_eq "check: one issue view per dependency" "$(grep -c 'issue view' "$FAKE_GH_DIR/calls.log")" 2

setup_check
run_check "$SCRIPT" check 12 '[]'
assert_exit "check: no refs, exit" 0
assert_jq "check: no refs gives nothing unmet" '.' '{"unmet":[],"warnings":[]}'

setup_check
issue_route acme/toy 22 CLOSED NOT_PLANNED
issue_route acme/toy 23 CLOSED DUPLICATE
issue_route acme/toy 24 CLOSED ""
run_check "$SCRIPT" check 12 '[{"repo":"acme/toy","number":22,"ref":"acme/toy#22"},{"repo":"acme/toy","number":23,"ref":"acme/toy#23"},{"repo":"acme/toy","number":24,"ref":"acme/toy#24"}]'
assert_exit "check: closed otherwise, exit" 0
assert_jq "check: closed as not planned, a duplicate or with no reason is unmet" '.unmet' \
  '[{"ref":"acme/toy#22","status":"closed as not planned"},{"ref":"acme/toy#23","status":"closed as duplicate"},{"ref":"acme/toy#24","status":"closed"}]'
assert_jq "check: only not planned warns" '.warnings' '["#12 depends on acme/toy#22, which was closed as not planned"]'
assert_eq "check: labels backend makes no project lookup" "$(grep -c 'graphql' "$FAKE_GH_DIR/calls.log")" 0

# lookups that fail
setup_check
route "issue view 22 --repo acme/toy --json state,stateReason" 1
run_check "$SCRIPT" check 12 '[{"repo":"acme/toy","number":22,"ref":"acme/toy#22"}]'
assert_exit "check: a failed lookup exits 1" 1
assert_eq "check: a failed lookup prints nothing on stdout" "$LAST_OUT" ""
assert_eq "check: a failed lookup names the command on stderr" "$(lookup_cmd)" "gh issue view 22 --repo acme/toy --json state,stateReason"

setup_check
route "issue view 22 --repo acme/toy --json state,stateReason" 0 '{"state":"WEIRD"}'
run_check "$SCRIPT" check 12 '[{"repo":"acme/toy","number":22,"ref":"acme/toy#22"}]'
assert_exit "check: an unexpected response exits 1" 1
assert_eq "check: an unexpected response names the command" "$(lookup_cmd)" "gh issue view 22 --repo acme/toy --json state,stateReason (unexpected response)"

# the Projects backend: Status of a same-board card
setup_check "$PROJECTS_YML"
issue_route acme/toy 22 OPEN ""
item_route 22 "Done"
run_check "$SCRIPT" check 12 '[{"repo":"acme/toy","number":22,"ref":"acme/toy#22"}]'
assert_exit "check: projects, Status Done, exit" 0
assert_jq "check: Status equal to the done column is met even when the issue is open" '.unmet' '[]'

setup_check "$PROJECTS_YML"
issue_route acme/toy 22 OPEN ""
item_route 22 "In Review"
issue_route acme/toy 23 OPEN ""
item_route 23 "-"
issue_route acme/toy 24 OPEN ""
item_route 24 ""
run_check "$SCRIPT" check 12 '[{"repo":"acme/toy","number":22,"ref":"acme/toy#22"},{"repo":"acme/toy","number":23,"ref":"acme/toy#23"},{"repo":"acme/toy","number":24,"ref":"acme/toy#24"}]'
assert_jq "check: the column name is the status; no item or no Status falls back to the state" '.unmet' \
  '[{"ref":"acme/toy#22","status":"In Review"},{"ref":"acme/toy#23","status":"open"},{"ref":"acme/toy#24","status":"open"}]'

setup_check "$PROJECTS_YML"
issue_route acme/toy 22 OPEN ""
item_route 22 "Won't Do"
run_check "$SCRIPT" check 12 '[{"repo":"acme/toy","number":22,"ref":"acme/toy#22"}]'
assert_jq "check: Status Won't Do is unmet" '.unmet' '[{"ref":"acme/toy#22","status":"Won'"'"'t Do"}]'
assert_jq "check: Status Won't Do warns as not planned" '.warnings' '["#12 depends on acme/toy#22, which was closed as not planned"]'

setup_check "$PROJECTS_YML"
issue_route acme/toy 22 CLOSED COMPLETED
issue_route other/repo 7 OPEN ""
run_check "$SCRIPT" check 12 '[{"repo":"acme/toy","number":22,"ref":"acme/toy#22"},{"repo":"other/repo","number":7,"ref":"other/repo#7"}]'
assert_jq "check: projects, closed completed and another repo's issue need no project lookup" '.unmet' '[{"ref":"other/repo#7","status":"open"}]'
assert_eq "check: projects, no graphql call was made" "$(grep -c 'graphql' "$FAKE_GH_DIR/calls.log")" 0

setup_check "$PROJECTS_YML"
issue_route acme/toy 22 OPEN ""
route "api graphql *-F n=22" 1
run_check "$SCRIPT" check 12 '[{"repo":"acme/toy","number":22,"ref":"acme/toy#22"}]'
assert_exit "check: a failed project lookup exits 1" 1
assert_eq "check: a failed project lookup names its command" "$(lookup_cmd)" "gh api graphql (project items of acme/toy#22)"

# usage
setup_check
run_check "$SCRIPT" check
assert_exit "check: no arguments is a usage error" 2
run_check "$SCRIPT" check x '[]'
assert_exit "check: a non-numeric card is a usage error" 2
run_check "$SCRIPT" check 12 'not json'
assert_exit "check: refs that are not a JSON array are a usage error" 2

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
