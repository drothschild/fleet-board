#!/usr/bin/env bash
#
# Plain-bash tests for the Acceptance and Ready defaults of filed follow-ups (offline, fake gh). Routes files are
# written at run time, so their fixture paths are absolute.
# No framework, no dependencies beyond POSIX tools, jq and git.
#
# Usage: bash plugins/fleet-board/tests/test-followups-acceptance.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SCRIPT_DIR/store-sync.sh" # the local store, rebuilt from the routes before each run
. "$SCRIPT_DIR/store-calls.sh" # its changes, recorded as the gh issue calls they replace
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
  store_sync
  store_snap
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
  store_calls
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
issue list --repo acme/toy --state closed --search*	0	$FAKE_GH_DIR/empty.json
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

CFG="$SCRIPT_DIR/../scripts/config.sh"
DOCS="$SCRIPT_DIR/../docs/config.md"

# A cmd-bearing out-of-scope item, one without a command, and one that depends on the spawning card
OOS_CMD='[{"title":"Fix rounding","detail":"round(2.5) is wrong. Run `node calc.js round 2.5`, expected 3."}]'
OOS_NOCMD='[{"title":"Tidy the module layout","detail":"the layout feels messy"}]'
OOS_DEP='[{"title":"Follow up on parser","detail":"Depends on this card. Run `node parse.js --strict`, expected exit 0."}]'

# Bodies and labels of the issue create calls
create_file() { files_starting issue create | head -n 1; }

echo "Test: follow-up Acceptance, Ready default, Depends on, dedupe, config"
echo ""

# --- bug: body builder includes ## Acceptance drafted from repro + expected
setup_case
report '[]' "[$(bug "Division by zero crashes")]"
run_ff
assert_exit "bug-acceptance: exit" 0
B="$(all_bodies)"
case "$B" in *"## Acceptance"*) pass "bug-acceptance: body has ## Acceptance" ;; *) fail "bug-acceptance: body has ## Acceptance" "$B" ;; esac
ACC="$(printf '%s\n' "$B" | sed -n '/^## Acceptance/,$p')"
case "$ACC" in *$'\n- '*) pass "bug-acceptance: at least one - bullet" ;; *) fail "bug-acceptance: at least one - bullet" "$ACC" ;; esac
case "$ACC" in *"require('./calc').div(1,0)"*"an error"*) pass "bug-acceptance: bullet names the failing command and expected result" ;; *) fail "bug-acceptance: bullet names the failing command and expected result" "$ACC" ;; esac

# --- a newline in repro or expected does not split the acceptance item
setup_case
report '[]' "[$(jq -cn '{title:"Multi line bug", repro:"node -e x", expected:"first line\nsecond line", observed:"o"}')]"
run_ff
ACCJ="$(jq -c 'select(.title == "Multi line bug") | .acceptance' "$REPO/.fleet-board/cards/"*.json 2>/dev/null | head -n 1)"
assert_eq "bug-acceptance-newline: one acceptance item" "$(jq -r 'length' <<<"$ACCJ" 2>/dev/null)" "1"
case "$ACCJ" in *"first line second line"*) pass "bug-acceptance-newline: newline became a space" ;; *) fail "bug-acceptance-newline: newline became a space" "$ACCJ" ;; esac

# --- oos with a command in the detail: Acceptance drafted
setup_case
report "$OOS_CMD" '[]'
run_ff
ACC="$(all_bodies | sed -n '/^## Acceptance/,$p')"
case "$ACC" in *'`node calc.js round 2.5`'*) pass "oos-acceptance: bullet carries the command from the detail" ;; *) fail "oos-acceptance: bullet carries the command from the detail" "$ACC" ;; esac

# --- default: Ready
setup_case
report "$OOS_CMD" '[]'
run_ff
F="$(create_file)"
if [ -n "$F" ]; then
  assert_true "default: labelled fleet:ready" has_pair "$F" --label fleet:ready
  assert_false "default: not labelled fleet:backlog" has_pair "$F" --label fleet:backlog
else
  fail "default: labelled fleet:ready" "no issue create call"
fi

