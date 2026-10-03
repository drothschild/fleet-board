#!/usr/bin/env bash
#
# Plain-bash tests for file-followups.sh (offline, fake gh). Routes files are
# written at run time, so their fixture paths are absolute.
# No framework, no dependencies beyond POSIX tools, jq and git.
#
# Usage: bash plugins/fleet-board/tests/test-followups.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/../scripts/file-followups.sh"
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

assert_exit_nonzero() {
  if [ "$LAST_EXIT" != 0 ]; then pass "$1"; else fail "$1" "expected a non-zero exit, got 0"; fi
}

assert_stderr_contains() {
  case "$LAST_ERR" in
    *"$2"*) pass "$1" ;;
    *) fail "$1" "expected to find '$2' in stderr, got: '$LAST_ERR'" ;;
  esac
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

# Number of argv files whose leading elements are exactly the words
calls_starting() {
  local want f n=0 k=$#
  want="$(printf '%s\n' "$@")"
  for f in "$FAKE_GH_DIR"/argv/*; do
    [ -f "$f" ] || continue
    [ "$(head -n "$k" "$f")" = "$want" ] && n=$((n + 1))
  done
  echo "$n"
}

# The argv files whose leading elements are exactly the words, in call order
files_starting() {
  local want f k=$#
  want="$(printf '%s\n' "$@")"
  for f in "$FAKE_GH_DIR"/argv/*; do
    [ -f "$f" ] || continue
    [ "$(head -n "$k" "$f")" = "$want" ] && echo "$f"
  done
}

# arg_after <argv-file> <flag>: the element that follows the flag
arg_after() { awk -v f="$2" 'prev == f { print; exit } { prev = $0 }' "$1"; }

# has_pair <argv-file> <flag> <value>
has_pair() {
  awk -v f="$2" -v v="$3" 'prev == f && $0 == v { found = 1 } { prev = $0 } END { exit found ? 0 : 1 }' "$1"
}

# The --body values of every call starting with the words, one per line, sorted
bodies_of() {
  local f
  for f in $(files_starting "$@"); do arg_after "$f" --body; done | sort
}

# Every gh call that is not an `api` read (search, create, comment)
non_api_calls() { grep -vc $'\tapi ' "$FAKE_GH_DIR/calls.log" 2>/dev/null || true; }

# Saved --body-file bodies, concatenated
all_bodies() { cat "$FAKE_GH_DIR/bodies"/* 2>/dev/null; }
body_count() { ls "$FAKE_GH_DIR/bodies" 2>/dev/null | grep -c . || true; }

# setup_case: a repo, fake gh, and a card #12 with no manager note.
# Case-specific routes go in $EXTRA_ROUTES (prepended, so they win).
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
  printf '[]\n' > "$FAKE_GH_DIR/comments.json"
  printf '[]\n' > "$FAKE_GH_DIR/empty.json"
  printf 'https://github.com/acme/toy/issues/78\n' > "$FAKE_GH_DIR/created-78.txt"
  printf 'https://github.com/acme/toy/issues/79\n' > "$FAKE_GH_DIR/created-79.txt"
  ROUTES="$FAKE_GH_DIR/routes.txt"
  {
    printf '%s' "${EXTRA_ROUTES:-}"
    cat << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
api repos/acme/toy/issues/12	0	$FIXTURES/labels/issue-12.json
api --paginate repos/acme/toy/issues/12/comments	0	$FAKE_GH_DIR/comments.json
issue list --repo acme/toy --state open --search*	0	$FAKE_GH_DIR/empty.json
issue create --repo acme/toy --title Extract math utils *	0	$FAKE_GH_DIR/created-78.txt
issue create --repo acme/toy --title Add CLI help *	0	$FAKE_GH_DIR/created-79.txt
issue create --repo acme/toy --title First bug *	0	$FAKE_GH_DIR/created-78.txt
issue create --repo acme/toy --title Second bug *	0	$FAKE_GH_DIR/created-79.txt
issue create *	0	$FIXTURES/labels/issue-created.txt
issue comment 55 *	0	-
pr comment 34 *	0	-
ROUTESEOF
  } > "$ROUTES"
  EXTRA_ROUTES=""

  unset CDPATH FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT FLEET_BOARD_CONFIG || true
  PATH="$BIN:$ORIG_PATH"
  export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH
  cd "$REPO"

  CLEANUP_DIRS+=("$REPO")
  CLEANUP_DIRS+=("$FAKE_GH_DIR")
}

# set_note <note json>: card #12's comments hold that manager note, by fleet-bot
set_note() {
  jq -cn --arg m "$MARK" --arg j "$1" '
    [{id:555,user:{login:"fleet-bot"},
      body:($m + "\n### fleet-board manager note\nState: x\n\n```json\n" + $j + "\n```\n"),
      created_at:"2026-09-28T00:01:00Z"}]' > "$FAKE_GH_DIR/comments.json"
}

# report <out_of_scope json> <bugs json>: writes a parsed report, sets REPORT
report() {
  REPORT="$FAKE_GH_DIR/report.json"
  jq -n --argjson o "$1" --argjson b "$2" \
    '{status:"done", findings:[], counts:{critical:0,important:0,minor:0}, for_the_card:"",
      out_of_scope:$o, bugs:$b, blocked_by:null, pr:34, verified:"VERIFIED: `true` -> 1 run"}' > "$REPORT"
}

run_ff() { run_check "$SCRIPT" 12 34 "$REPORT"; }

bug() {
  jq -cn --arg t "$1" --arg r "node -e \"require('./calc').div(1,0)\"" \
    '{title:$t, repro:$r, expected:"an error", observed:"a crash"}'
}

TWO_OOS='[{"title":"Extract math utils","detail":"calc.js mixes parsing and math"},{"title":"Add CLI help","detail":"there is no --help"}]'

echo "Test: file-followups.sh"
echo ""

# ---------------------------------------------------------------------------
# AC3.9: two out-of-scope items, empty note
setup_case
report "$TWO_OOS" '[]'
run_ff
assert_exit "oos: exit" 0
assert_eq "oos: 2 issue create" "$(calls_starting issue create)" 2
assert_eq "oos: 2 bodies saved" "$(body_count)" 2
N_OK=0
for f in "$FAKE_GH_DIR"/bodies/*; do
  [ -f "$f" ] || continue
  grep -qF '#12' "$f" && grep -qF 'PR #34' "$f" && N_OK=$((N_OK + 1))
done
assert_eq "oos: each body names #12 and PR #34" "$N_OK" 2
case "$(all_bodies)" in *"calc.js mixes parsing and math"*) pass "oos: body carries the detail" ;; *) fail "oos: body carries the detail" "$(all_bodies)" ;; esac
N_BUG=0
for f in $(files_starting issue create); do has_pair "$f" --label bug && N_BUG=$((N_BUG + 1)); done
assert_eq "oos: no --label bug" "$N_BUG" 0
assert_eq "oos: 2 pr comment 34" "$(calls_starting pr comment 34)" 2
assert_eq "oos: pr comment bodies" "$(bodies_of pr comment 34)" \
  "$(printf '%s\n%s' 'Out of scope, tracked as #78: Extract math utils' 'Out of scope, tracked as #79: Add CLI help')"
assert_eq "oos: output" "$(jq -S -c . <<<"$LAST_OUT" 2>/dev/null)" \
  '{"bugs_filed":[],"out_of_scope_created":[{"existing":false,"number":78,"title":"Extract math utils"},{"existing":false,"number":79,"title":"Add CLI help"}]}'

# One title already in note.out_of_scope_created
setup_case
set_note '{"out_of_scope_created":[{"title":"Extract math utils","number":51,"existing":false}]}'
report "$TWO_OOS" '[]'
run_ff
assert_exit "oos-in-note: exit" 0
assert_eq "oos-in-note: 1 issue create" "$(calls_starting issue create)" 1
assert_eq "oos-in-note: 1 pr comment" "$(calls_starting pr comment 34)" 1
assert_eq "oos-in-note: 1 search" "$(calls_starting issue list)" 1
assert_eq "oos-in-note: output" "$(jqc .out_of_scope_created)" '[{"title":"Add CLI help","number":79,"existing":false}]'

# ---------------------------------------------------------------------------
# AC3.10 files-bug
setup_case
report '[]' "[$(bug "Division by zero crashes")]"
run_ff
assert_exit "files-bug: exit" 0
assert_eq "files-bug: 1 issue create" "$(calls_starting issue create)" 1
CREATE="$(files_starting issue create | head -1)"
if [ -n "$CREATE" ]; then
  assert_true "files-bug: --label bug" has_pair "$CREATE" --label bug
  assert_true "files-bug: --label fleet:backlog" has_pair "$CREATE" --label fleet:backlog
  assert_eq "files-bug: title" "$(arg_after "$CREATE" --title)" "Division by zero crashes"
else
  fail "files-bug: --label bug" "no issue create call"
  fail "files-bug: --label fleet:backlog" "no issue create call"
  fail "files-bug: title" "no issue create call"
fi
EXPECTED_BODY="$(cat << 'BODYEOF'
## Bug
Division by zero crashes

## Repro
`node -e "require('./calc').div(1,0)"`

## Expected
an error

## Observed
a crash

Found by fleet-board while working #12 (PR #34).
BODYEOF
)"
assert_eq "files-bug: exact body" "$(all_bodies)" "$EXPECTED_BODY"
BODY="$(all_bodies)"
for want in '## Repro' "node -e \"require('./calc').div(1,0)\"" '## Expected' '## Observed' '#12'; do
  case "$BODY" in *"$want"*) pass "files-bug: body contains $want" ;; *) fail "files-bug: body contains $want" "$BODY" ;; esac
done
assert_eq "files-bug: 1 pr comment" "$(calls_starting pr comment 34)" 1
assert_eq "files-bug: pr comment body" "$(bodies_of pr comment 34)" "Bug found outside this card, filed as #77: Division by zero crashes"
assert_eq "files-bug: bugs_filed[0].existing" "$(jqc '.bugs_filed[0].existing')" "false"
assert_eq "files-bug: output" "$(jqc .)" '{"out_of_scope_created":[],"bugs_filed":[{"title":"Division by zero crashes","number":77,"existing":false}]}'

# ---------------------------------------------------------------------------
# AC3.10 bug-matches-open-issue (case differs; a near-miss title comes first)
setup_case
printf '[{"number":56,"title":"add() overflows on large ints sometimes"},{"number":55,"title":"Add() overflows on large ints"}]\n' \
  > "$FAKE_GH_DIR/match.json"
{ printf 'issue list --repo acme/toy --state open --search*\t0\t%s\n' "$FAKE_GH_DIR/match.json"; cat "$ROUTES"; } > "$ROUTES.new" && mv "$ROUTES.new" "$ROUTES"
report '[]' "[$(bug "add() overflows on large ints")]"
run_ff
assert_exit "bug-matches-open-issue: exit" 0
assert_eq "bug-matches-open-issue: no issue create" "$(calls_starting issue create)" 0
assert_eq "bug-matches-open-issue: 1 issue comment 55" "$(calls_starting issue comment 55)" 1
assert_eq "bug-matches-open-issue: issue comment body" "$(bodies_of issue comment 55)" "Also seen while working #12 (PR #34)."
case "$(bodies_of issue comment 55)" in *"Also seen while working #12"*) pass "bug-matches-open-issue: comment contains 'Also seen while working #12'" ;; *) fail "bug-matches-open-issue: comment contains 'Also seen while working #12'" "$(bodies_of issue comment 55)" ;; esac
assert_eq "bug-matches-open-issue: no comment on the near miss" "$(calls_starting issue comment 56)" 0
assert_eq "bug-matches-open-issue: 1 pr comment 34" "$(calls_starting pr comment 34)" 1
assert_eq "bug-matches-open-issue: pr comment body" "$(bodies_of pr comment 34)" "Known bug, already tracked as #55: add() overflows on large ints"
assert_eq "bug-matches-open-issue: bugs_filed" "$(jqc .bugs_filed)" '[{"title":"add() overflows on large ints","number":55,"existing":true}]'

# AC3.10 search-terms-sanitized (same run)
SEARCH="$(files_starting issue list | head -1)"
if [ -n "$SEARCH" ]; then
  S="$(arg_after "$SEARCH" --search)"
  assert_eq "search-terms-sanitized: --search argument" "$S" "add   overflows on large ints in:title"
  case "$S" in *"("*) fail "search-terms-sanitized: no '('" "$S" ;; *) pass "search-terms-sanitized: no '('" ;; esac
  assert_eq "search-terms-sanitized: full search argv" "$(cat "$SEARCH")" \
    "$(printf '%s\n' issue list --repo acme/toy --state open --search 'add   overflows on large ints in:title' --json number,title --limit 50)"
else
  fail "search-terms-sanitized: --search argument" "no issue list call"
  fail "search-terms-sanitized: no '('" "no issue list call"
  fail "search-terms-sanitized: full search argv" "no issue list call"
fi

# An out-of-scope match comments with "Out of scope, already tracked"
setup_case
printf '[{"number":55,"title":"extract MATH utils"}]\n' > "$FAKE_GH_DIR/match.json"
{ printf 'issue list --repo acme/toy --state open --search*\t0\t%s\n' "$FAKE_GH_DIR/match.json"; cat "$ROUTES"; } > "$ROUTES.new" && mv "$ROUTES.new" "$ROUTES"
report '[{"title":"Extract math utils","detail":"d"}]' '[]'
run_ff
assert_exit "oos-matches-open-issue: exit" 0
assert_eq "oos-matches-open-issue: no issue create" "$(calls_starting issue create)" 0
assert_eq "oos-matches-open-issue: pr comment body" "$(bodies_of pr comment 34)" "Out of scope, already tracked as #55: Extract math utils"
assert_eq "oos-matches-open-issue: output" "$(jqc .out_of_scope_created)" '[{"title":"Extract math utils","number":55,"existing":true}]'

# ---------------------------------------------------------------------------
# AC3.10 bug-already-in-note: no gh write calls at all
setup_case
set_note '{"bugs_filed":[{"title":"Division by zero crashes","number":60,"existing":false}]}'
report '[]' "[$(bug "Division by zero crashes")]"
run_ff
assert_exit "bug-already-in-note: exit" 0
assert_eq "bug-already-in-note: no calls besides api reads" "$(non_api_calls)" 0
assert_eq "bug-already-in-note: nothing filed" "$(jqc .bugs_filed)" '[]'

# ---------------------------------------------------------------------------
# search-failure-files-nothing
EXTRA_ROUTES="$(printf 'issue list *\t1\t-\n')
"
setup_case
report "$TWO_OOS" "[$(bug "Division by zero crashes")]"
run_ff
assert_exit "search-failure-files-nothing: exit" 1
assert_eq "search-failure-files-nothing: no issue create" "$(calls_starting issue create)" 0
assert_eq "search-failure-files-nothing: no issue comment" "$(calls_starting issue comment)" 0
assert_eq "search-failure-files-nothing: no pr comment" "$(calls_starting pr comment)" 0
assert_eq "search-failure-files-nothing: no stdout" "$LAST_OUT" ""

# second-search-fails-files-nothing: the two-pass order
EXTRA_ROUTES="$(printf 'issue list --repo acme/toy --state open --search Second bug in:title *\t1\t-\n')
"
setup_case
report '[]' "[$(bug "First bug"),$(bug "Second bug")]"
run_ff
assert_exit "second-search-fails-files-nothing: exit" 1
assert_eq "second-search-fails-files-nothing: both searched" "$(calls_starting issue list)" 2
assert_eq "second-search-fails-files-nothing: no issue create" "$(calls_starting issue create)" 0
assert_eq "second-search-fails-files-nothing: no pr comment" "$(calls_starting pr comment)" 0

# partial-create-reports-filed
EXTRA_ROUTES="$(printf 'issue create --repo acme/toy --title Second bug *\t1\t-\n')
"
setup_case
report '[]' "[$(bug "First bug"),$(bug "Second bug")]"
run_ff
assert_exit_nonzero "partial-create-reports-filed: non-zero exit"
assert_eq "partial-create-reports-filed: 2 issue create attempts" "$(calls_starting issue create)" 2
assert_eq "partial-create-reports-filed: bugs_filed is the first bug" "$(jqc .bugs_filed)" \
  '[{"title":"First bug","number":78,"existing":false}]'
assert_eq "partial-create-reports-filed: out_of_scope_created empty" "$(jqc .out_of_scope_created)" '[]'

# pr-comment-failure-still-filed
EXTRA_ROUTES="$(printf 'pr comment 34 *\t1\t-\n')
"
setup_case
report '[]' "[$(bug "Division by zero crashes")]"
run_ff
assert_exit "pr-comment-failure-still-filed: exit" 0
assert_eq "pr-comment-failure-still-filed: bugs_filed" "$(jqc .bugs_filed)" \
  '[{"title":"Division by zero crashes","number":77,"existing":false}]'
assert_stderr_contains "pr-comment-failure-still-filed: warning" "PR comment failed"
assert_stderr_contains "pr-comment-failure-still-filed: warning names the issue" "warning: PR comment failed for #77"

# existing-comment-failure-not-filed
EXTRA_ROUTES="$(printf 'issue comment 55 *\t1\t-\n')
"
setup_case
printf '[{"number":55,"title":"Add() overflows on large ints"}]\n' > "$FAKE_GH_DIR/match.json"
{ printf 'issue list --repo acme/toy --state open --search*\t0\t%s\n' "$FAKE_GH_DIR/match.json"; cat "$ROUTES"; } > "$ROUTES.new" && mv "$ROUTES.new" "$ROUTES"
report '[]' "[$(bug "add() overflows on large ints")]"
run_ff
assert_exit_nonzero "existing-comment-failure-not-filed: non-zero exit"
assert_eq "existing-comment-failure-not-filed: bugs_filed empty" "$(jqc .bugs_filed)" '[]'
assert_eq "existing-comment-failure-not-filed: no pr comment" "$(calls_starting pr comment)" 0

# duplicate-title-in-input-files-once
setup_case
report '[]' "[$(bug "Foo breaks"),$(bug "foo breaks")]"
run_ff
assert_exit "duplicate-title-in-input-files-once: exit" 0
assert_eq "duplicate-title-in-input-files-once: one issue create" "$(calls_starting issue create)" 1
assert_eq "duplicate-title-in-input-files-once: one search" "$(calls_starting issue list)" 1
assert_eq "duplicate-title-in-input-files-once: one entry" "$(jqc '.bugs_filed | length')" 1

# note-read-failure-files-nothing
EXTRA_ROUTES="$(printf 'api --paginate repos/acme/toy/issues/12/comments\t1\t-\n')
"
setup_case
report '[]' "[$(bug "Division by zero crashes")]"
run_ff
assert_exit "note-read-failure-files-nothing: exit" 1
assert_eq "note-read-failure-files-nothing: no calls besides api reads" "$(non_api_calls)" 0

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
