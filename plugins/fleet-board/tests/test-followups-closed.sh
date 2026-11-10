#!/usr/bin/env bash
#
# Plain-bash tests for the issue comment on a closed-card duplicate match (offline, fake gh). Routes files are
# written at run time, so their fixture paths are absolute.
# No framework, no dependencies beyond POSIX tools, jq and git.
#
# Usage: bash plugins/fleet-board/tests/test-followups-closed.sh

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

echo "Test: a duplicate matched to a closed card is commented on the issue as well as the PR"
echo ""

RECENT="$(date -u -v-3d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%SZ)"

# closed_case: the follow-up "Fix rounding" matches closed card #61
closed_case() {
  setup_case
  printf '[{"number":61,"title":"Fix rounding","closedAt":"%s"}]\n' "$RECENT" > "$FAKE_GH_DIR/closed.json"
  {
    printf 'issue list --repo acme/toy --state closed --search*\t0\t%s\n' "$FAKE_GH_DIR/closed.json"
    printf 'issue comment 61 *\t0\t-\n'
    cat "$ROUTES"
  } > "$ROUTES.new" && mv "$ROUTES.new" "$ROUTES"
  report "$OOS_CMD" '[]'
}

# --- AC1: a closed-card match comments on that issue and on the PR
closed_case
run_ff
assert_exit "closed-match: exit" 0
assert_eq "closed-match: one issue comment on the closed card" "$(calls_starting issue comment 61)" 1
assert_eq "closed-match: the issue comment names the card and PR" "$(bodies_of issue comment 61)" "Also seen while working #12 (PR #34)."
assert_eq "closed-match: one PR comment" "$(calls_starting pr comment 34)" 1
assert_eq "closed-match: no issue create" "$(calls_starting issue create)" 0

# --- AC2: a match against an open card is unchanged
setup_case
printf '[{"number":55,"title":"fix rounding"}]\n' > "$FAKE_GH_DIR/match.json"
{ printf 'issue list --repo acme/toy --state open --search*\t0\t%s\n' "$FAKE_GH_DIR/match.json"; cat "$ROUTES"; } > "$ROUTES.new" && mv "$ROUTES.new" "$ROUTES"
report "$OOS_CMD" '[]'
run_ff
assert_exit "open-match: exit" 0
assert_eq "open-match: one issue comment on the open card" "$(calls_starting issue comment 55)" 1
assert_eq "open-match: issue comment body" "$(bodies_of issue comment 55)" "Also seen while working #12 (PR #34)."
assert_eq "open-match: one PR comment" "$(calls_starting pr comment 34)" 1
assert_eq "open-match: no closed search" "$(calls_starting issue list --repo acme/toy --state closed)" 0

# --- AC3: the comment is posted once; filing the same follow-up again posts nothing new
closed_case
run_ff
set_note "$(jq -c '{out_of_scope_created: .out_of_scope_created}' <<<"$LAST_OUT")"
run_ff
assert_exit "closed-twice: second exit" 0
assert_eq "closed-twice: still one issue comment on the closed card" "$(calls_starting issue comment 61)" 1
assert_eq "closed-twice: still one PR comment" "$(calls_starting pr comment 34)" 1

# --- local backend: "closed" is done or wont_do, updated within 30 days; gh
# answers only the PR comment, so any issue search or comment exits 99
local_card() {
  jq -n --argjson n "$1" --arg t "$2" --arg s "$3" --arg u "$4" \
    '{number: $n, title: $t, body: "b", state: $s, labels: [], next_comment_id: 1, comments: [],
      created_at: "2026-01-01T00:00:00Z", updated_at: $u}' > "$REPO/.fleet-board/cards/$1.json"
}
setup_local() {
  setup_case
  printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\n' > "$REPO/.fleet-board.yml"
  mkdir -p "$REPO/.fleet-board/cards"
  echo 70 > "$REPO/.fleet-board/next"
  local_card 12 "The card" in_progress "$RECENT"
  printf 'pr comment 34 *\t0\t-\n' > "$ROUTES"
  report "$OOS_CMD" '[]'
}

setup_local
local_card 61 "fix ROUNDING" wont_do "$RECENT"
run_ff
assert_exit "local closed-match: exit" 0
assert_eq "local closed-match: matched the recent wont_do card" "$(jq -c .out_of_scope_created <<<"$LAST_OUT")" '[{"title":"Fix rounding","number":61,"existing":true,"matched":"closed"}]'
assert_eq "local closed-match: comment on card 61" "$(jq -r '.comments[-1].body' "$REPO/.fleet-board/cards/61.json")" "Also seen while working #12 (PR #34)."
assert_eq "local closed-match: no card created" "$(cat "$REPO/.fleet-board/next")" 70
assert_eq "local closed-match: only the PR comment reached gh" "$(ls "$FAKE_GH_DIR/argv" | wc -l | tr -d ' ')" 1

setup_local
local_card 61 "Fix rounding" done 2020-01-01T00:00:00Z
run_ff
assert_exit "local old-closed: exit" 0
assert_eq "local old-closed: a card closed long ago is no match" "$(jq -c .out_of_scope_created <<<"$LAST_OUT")" '[{"title":"Fix rounding","number":70,"existing":false}]'
assert_eq "local old-closed: created in the followups column" "$(jq -r .state "$REPO/.fleet-board/cards/70.json")" ready

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