# --- followups.status: backlog
setup_case
printf 'followups:\n  status: backlog\n' >> "$REPO/.fleet-board.yml"
report "$OOS_CMD" '[]'
run_ff
F="$(create_file)"
if [ -n "$F" ]; then
  assert_true "backlog switch: labelled fleet:backlog" has_pair "$F" --label fleet:backlog
  assert_false "backlog switch: not labelled fleet:ready" has_pair "$F" --label fleet:ready
else
  fail "backlog switch: labelled fleet:backlog" "no issue create call"
fi

# --- config validator
setup_case
run_check "$CFG" followups.status
assert_eq "config: default followups.status is ready" "$LAST_OUT" "ready"
printf 'followups:\n  status: soon\n' >> "$REPO/.fleet-board.yml"
run_check "$CFG" --check
assert_exit "config: bad followups.status exit 5" 5
assert_stderr_contains "config: message names followups.status" "followups.status"

# --- Depends on the spawning card
setup_case
report "$OOS_DEP" '[]'
run_ff
B="$(all_bodies)"
case "$B" in *$'## Depends on\n- #12'*) pass "depends: body carries ## Depends on - #12" ;; *) fail "depends: body carries ## Depends on - #12" "$B" ;; esac
setup_case
report "$OOS_CMD" '[]'
run_ff
case "$(all_bodies)" in *"## Depends on"*) fail "no-depends: independent follow-up has no Depends on" "$(all_bodies)" ;; *) pass "no-depends: independent follow-up has no Depends on" ;; esac

# --- no testable bullet: Backlog and a comment saying why
setup_case
{ printf 'issue create --repo acme/toy --title Tidy the module layout *\t0\t%s\nissue comment 78 *\t0\t-\n' "$FAKE_GH_DIR/created-78.txt"; cat "$ROUTES"; } > "$ROUTES.new" && mv "$ROUTES.new" "$ROUTES"
report "$OOS_NOCMD" '[]'
run_ff
assert_exit "untestable: exit" 0
F="$(create_file)"
if [ -n "$F" ]; then
  assert_true "untestable: filed in fleet:backlog" has_pair "$F" --label fleet:backlog
else
  fail "untestable: filed in fleet:backlog" "no issue create call"
fi
assert_eq "untestable: one issue comment on the new card" "$(calls_starting issue comment 13)" 1
case "$(bodies_of issue comment 13)" in *"testable"*"Backlog"*|*"Backlog"*"testable"*) pass "untestable: comment says why" ;; *) fail "untestable: comment says why" "$(bodies_of issue comment 13)" ;; esac

# --- escape words beat a backticked span: Backlog, no Acceptance
setup_case
{ printf 'issue create --repo acme/toy --title Rename the module *\t0\t%s\nissue comment 78 *\t0\t-\n' "$FAKE_GH_DIR/created-78.txt"; cat "$ROUTES"; } > "$ROUTES.new" && mv "$ROUTES.new" "$ROUTES"
report '[{"title":"Rename the module","detail":"no testable check; a naming call, see `README.md`"}]' '[]'
run_ff
assert_exit "escape-words: exit" 0
F="$(create_file)"
if [ -n "$F" ]; then
  assert_true "escape-words: filed in fleet:backlog" has_pair "$F" --label fleet:backlog
else
  fail "escape-words: filed in fleet:backlog" "no issue create call"
fi
case "$(all_bodies)" in *"## Acceptance"*) fail "escape-words: body has no ## Acceptance" "$(all_bodies)" ;; *) pass "escape-words: body has no ## Acceptance" ;; esac

# --- a blank backtick span drafts no Acceptance: Backlog
setup_case
{ printf 'issue create --repo acme/toy --title Tidy blank *\t0\t%s\nissue comment 78 *\t0\t-\n' "$FAKE_GH_DIR/created-78.txt"; cat "$ROUTES"; } > "$ROUTES.new" && mv "$ROUTES.new" "$ROUTES"
report '[{"title":"Tidy blank","detail":"run ` ` to see"}]' '[]'
run_ff
F="$(create_file)"
if [ -n "$F" ]; then
  assert_true "blank-span: filed in fleet:backlog" has_pair "$F" --label fleet:backlog
else
  fail "blank-span: filed in fleet:backlog" "no issue create call"
fi

