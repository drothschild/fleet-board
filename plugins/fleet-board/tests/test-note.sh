#!/usr/bin/env bash
#
# Plain-bash tests for note.sh, the manager-note codec (offline, fake gh).
# No framework, no dependencies beyond POSIX tools, jq and git.
#
# Usage: bash plugins/fleet-board/tests/test-note.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/../scripts/note.sh"
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

assert_stderr_exact() {
  if [ "$LAST_ERR" = "$2" ]; then pass "$1"; else fail "$1" "expected exact stderr: '$2', got: '$LAST_ERR'"; fi
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

run_note() { run_check "$SCRIPT" "$@"; }

# Compact, key-sorted form of a JSON text; prints INVALID when it does not parse
canon() { jq -S -c . <<<"$1" 2>/dev/null || echo INVALID; }

setup_case() {
  REPO="$(mktemp -d)"
  git init -q "$REPO"
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test User"
  cat > "$REPO/.fleet-board.yml" << 'YML'
board:
  repo: acme/toy
worktrees:
  dir: .fw
YML
  git -C "$REPO" add .fleet-board.yml
  git -C "$REPO" commit -q -m "initial"

  FAKE_GH_DIR="$(mktemp -d)"
  ROUTES="$FAKE_GH_DIR/routes.txt"
  BIN="$FAKE_GH_DIR/bin"
  mkdir -p "$BIN"
  ln -s "$SCRIPT_DIR/fake-gh.sh" "$BIN/gh"
  printf '[]\n' > "$FAKE_GH_DIR/comments.json"
  printf '{}\n' > "$FAKE_GH_DIR/patched.json"

  # Routes written at run time use absolute paths (Phase conventions)
  cat > "$ROUTES" << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
api repos/acme/toy/issues/12	0	$FIXTURES/labels/issue-12.json
api --paginate repos/acme/toy/issues/12/comments	0	$FAKE_GH_DIR/comments.json
api -X POST repos/acme/toy/issues/12/comments --input -	0	$FIXTURES/labels/comment-created.json
api -X PUT repos/acme/toy/issues/comments/9001/pin	0	-
api -X PATCH repos/acme/toy/issues/comments/555 --input -	0	$FAKE_GH_DIR/patched.json
ROUTESEOF

  # Reset environment between cases
  unset CDPATH FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT FLEET_BOARD_CONFIG || true
  PATH="$BIN:$ORIG_PATH"
  export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH

  cd "$REPO"
  BASE="$(mkdir -p "$REPO/.fw" && cd "$REPO/.fw" && pwd -P)"

  CLEANUP_DIRS+=("$REPO")
  CLEANUP_DIRS+=("$FAKE_GH_DIR")
}

# set_note_json <json text>: the card's comments hold one manager note (by
# fleet-bot) whose fenced json block is exactly that text
set_note_json() {
  jq -cn --arg m "$MARK" --arg j "$1" '
    [{id:501,user:{login:"alice"},body:"plain comment",created_at:"2026-09-28T00:00:00Z"},
     {id:555,user:{login:"fleet-bot"},
      body:($m + "\n### fleet-board manager note\nState: x\n\n```json\n" + $j + "\n```\n"),
      created_at:"2026-09-28T00:01:00Z"}]' > "$FAKE_GH_DIR/comments.json"
}

# set_note_body <text>: the note comment body after the marker line
set_note_body() {
  jq -cn --arg m "$MARK" --arg b "$1" \
    '[{id:555,user:{login:"fleet-bot"},body:($m + "\n" + $b),created_at:"2026-09-28T00:01:00Z"}]' \
    > "$FAKE_GH_DIR/comments.json"
}

clear_inputs() { rm -rf "$FAKE_GH_DIR/inputs"; }

# Number of bodies sent with --input - since the last clear_inputs
input_count() { ls "$FAKE_GH_DIR/inputs" 2>/dev/null | grep -c . || true; }

# The comment body sent in the single --input - since the last clear_inputs
posted_body() {
  local f
  f="$(ls "$FAKE_GH_DIR/inputs"/* 2>/dev/null | head -1)"
  [ -n "$f" ] && jq -r .body "$f"
}

# The JSON between the ```json line and the next ``` line of a body
block_json() { printf '%s\n' "$1" | awk '$0 == "```json" { on = 1; next } on && $0 == "```" { exit } on { print }'; }

# feed_back: the note the last write posted becomes the card's stored note
feed_back() {
  local b; b="$(posted_body)"
  jq -cn --arg b "$b" '[{id:555,user:{login:"fleet-bot"},body:$b,created_at:"2026-09-28T00:05:00Z"}]' \
    > "$FAKE_GH_DIR/comments.json"
}

echo "Test: note.sh"
echo ""

# ---------------------------------------------------------------------------
# AC1.5 round-trip: put then get of a note with every key set
setup_case
cat > "$FAKE_GH_DIR/full.json" << JSONEOF
{
  "state": "in_review",
  "branch": "fleet/12-add-subtract",
  "worktree": "$BASE/12-add-subtract",
  "pr": 34,
  "round": 2,
  "models": {"implementor": "opus", "reviewer": "opus", "fixer": "opus"},
  "escalated": true,
  "escalated_at_round": 2,
  "last_verified": "VERIFIED: node --test test/calc.test.js -> 3 passing",
  "last_review": {"round": 2, "sha": "abc1234", "critical": 0, "important": 1,
                  "findings": [{"severity": "Important", "text": "subtract(2,5) returns 3"}]},
  "blocked_findings": [{"severity": "Critical", "text": "test deleted"}],
  "blocking_pr": 41,
  "merged_pr": 30,
  "main_check": {"commit": "def5678", "ok": true, "results": ["typecheck ok", "test/calc.test.js ok"]},
  "out_of_scope_created": [{"title": "extract math utils", "number": 51, "existing": false}],
  "bugs_filed": [{"title": "calc crashes on NaN", "number": 52, "existing": true}],
  "pending_followups": {"out_of_scope": [], "bugs": [{"title": "overflow"}], "pr": 34},
  "report_errors": [{"role": "implementor", "error": "missing VERIFIED line"}],
  "implementor_attempts": 2,
  "action_failures": 2,
  "last_action_error": "fatal: branch fleet/12-add-subtract is checked out elsewhere",
  "updated_at": "2020-01-01T00:00:00Z"
}
JSONEOF
clear_inputs
run_note put 12 "$FAKE_GH_DIR/full.json"
assert_exit "round-trip: put exit" 0
assert_eq "round-trip: put sent exactly one body" "$(input_count)" 1
BODY="$(posted_body)"
posted="$(canon "$(block_json "$BODY")")"
if [ "$(jq -r '.updated_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' <<<"$posted" 2>/dev/null)" = true ] \
   && [ "$(jq -r .updated_at <<<"$posted")" != "2020-01-01T00:00:00Z" ]; then
  pass "round-trip: put sets updated_at to a fresh ISO timestamp"
else
  fail "round-trip: put sets updated_at to a fresh ISO timestamp" "got $(jq -c .updated_at <<<"$posted" 2>/dev/null)"
fi
feed_back
run_note get 12
assert_exit "round-trip: get exit" 0
assert_stderr_exact "round-trip: get writes nothing to stderr" ""
assert_eq "round-trip: get returns the note put, apart from updated_at" \
  "$(jq -S -c 'del(.updated_at)' <<<"$LAST_OUT" 2>/dev/null)" \
  "$(jq -S -c 'del(.updated_at)' "$FAKE_GH_DIR/full.json")"

# The rendered body: marker, heading, summary line, exactly one fenced json block
assert_eq "rendered-body: first line is the marker" "$(printf '%s\n' "$BODY" | sed -n 1p)" "$MARK"
assert_eq "rendered-body: heading line" "$(printf '%s\n' "$BODY" | sed -n 2p)" "### fleet-board manager note"
assert_eq "rendered-body: summary line" "$(printf '%s\n' "$BODY" | sed -n 3p)" \
  'State: in_review · Round: 2 · PR: #34 · Branch: `fleet/12-add-subtract` · Action failures: 2 (last: fatal: branch fleet/12-add-subtract is checked out elsewhere)'
assert_eq "rendered-body: exactly one \`\`\`json line" "$(printf '%s\n' "$BODY" | grep -cx '```json')" 1
assert_eq "rendered-body: exactly one closing fence line" "$(printf '%s\n' "$BODY" | grep -cx '```')" 1

# ---------------------------------------------------------------------------
# put fills every missing key with its default; summary shows dashes for nulls
setup_case
printf '{"state":"ready"}\n' > "$FAKE_GH_DIR/min.json"
clear_inputs
run_note put 12 "$FAKE_GH_DIR/min.json"
assert_exit "put-fills-defaults: exit" 0
BODY="$(posted_body)"
assert_eq "put-fills-defaults: every key with its default" \
  "$(jq -S -c 'del(.updated_at)' <<<"$(block_json "$BODY")" 2>/dev/null)" \
  '{"action_failures":0,"blocked_findings":[],"blocking_pr":null,"branch":null,"bugs_filed":[],"escalated":null,"escalated_at_round":null,"implementor_attempts":0,"last_action_error":null,"last_review":null,"last_verified":null,"main_check":null,"merged_pr":null,"models":null,"out_of_scope_created":[],"pending_followups":null,"pr":null,"report_errors":[],"round":null,"state":"ready","worktree":null}'
assert_eq "put-fills-defaults: summary line with nothing set" "$(printf '%s\n' "$BODY" | sed -n 3p)" \
  'State: ready · Round: — · PR: — · Branch: —'

# put refuses a note that get would reject (it never writes one)
setup_case
printf '{"state":"ready","branch":"main; rm -rf ~"}\n' > "$FAKE_GH_DIR/bad.json"
clear_inputs
run_note put 12 "$FAKE_GH_DIR/bad.json"
assert_exit "put-rejects-invalid: exit" 1
assert_eq "put-rejects-invalid: nothing posted" "$(input_count)" 0
assert_stderr_contains "put-rejects-invalid: names the field" "branch"

# put of a file that is not a JSON object
setup_case
printf 'not json\n' > "$FAKE_GH_DIR/junk.json"
clear_inputs
run_note put 12 "$FAKE_GH_DIR/junk.json"
assert_exit "put-rejects-non-json: exit" 1
assert_eq "put-rejects-non-json: nothing posted" "$(input_count)" 0

# ---------------------------------------------------------------------------
# get with no note, and with a note that has no JSON block
setup_case
run_note get 12
assert_exit "get-no-note: exit" 0
assert_stdout_exact "get-no-note: prints {}" "{}"
set_note_body $'### fleet-board manager note\nState: ready\n'
run_note get 12
assert_exit "get-no-json-block: exit" 0
assert_stdout_exact "get-no-json-block: prints {}" "{}"

# get with a JSON block that will not parse exits 1
setup_case
set_note_json '{"state": "ready",'
run_note get 12
assert_exit "get-unparsable-block: exit" 1
assert_stdout_exact "get-unparsable-block: no stdout" ""

# get when the card cannot be read fails closed
setup_case
printf 'api user\t0\t%s\n' "$FIXTURES/labels/user.json" > "$ROUTES"
printf 'api repos/acme/toy/issues/12\t1\t-\n' >> "$ROUTES"
run_note get 12
assert_exit "get-read-failure: exit" 1
assert_stdout_exact "get-read-failure: no stdout" ""

# a note by another login is not the manager note
setup_case
jq -cn --arg m "$MARK" '[{id:777,user:{login:"mallory"},body:($m + "\n```json\n{\"state\":\"done\"}\n```\n"),created_at:"2026-09-28T00:00:00Z"}]' > "$FAKE_GH_DIR/comments.json"
run_note get 12
assert_stdout_exact "get-foreign-note: ignored, prints {}" "{}"

# ---------------------------------------------------------------------------
# merge preserves untouched keys
setup_case
set_note_json '{"state":"in_review","branch":"fleet/12-add-subtract","pr":34,"round":1,"models":{"implementor":"sonnet","reviewer":"opus","fixer":"sonnet"}}'
printf '{"round":2,"models":{"implementor":"opus"}}\n' > "$FAKE_GH_DIR/patch.json"
clear_inputs
run_note merge 12 "$FAKE_GH_DIR/patch.json"
assert_exit "merge-preserves: exit" 0
assert_eq "merge-preserves: replaced the stored note in place (one PATCH)" "$(grep -c 'api -X PATCH repos/acme/toy/issues/comments/555' "$FAKE_GH_DIR/calls.log")" 1
assert_eq "merge-preserves: merged note" \
  "$(jq -S -c '{state,branch,pr,round,models}' <<<"$(block_json "$(posted_body)")" 2>/dev/null)" \
  '{"branch":"fleet/12-add-subtract","models":{"fixer":"sonnet","implementor":"opus","reviewer":"opus"},"pr":34,"round":2,"state":"in_review"}'

# ---------------------------------------------------------------------------
# AC3.9 merge-appends-arrays
setup_case
set_note_json '{"state":"in_review","pr":34}'
printf '{"out_of_scope_created":[{"title":"A","number":5}],"bugs_filed":[{"title":"X","number":7}],"report_errors":[{"error":"e1"}]}\n' > "$FAKE_GH_DIR/p1.json"
printf '{"out_of_scope_created":[{"title":"B","number":6}],"bugs_filed":[{"title":"Y","number":8}],"report_errors":[{"error":"e2"}]}\n' > "$FAKE_GH_DIR/p2.json"
printf '{"out_of_scope_created":[{"title":"A","number":5}],"bugs_filed":[{"title":"X","number":7}]}\n' > "$FAKE_GH_DIR/p3.json"
clear_inputs; run_note merge 12 "$FAKE_GH_DIR/p1.json"; assert_exit "merge-appends-arrays: first merge exit" 0; feed_back
clear_inputs; run_note merge 12 "$FAKE_GH_DIR/p2.json"; assert_exit "merge-appends-arrays: second merge exit" 0; feed_back
N="$(block_json "$(posted_body)")"
assert_eq "merge-appends-arrays: out_of_scope_created has A then B" "$(jq -c .out_of_scope_created <<<"$N" 2>/dev/null)" '[{"title":"A","number":5},{"title":"B","number":6}]'
assert_eq "merge-appends-arrays: bugs_filed appends" "$(jq -c .bugs_filed <<<"$N" 2>/dev/null)" '[{"title":"X","number":7},{"title":"Y","number":8}]'
assert_eq "merge-appends-arrays: report_errors appends" "$(jq -c .report_errors <<<"$N" 2>/dev/null)" '[{"error":"e1"},{"error":"e2"}]'
clear_inputs; run_note merge 12 "$FAKE_GH_DIR/p3.json"; assert_exit "merge-appends-arrays: third merge exit" 0
N="$(block_json "$(posted_body)")"
assert_eq "merge-appends-arrays: merging A again does not duplicate it" "$(jq -c .out_of_scope_created <<<"$N" 2>/dev/null)" '[{"title":"A","number":5},{"title":"B","number":6}]'
assert_eq "merge-appends-arrays: merging X again does not duplicate it" "$(jq -c .bugs_filed <<<"$N" 2>/dev/null)" '[{"title":"X","number":7},{"title":"Y","number":8}]'

# merge dedups by title case-insensitively
setup_case
set_note_json '{"state":"in_review","pr":34,"out_of_scope_created":[{"title":"Extract Utils","number":5}],"bugs_filed":[{"title":"Calc Crashes","number":7}]}'
printf '{"out_of_scope_created":[{"title":"extract utils","number":9}],"bugs_filed":[{"title":"CALC CRASHES","number":8}]}\n' > "$FAKE_GH_DIR/p.json"
clear_inputs; run_note merge 12 "$FAKE_GH_DIR/p.json"
assert_exit "merge-dedup-case-insensitive: exit" 0
N="$(block_json "$(posted_body)")"
assert_eq "merge-dedup-case-insensitive: out_of_scope_created" "$(jq -c .out_of_scope_created <<<"$N" 2>/dev/null)" '[{"title":"Extract Utils","number":5}]'
assert_eq "merge-dedup-case-insensitive: bugs_filed" "$(jq -c .bugs_filed <<<"$N" 2>/dev/null)" '[{"title":"Calc Crashes","number":7}]'

# ---------------------------------------------------------------------------
# parse: the note from a board-read JSON on stdin, no gh call
setup_case
GOOD="{\"state\":\"in_review\",\"branch\":\"fleet/12-add-subtract\",\"pr\":34,\"round\":1,\"worktree\":\"$BASE/12-add-subtract\"}"
set_note_json "$GOOD"
READ_JSON="$(bash "${SCRIPT_DIR}/../scripts/board-read.sh" 12)"
rm -f "$FAKE_GH_DIR/calls.log"
printf '%s\n' "$READ_JSON" > "$FAKE_GH_DIR/read.json"
run_check_stdin() { local f="$1"; shift; local o e; o="$(mktemp)"; e="$(mktemp)"; "$BASH_EXE" "$SCRIPT" "$@" < "$f" > "$o" 2> "$e"; LAST_EXIT=$?; LAST_OUT="$(cat "$o")"; LAST_ERR="$(cat "$e")"; rm -f "$o" "$e"; }
run_check_stdin "$FAKE_GH_DIR/read.json" parse 12
assert_exit "parse: exit" 0
assert_eq "parse: the note" "$(canon "$LAST_OUT")" "$(canon "$GOOD")"
assert_stderr_exact "parse: no stderr" ""
assert_eq "parse: no gh call" "$( [ -f "$FAKE_GH_DIR/calls.log" ] && wc -l < "$FAKE_GH_DIR/calls.log" | tr -d ' ' || echo 0)" 0
jq -c '.manager_note = null' "$FAKE_GH_DIR/read.json" > "$FAKE_GH_DIR/read-none.json"
run_check_stdin "$FAKE_GH_DIR/read-none.json" parse 12
assert_stdout_exact "parse: no note prints {}" "{}"
jq -c '.manager_note = "### x\n```json\n{\"state\":\"ready\",\"pr\":\"34; echo\"}\n```\n"' "$FAKE_GH_DIR/read.json" > "$FAKE_GH_DIR/read-bad.json"
run_check_stdin "$FAKE_GH_DIR/read-bad.json" parse 12
assert_exit "parse: invalid note exit" 0
assert_stdout_exact "parse: invalid note prints {}" "{}"
assert_stderr_exact "parse: invalid note warning" "fleet-board: warning: ignoring invalid manager note on #12: pr"
printf 'not json\n' > "$FAKE_GH_DIR/read-junk.json"
run_check_stdin "$FAKE_GH_DIR/read-junk.json" parse 12
assert_exit "parse: unparsable card exit 1" 1
assert_stdout_exact "parse: unparsable card no stdout" ""
run_note parse 12 extra
assert_exit "parse: usage" 2

# ---------------------------------------------------------------------------
# pending-followups-replaced
setup_case
set_note_json '{"state":"in_review","pr":34}'
printf '{"pending_followups":{"out_of_scope":[],"bugs":[{"title":"overflow"}],"pr":34}}\n' > "$FAKE_GH_DIR/p1.json"
printf '{"pending_followups":null}\n' > "$FAKE_GH_DIR/p2.json"
printf '{"pending_followups":{"out_of_scope":[{"title":"docs"}]}}\n' > "$FAKE_GH_DIR/p3.json"
clear_inputs; run_note merge 12 "$FAKE_GH_DIR/p1.json"; assert_exit "pending-followups-replaced: first merge exit" 0; feed_back
assert_eq "pending-followups-replaced: set by the first merge" "$(jq -c .pending_followups <<<"$(block_json "$(posted_body)")" 2>/dev/null)" '{"out_of_scope":[],"bugs":[{"title":"overflow"}],"pr":34}'
clear_inputs; run_note merge 12 "$FAKE_GH_DIR/p3.json"; assert_exit "pending-followups-replaced: object merge exit" 0; feed_back
assert_eq "pending-followups-replaced: an object patch replaces the key whole (no deep merge)" "$(jq -c .pending_followups <<<"$(block_json "$(posted_body)")" 2>/dev/null)" '{"out_of_scope":[{"title":"docs"}]}'
clear_inputs; run_note merge 12 "$FAKE_GH_DIR/p2.json"; assert_exit "pending-followups-replaced: null merge exit" 0; feed_back
assert_eq "pending-followups-replaced: null patch leaves it null" "$(jq -c .pending_followups <<<"$(block_json "$(posted_body)")" 2>/dev/null)" 'null'
run_note get 12
assert_eq "pending-followups-replaced: get agrees" "$(jq -c .pending_followups <<<"$LAST_OUT" 2>/dev/null)" 'null'

setup_case
set_note_json '{"state":"in_review","pr":34,"pending_followups":{"out_of_scope":[],"bugs":[],"pr":"34; echo"}}'
run_note get 12
assert_exit "pending-followups-replaced: hostile pending pr exit" 0
assert_stdout_exact "pending-followups-replaced: hostile pending_followups.pr rejected" "{}"
assert_stderr_exact "pending-followups-replaced: hostile pending_followups.pr warning" \
  "fleet-board: warning: ignoring invalid manager note on #12: pending_followups.pr"

# ---------------------------------------------------------------------------
# rejects-hostile-note: each prints {} and one warning naming the field
hostile() { # name field note-json
  setup_case
  set_note_json "$3"
  run_note get 12
  assert_exit "rejects-hostile-note: $1: exit" 0
  assert_stdout_exact "rejects-hostile-note: $1: prints {}" "{}"
  assert_stderr_exact "rejects-hostile-note: $1: warning" \
    "fleet-board: warning: ignoring invalid manager note on #12: $2"
}
hostile "branch with shell" branch '{"state":"ready","branch":"main; rm -rf ~"}'
hostile "branch outside fleet/" branch '{"state":"ready","branch":"main"}'
hostile "pr string" pr '{"state":"in_review","pr":"34; echo"}'
hostile "pr fraction" pr '{"state":"in_review","pr":34.5}'
hostile "blocking_pr string" blocking_pr '{"state":"blocked","blocking_pr":"41 && x"}'
hostile "merged_pr string" merged_pr '{"state":"in_review","merged_pr":"x"}'
hostile "round string" round '{"state":"in_review","round":"1"}'
hostile "implementor_attempts string" implementor_attempts '{"state":"in_progress","implementor_attempts":"1"}'
hostile "action_failures string" action_failures '{"state":"ready","action_failures":"1"}'
hostile "action_failures negative" action_failures '{"state":"ready","action_failures":-1}'
hostile "action_failures fraction" action_failures '{"state":"ready","action_failures":1.5}'
hostile "last_action_error number" last_action_error '{"state":"ready","last_action_error":5}'
hostile "last_action_error object" last_action_error '{"state":"ready","last_action_error":{"a":1}}'
hostile "last_action_error control char" last_action_error "$(jq -cn '{state:"ready",action_failures:1,last_action_error:"x\u001b[31my"}')"
hostile "pending_followups not an object" pending_followups '{"state":"in_review","pending_followups":"x"}'
hostile "note not an object" note '[1,2]'
# A well-formed absolute worktree outside the current base (a re-clone, a
# moved repo, another machine, a changed worktrees.dir) is not hostile: get
# keeps the note, nulls the worktree, and warns
outside() { # name path
  setup_case
  set_note_json "$(jq -cn --arg w "$2" '{state:"in_review",branch:"fleet/12-add-subtract",pr:34,round:1,worktree:$w,bugs_filed:[{title:"X",number:7}]}')"
  run_note get 12
  assert_exit "worktree-outside-base: $1: exit" 0
  assert_eq "worktree-outside-base: $1: note kept, worktree null" \
    "$(jq -S -c . <<<"$LAST_OUT" 2>/dev/null)" \
    '{"branch":"fleet/12-add-subtract","bugs_filed":[{"number":7,"title":"X"}],"pr":34,"round":1,"state":"in_review","worktree":null}'
  assert_stderr_exact "worktree-outside-base: $1: warning" \
    "fleet-board: warning: manager note on #12 names a worktree outside $BASE; treating it as null: $2"
}
outside "/etc" "/etc"
outside "sibling prefix" "${BASE}2/x"
outside "old clone" "/old/clone/.fw/12-add-subtract"
# A control character in an outside path is still a full rejection
setup_case
set_note_json "$(jq -cn '{state:"ready",worktree:"/old/x\u0007y"}')"
run_note get 12
assert_stdout_exact "rejects-hostile-note: control char worktree: prints {}" "{}"
assert_stderr_exact "rejects-hostile-note: control char worktree: warning" \
  "fleet-board: warning: ignoring invalid manager note on #12: worktree"
# put still refuses to write a worktree outside the base
setup_case
printf '{"state":"ready","worktree":"/etc"}\n' > "$FAKE_GH_DIR/out.json"
clear_inputs
run_note put 12 "$FAKE_GH_DIR/out.json"
assert_exit "put-rejects-outside-worktree: exit" 1
assert_eq "put-rejects-outside-worktree: nothing posted" "$(input_count)" 0
assert_stderr_contains "put-rejects-outside-worktree: names the field" "worktree"
# merge after a base change keeps the note's history; only the worktree drops
setup_case
set_note_json "$(jq -cn '{state:"in_review",branch:"fleet/12-add-subtract",pr:34,round:1,worktree:"/old/clone/.fw/12-add-subtract",
  bugs_filed:[{title:"X",number:7}],pending_followups:{out_of_scope:[{title:"docs"}],bugs:[],pr:34},report_errors:[{error:"e1"}]}')"
printf '{"round":2}\n' > "$FAKE_GH_DIR/patch.json"
clear_inputs
run_note merge 12 "$FAKE_GH_DIR/patch.json"
assert_exit "merge-after-base-change: exit" 0
assert_eq "merge-after-base-change: history kept, worktree null, round merged" \
  "$(jq -S -c '{round,worktree,bugs_filed,pending_followups,report_errors,branch,pr}' <<<"$(block_json "$(posted_body)")" 2>/dev/null)" \
  '{"branch":"fleet/12-add-subtract","bugs_filed":[{"number":7,"title":"X"}],"pending_followups":{"bugs":[],"out_of_scope":[{"title":"docs"}],"pr":34},"pr":34,"report_errors":[{"error":"e1"}],"round":2,"worktree":null}'
# merge refuses to overwrite an invalid stored note
setup_case
set_note_json '{"state":"in_review","branch":"main; rm -rf ~","pr":34,"bugs_filed":[{"title":"X","number":7}]}'
printf '{"round":2}\n' > "$FAKE_GH_DIR/patch.json"
clear_inputs
run_note merge 12 "$FAKE_GH_DIR/patch.json"
assert_exit "merge-refuses-invalid-note: exit 1" 1
assert_eq "merge-refuses-invalid-note: nothing posted" "$(input_count)" 0
assert_stderr_contains "merge-refuses-invalid-note: says it refuses" "refusing to merge into the invalid manager note on #12"
# The dot-dot worktree needs this case's normalized base
setup_case
set_note_json "{\"state\":\"ready\",\"worktree\":\"$BASE/../../etc\"}"
run_note get 12
assert_stdout_exact "rejects-hostile-note: dot-dot worktree: prints {}" "{}"
assert_stderr_exact "rejects-hostile-note: dot-dot worktree: warning" \
  "fleet-board: warning: ignoring invalid manager note on #12: worktree"
setup_case
set_note_json "{\"state\":\"ready\",\"worktree\":\"fw/12-x\"}"
run_note get 12
assert_stdout_exact "rejects-hostile-note: relative worktree: prints {}" "{}"
# The base itself and a path under it pass
setup_case
set_note_json "{\"state\":\"ready\",\"worktree\":\"$BASE\"}"
run_note get 12
assert_eq "worktree-at-base: accepted" "$(jq -c .worktree <<<"$LAST_OUT" 2>/dev/null)" "\"$BASE\""
assert_stderr_exact "worktree-at-base: no warning" ""
GOOD="{\"state\":\"ready\",\"worktree\":\"$BASE/12-add-subtract\",\"branch\":\"fleet/12-add-subtract\",\"pr\":34,\"blocking_pr\":null,\"round\":0}"
set_note_json "$GOOD"
run_note get 12
assert_eq "worktree-under-base: accepted" "$(canon "$LAST_OUT")" "$(canon "$GOOD")"
assert_stderr_exact "worktree-under-base: no warning" ""

# ---------------------------------------------------------------------------
# action_failures and last_action_error: the action-failure counter
# A note written before the keys existed is valid and reads unchanged
setup_case
set_note_json '{"state":"ready","branch":"fleet/12-add-subtract"}'
run_note get 12
assert_exit "action-keys-absent: exit" 0
assert_stderr_exact "action-keys-absent: no warning" ""
assert_eq "action-keys-absent: note unchanged" "$(canon "$LAST_OUT")" '{"branch":"fleet/12-add-subtract","state":"ready"}'
# put strips control characters from last_action_error (it is written from a
# stderr line) instead of refusing the write, so the count is never lost
setup_case
jq -cn '{state:"ready",action_failures:1,last_action_error:"fatal:\u001b[31m bad\tline\r"}' > "$FAKE_GH_DIR/ctl.json"
clear_inputs
run_note put 12 "$FAKE_GH_DIR/ctl.json"
assert_exit "action-error-control-chars: put exit" 0
BODY="$(posted_body)"
assert_eq "action-error-control-chars: stored with spaces" \
  "$(jq -c '[.action_failures, .last_action_error]' <<<"$(block_json "$BODY")" 2>/dev/null)" '[1,"fatal: [31m bad line "]'
assert_eq "action-error-control-chars: summary line" "$(printf '%s\n' "$BODY" | sed -n 3p)" \
  'State: ready · Round: — · PR: — · Branch: — · Action failures: 1 (last: fatal: [31m bad line )'
feed_back
run_note get 12
assert_stderr_exact "action-error-control-chars: reads back without a warning" ""
assert_eq "action-error-control-chars: reads back" "$(jq -c .action_failures <<<"$LAST_OUT" 2>/dev/null)" "1"
# put refuses an invalid counter
setup_case
printf '{"state":"ready","action_failures":-2}\n' > "$FAKE_GH_DIR/neg.json"
clear_inputs
run_note put 12 "$FAKE_GH_DIR/neg.json"
assert_exit "put-rejects-negative-action-failures: exit" 1
assert_eq "put-rejects-negative-action-failures: nothing posted" "$(input_count)" 0
assert_stderr_contains "put-rejects-negative-action-failures: names the field" "action_failures"
# merge counts a failure, then a success resets both keys
setup_case
set_note_json '{"state":"in_review","branch":"fleet/12-add-subtract","pr":34,"round":1,"action_failures":1,"last_action_error":"old"}'
printf '{"action_failures":2,"last_action_error":"fatal: new"}\n' > "$FAKE_GH_DIR/patch.json"
clear_inputs
run_note merge 12 "$FAKE_GH_DIR/patch.json"
assert_exit "merge-action-failure: exit" 0
assert_eq "merge-action-failure: counted" \
  "$(jq -c '[.action_failures, .last_action_error, .round]' <<<"$(block_json "$(posted_body)")" 2>/dev/null)" '[2,"fatal: new",1]'
feed_back
printf '{"action_failures":0,"last_action_error":null}\n' > "$FAKE_GH_DIR/patch.json"
clear_inputs
run_note merge 12 "$FAKE_GH_DIR/patch.json"
assert_exit "merge-action-reset: exit" 0
assert_eq "merge-action-reset: both reset" \
  "$(jq -c '[.action_failures, .last_action_error, .round]' <<<"$(block_json "$(posted_body)")" 2>/dev/null)" '[0,null,1]'
assert_eq "merge-action-reset: summary has no action-failures suffix" "$(posted_body | sed -n 3p)" \
  'State: in_review · Round: 1 · PR: #34 · Branch: `fleet/12-add-subtract`'

# reset-failures: what a person runs after moving a card the plan skips
# (tick-plan.sh warns with this command); a merge of {"action_failures": 0,
# "last_action_error": null} that needs no patch file
setup_case
set_note_json '{"state":"in_review","branch":"fleet/12-add-subtract","pr":34,"round":1,"blocking_pr":41,"action_failures":6,"last_action_error":"fatal: stuck","bugs_filed":[{"title":"X","number":7}]}'
clear_inputs
run_note reset-failures 12
assert_exit "reset-failures: exit" 0
assert_eq "reset-failures: replaced the stored note in place (one PATCH)" "$(grep -c 'api -X PATCH repos/acme/toy/issues/comments/555' "$FAKE_GH_DIR/calls.log")" 1
assert_eq "reset-failures: both keys reset, the rest kept" \
  "$(jq -S -c '{action_failures,last_action_error,state,branch,pr,round,blocking_pr,bugs_filed}' <<<"$(block_json "$(posted_body)")" 2>/dev/null)" \
  '{"action_failures":0,"blocking_pr":41,"branch":"fleet/12-add-subtract","bugs_filed":[{"number":7,"title":"X"}],"last_action_error":null,"pr":34,"round":1,"state":"in_review"}'
assert_eq "reset-failures: summary has no action-failures suffix" "$(posted_body | sed -n 3p)" \
  'State: in_review · Round: 1 · PR: #34 · Branch: `fleet/12-add-subtract`'
# An old note's setup_* keys are reset too (they are read as the new keys)
setup_case
set_note_json '{"state":"ready","setup_failures":6,"last_setup_error":"fatal: old"}'
clear_inputs
run_note reset-failures 12
assert_exit "reset-failures: legacy keys: exit" 0
assert_eq "reset-failures: legacy keys: reset, old keys dropped" \
  "$(jq -c '[.action_failures, .last_action_error, has("setup_failures"), has("last_setup_error")]' <<<"$(block_json "$(posted_body)")" 2>/dev/null)" \
  '[0,null,false,false]'
# A card with no note gets a default note with the count at 0
setup_case
clear_inputs
run_note reset-failures 12
assert_exit "reset-failures: no note: exit" 0
assert_eq "reset-failures: no note: writes the defaults" \
  "$(jq -c '[.action_failures, .last_action_error, .state]' <<<"$(block_json "$(posted_body)")" 2>/dev/null)" '[0,null,null]'
# Like merge, it refuses to overwrite an invalid stored note
setup_case
set_note_json '{"state":"ready","branch":"main; rm -rf ~","action_failures":6}'
clear_inputs
run_note reset-failures 12
assert_exit "reset-failures: invalid note: exit 1" 1
assert_eq "reset-failures: invalid note: nothing posted" "$(input_count)" 0
assert_stderr_contains "reset-failures: invalid note: says it refuses" "refusing to reset the action failures on the invalid manager note on #12"
# A card that cannot be read fails closed
setup_case
printf 'api user\t0\t%s\n' "$FIXTURES/labels/user.json" > "$ROUTES"
printf 'api repos/acme/toy/issues/12\t1\t-\n' >> "$ROUTES"
clear_inputs
run_note reset-failures 12
assert_exit "reset-failures: read failure: exit 1" 1
assert_eq "reset-failures: read failure: nothing posted" "$(input_count)" 0

# A note written before the rename (setup_failures, last_setup_error) is
# read as action_failures and last_action_error; the old keys are dropped
setup_case
set_note_json '{"state":"ready","branch":"fleet/12-add-subtract","setup_failures":2,"last_setup_error":"fatal: old"}'
run_note get 12
assert_exit "legacy-setup-keys: get exit" 0
assert_stderr_exact "legacy-setup-keys: no warning" ""
assert_eq "legacy-setup-keys: mapped to the action keys" "$(canon "$LAST_OUT")" \
  '{"action_failures":2,"branch":"fleet/12-add-subtract","last_action_error":"fatal: old","state":"ready"}'
# The new keys win when both are present
setup_case
set_note_json '{"state":"ready","setup_failures":5,"last_setup_error":"old","action_failures":1,"last_action_error":"new"}'
run_note get 12
assert_eq "legacy-setup-keys: the new keys win" "$(canon "$LAST_OUT")" \
  '{"action_failures":1,"last_action_error":"new","state":"ready"}'
# An invalid old value is rejected under its new name
setup_case
set_note_json '{"state":"ready","setup_failures":"1"}'
run_note get 12
assert_stdout_exact "legacy-setup-keys: invalid old counter: prints {}" "{}"
assert_stderr_exact "legacy-setup-keys: invalid old counter: warning" \
  "fleet-board: warning: ignoring invalid manager note on #12: action_failures"
# merge into an old note keeps the count and writes only the new keys
setup_case
set_note_json '{"state":"in_review","branch":"fleet/12-add-subtract","pr":34,"round":1,"setup_failures":2,"last_setup_error":"fatal: old"}'
printf '{"round":2}\n' > "$FAKE_GH_DIR/patch.json"
clear_inputs
run_note merge 12 "$FAKE_GH_DIR/patch.json"
assert_exit "legacy-setup-keys: merge exit" 0
assert_eq "legacy-setup-keys: merge carries the count under the new keys" \
  "$(jq -c '[.action_failures, .last_action_error, .round, has("setup_failures"), has("last_setup_error")]' <<<"$(block_json "$(posted_body)")" 2>/dev/null)" \
  '[2,"fatal: old",2,false,false]'
assert_eq "legacy-setup-keys: merge summary line" "$(posted_body | sed -n 3p)" \
  'State: in_review · Round: 2 · PR: #34 · Branch: `fleet/12-add-subtract` · Action failures: 2 (last: fatal: old)'
# put maps the old keys too, before the defaults fill the new ones
setup_case
printf '{"state":"ready","setup_failures":1,"last_setup_error":"fatal: x"}\n' > "$FAKE_GH_DIR/old.json"
clear_inputs
run_note put 12 "$FAKE_GH_DIR/old.json"
assert_exit "legacy-setup-keys: put exit" 0
assert_eq "legacy-setup-keys: put stores the new keys only" \
  "$(jq -c '[.action_failures, .last_action_error, has("setup_failures"), has("last_setup_error")]' <<<"$(block_json "$(posted_body)")" 2>/dev/null)" \
  '[1,"fatal: x",false,false]'

# ---------------------------------------------------------------------------
# usage
setup_case
run_note get
assert_exit "usage: get without a number" 2
run_note get abc
assert_exit "usage: non-numeric card" 2
run_note frob 12
assert_exit "usage: unknown subcommand" 2
run_note put 12 "$FAKE_GH_DIR/missing.json"
assert_exit "usage: put with a missing file" 2
run_note reset-failures
assert_exit "usage: reset-failures without a number" 2
run_note reset-failures abc
assert_exit "usage: reset-failures with a non-numeric card" 2
run_note reset-failures 12 "$FAKE_GH_DIR/patch.json"
assert_exit "usage: reset-failures takes no file" 2

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