# --- the escape phrase is matched on ASCII only: a Kelvin sign is not a k
setup_case
report "$(printf '[{"title":"Fix kelvin","detail":"no testable chec\342\204\252 and `make test`"}]')" '[]'
run_ff
ACC="$(all_bodies | sed -n '/^## Acceptance/,$p')"
case "$ACC" in *'`make test`'*) pass "kelvin: Acceptance runs make test" ;; *) fail "kelvin: Acceptance runs make test" "$ACC" ;; esac

# --- a span holding only U+00A0 is blank: Backlog, no Acceptance
setup_case
{ printf 'issue create --repo acme/toy --title Tidy nbsp *\t0\t%s\nissue comment 78 *\t0\t-\n' "$FAKE_GH_DIR/created-78.txt"; cat "$ROUTES"; } > "$ROUTES.new" && mv "$ROUTES.new" "$ROUTES"
report "$(printf '[{"title":"Tidy nbsp","detail":"run `\302\240` to see"}]')" '[]'
run_ff
F="$(create_file)"
if [ -n "$F" ]; then
  assert_true "nbsp-span: filed in fleet:backlog" has_pair "$F" --label fleet:backlog
else
  fail "nbsp-span: filed in fleet:backlog" "no issue create call"
fi
case "$(all_bodies)" in *"## Acceptance"*) fail "nbsp-span: body has no ## Acceptance" "$(all_bodies)" ;; *) pass "nbsp-span: body has no ## Acceptance" ;; esac

# --- the Backlog comment for the escape words says no testable check was stated
setup_case
{ printf 'issue create --repo acme/toy --title Rename the module *\t0\t%s\nissue comment 78 *\t0\t-\n' "$FAKE_GH_DIR/created-78.txt"; cat "$ROUTES"; } > "$ROUTES.new" && mv "$ROUTES.new" "$ROUTES"
report '[{"title":"Rename the module","detail":"no testable check; a naming call"}]' '[]'
run_ff
C="$(bodies_of issue comment 13)"
case "$C" in *"no testable check"*) pass "escape-comment: names that no testable check was stated" ;; *) fail "escape-comment: names that no testable check was stated" "$C" ;; esac
case "$C" in *"no failing command and expected result"*) fail "escape-comment: does not blame a missing command" "$C" ;; *) pass "escape-comment: does not blame a missing command" ;; esac

# --- spans are paired, not matched anywhere: the text between two spans is never the command
setup_case
report '[{"title":"Fix rounding","detail":"calc has no multiply; ` ` x `make test` exits 0"}]' '[]'
run_ff
ACC="$(all_bodies | sed -n '/^## Acceptance/,$p')"
case "$ACC" in *'`make test`'*) pass "paired-spans: Acceptance runs make test" ;; *) fail "paired-spans: Acceptance runs make test" "$ACC" ;; esac
case "$ACC" in *'` x `'*) fail "paired-spans: text between spans is not the command" "$ACC" ;; *) pass "paired-spans: text between spans is not the command" ;; esac

# --- an odd number of backticks pairs no span: Backlog
setup_case
{ printf 'issue create --repo acme/toy --title Watch flag *\t0\t%s\nissue comment 78 *\t0\t-\n' "$FAKE_GH_DIR/created-78.txt"; cat "$ROUTES"; } > "$ROUTES.new" && mv "$ROUTES.new" "$ROUTES"
report '[{"title":"Watch flag","detail":"the `--watch flag is ignored; `npm test -- --watch` exits 0"}]' '[]'
run_ff
F="$(create_file)"
if [ -n "$F" ]; then
  assert_true "stray-backtick: filed in fleet:backlog" has_pair "$F" --label fleet:backlog
else
  fail "stray-backtick: filed in fleet:backlog" "no issue create call"
fi

# --- dedupe against a recently closed card, case-insensitively
setup_case
RECENT="$(date -u -v-3d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%SZ)"
printf '[{"number":61,"title":"FIX ROUNDING","closedAt":"%s"}]\n' "$RECENT" > "$FAKE_GH_DIR/closed.json"
{ printf 'issue list --repo acme/toy --state closed --search*\t0\t%s\nissue comment 61 *\t0\t-\n' "$FAKE_GH_DIR/closed.json"; cat "$ROUTES"; } > "$ROUTES.new" && mv "$ROUTES.new" "$ROUTES"
report "$OOS_CMD" '[]'
run_ff
assert_exit "dedupe-closed: exit" 0
assert_eq "dedupe-closed: no issue create" "$(calls_starting issue create)" 0
assert_eq "dedupe-closed: output names the matched duplicate" "$(jqc '.out_of_scope_created')" \
  '[{"title":"Fix rounding","number":61,"existing":true,"matched":"closed"}]'

# --- an old closed card does not suppress
setup_case
printf '[{"number":61,"title":"Fix rounding","closedAt":"2020-01-01T00:00:00Z"}]\n' > "$FAKE_GH_DIR/closed.json"
{ printf 'issue list --repo acme/toy --state closed --search*\t0\t%s\n' "$FAKE_GH_DIR/closed.json"; cat "$ROUTES"; } > "$ROUTES.new" && mv "$ROUTES.new" "$ROUTES"
report "$OOS_CMD" '[]'
run_ff
assert_eq "dedupe-old: long-closed card does not suppress" "$(calls_starting issue create)" 1

# --- dedupe against an open card records matched: open
setup_case
printf '[{"number":55,"title":"fix rounding"}]\n' > "$FAKE_GH_DIR/match.json"
{ printf 'issue list --repo acme/toy --state open --search*\t0\t%s\n' "$FAKE_GH_DIR/match.json"; cat "$ROUTES"; } > "$ROUTES.new" && mv "$ROUTES.new" "$ROUTES"
report "$OOS_CMD" '[]'
run_ff
assert_eq "dedupe-open: output names the matched duplicate" "$(jqc '.out_of_scope_created')" \
  '[{"title":"Fix rounding","number":55,"existing":true,"matched":"open"}]'

# --- docs
if grep -q 'followups.status' "$DOCS"; then pass "docs: config.md documents followups.status"; else fail "docs: config.md documents followups.status" "not found in $DOCS"; fi

# docs: the key is pinned by fixed-string match (the dot is literal, not a wildcard)
if grep -qF '## `followups.status`' "$DOCS" && grep -qF 'followups.status: backlog' "$DOCS"; then pass "docs: config.md has a literal followups.status heading and backlog example"; else fail "docs: config.md has a literal followups.status heading and backlog example" "not found in $DOCS"; fi

# docs: the main-is-red card is filed in the followups.status column, not Backlog
# --- local backend: the "no testable check" item lands in Backlog on a card
# file, with the why-comment on that card; gh answers only the PR comment
setup_case
printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\n' > "$REPO/.fleet-board.yml"
mkdir -p "$REPO/.fleet-board/cards"
echo 9 > "$REPO/.fleet-board/next"
jq -n '{number: 12, title: "The card", body: "b", state: "in_progress", labels: [], next_comment_id: 1, comments: [], created_at: "2026-11-01T00:00:00Z"}' \
  > "$REPO/.fleet-board/cards/12.json"
printf 'pr comment 34 *\t0\t-\n' > "$ROUTES"
report '[{"title":"Rename the module","detail":"no testable check; a naming call, see `README.md`"}]' '[]'
run_ff
assert_exit "local escape-words: exit" 0
assert_eq "local escape-words: card #9 in backlog" "$(jq -r .state "$REPO/.fleet-board/cards/9.json" 2>/dev/null)" backlog
case "$(jq -r '.comments[-1].body' "$REPO/.fleet-board/cards/9.json" 2>/dev/null)" in
  "Filed in Backlog: the role stated that there is no testable check"*) pass "local escape-words: why-comment on card #9" ;;
  *) fail "local escape-words: why-comment on card #9" "$LAST_ERR" ;;
esac
# the detail names a backticked path, so file-followups.sh also looks up the PR's
# file list (#303, fl_names_unmerged_path); nothing else reached gh
assert_eq "local escape-words: only the PR file lookup and the PR comment reached gh" "$(ls "$FAKE_GH_DIR/argv" | wc -l | tr -d ' ')" 2
assert_eq "local escape-words: the PR comment reached gh once" "$(calls_starting pr comment)" 1
assert_eq "local escape-words: the PR file list was read once" "$(calls_starting pr view)" 1

if grep -F 'main is red' "$DOCS" | sed 's/.*main is red//; s/\. .*//' | grep -qF 'Backlog'; then fail "docs: no sentence puts the main is red card in Backlog" "Backlog follows main is red"; else pass "docs: no sentence puts the main is red card in Backlog"; fi

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
