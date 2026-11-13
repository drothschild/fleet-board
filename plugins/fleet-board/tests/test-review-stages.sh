#!/usr/bin/env bash
#
# Plain-bash tests for review-stages.sh (offline, fake gh).
#
# Usage: bash plugins/fleet-board/tests/test-review-stages.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SCRIPT_DIR/store-sync.sh" # the local store, rebuilt from the routes before each run
. "$SCRIPT_DIR/store-calls.sh" # its changes, recorded as the gh issue calls they replace
SCRIPT="${SCRIPT_DIR}/../scripts/review-stages.sh"
FIXTURES="$SCRIPT_DIR/../fixtures/gh"
STAGES_FIX="$FIXTURES/stages"

unset FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT || true

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

assert_stderr_contains() {
  case "$LAST_ERR" in
    *"$2"*) pass "$1" ;;
    *) fail "$1" "expected to find '$2' in stderr, got: '$LAST_ERR'" ;;
  esac
}

assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}

run_stages() {
  store_sync
  store_snap
  local tmpout tmperr
  tmpout="$(mktemp)"
  tmperr="$(mktemp)"
  "$BASH_EXE" "$SCRIPT" "$@" > "$tmpout" 2> "$tmperr"
  LAST_EXIT=$?
  LAST_OUT="$(cat "$tmpout")"
  LAST_ERR="$(cat "$tmperr")"
  rm -f "$tmpout" "$tmperr"
  store_calls
}

# cnt <argv words...>: how many gh calls had exactly these arguments
cnt() {
  local want f n=0
  want="$(printf '%s\n' "$@")"
  for f in "$FAKE_GH_DIR"/argv/*; do
    [ -f "$f" ] || continue
    [ "$(cat "$f")" = "$want" ] && n=$((n + 1))
  done
  echo "$n"
}

# cnt_prefix <word> <word>: how many gh calls start with these two arguments
cnt_prefix() {
  local f n=0
  for f in "$FAKE_GH_DIR"/argv/*; do
    [ -f "$f" ] || continue
    [ "$(sed -n 1p "$f") $(sed -n 2p "$f")" = "$1 $2" ] && n=$((n + 1))
  done
  echo "$n"
}

STAGES_YML='  stages:
    - name: security
      agent: sec-reviewer
      paths: ["src/auth/**"]
    - name: ux
      agent: ux-reviewer
      paths: ["src/ui/**"]
      advisory: true'

# setup_case <kind: labels|local|nostages|labelonly> <issue fixture> <PR file paths> [changedFiles]
# (labels: the card comes from the issue fixture through the routes; local: the
# case seeds the store itself; every kind is a local board)
setup_case() {
  local backend="$1" issue="$2" files="$3" changed="${4:-}" board='  repo: acme/toy' stages=""
  [ "$backend" = nostages ] || stages="review:
$STAGES_YML"
  # labelonly: a third stage with no paths (routed by its label only)
  [ "$backend" = labelonly ] && stages="$stages
    - name: copy
      agent: copy-reviewer"
  # defaultstage: a third stage with default: true and paths that match nothing
  [ "$backend" = defaultstage ] && stages="$stages
    - name: everyone
      agent: all-reviewer
      paths: [\"nothing/**\"]
      default: true"
  REPO="$(mktemp -d)"
  git init -q "$REPO"
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test User"
  cat > "$REPO/.fleet-board.yml" << YML
board:
$board
worktrees:
  dir: .fw
$stages
YML
  git -C "$REPO" add .fleet-board.yml
  git -C "$REPO" commit -q -m "initial"

  FAKE_GH_DIR="$(mktemp -d)"
  ROUTES="$FAKE_GH_DIR/routes.txt"
  BIN="$FAKE_GH_DIR/bin"
  mkdir -p "$BIN"
  ln -s "$SCRIPT_DIR/fake-gh.sh" "$BIN/gh"

  printf '%s\n' $files | jq -R . | jq -cs --arg c "$changed" \
    '{files: map({path: .})} + (if $c == "" then {changedFiles: length} else {changedFiles: ($c | tonumber)} end)' \
    > "$FAKE_GH_DIR/files.json"

  cat > "$ROUTES" << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
api repos/acme/toy/issues/12	0	$issue
api --paginate repos/acme/toy/issues/12/comments	0	$FIXTURES/labels/comments-none.json
pr view 34 --repo acme/toy --json files*	0	$FAKE_GH_DIR/files.json
pr view 35 --repo acme/toy --json files*	0	$FAKE_GH_DIR/files.json
pr view 36 --repo acme/toy --json files*	1	-
issue edit *	0	-
label create *	0	-
project field-list 7 --owner acme --format json --limit 100	0	$FAKE_GH_DIR/field-list.json
ROUTESEOF

  unset CDPATH FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT || true
  PATH="$BIN:$ORIG_PATH"
  export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH

  cd "$REPO"
  CLEANUP_DIRS+=("$REPO")
  CLEANUP_DIRS+=("$FAKE_GH_DIR")
}

CARD_PLAIN="$FIXTURES/labels/issue-12.json"
CARD_SEC="$STAGES_FIX/issue-12-security.json"
CARD_UX="$STAGES_FIX/issue-12-ux.json"

echo "Test: review-stages.sh"
echo ""

# route: a matching path adds its stage's label
setup_case labels "$CARD_PLAIN" "src/auth/login.js"
run_stages route 12 34
assert_exit "route: exit 0" 0
assert_stdout_exact "route: prints the routed names" '["security"]'
assert_eq "route: adds the security label" "$(cnt issue edit 12 --repo acme/toy --add-label needs-security-review)" 1
assert_eq "route: does not add ux" "$(cnt issue edit 12 --repo acme/toy --add-label needs-ux-review)" 0

# route: idempotent
setup_case labels "$CARD_SEC" "src/auth/login.js"
run_stages route 12 34
assert_stdout_exact "route: already labelled still reported" '["security"]'
assert_eq "route: idempotent, no edit" "$(cnt_prefix issue edit)" 0

# route: a label a person added counts even when no path matches
setup_case labels "$CARD_UX" "README.md"
run_stages route 12 34
assert_stdout_exact "route: a person's label routes" '["ux"]'
assert_eq "route: no edit for a person's label" "$(cnt_prefix issue edit)" 0

# route: nothing matches
setup_case labels "$CARD_PLAIN" "README.md"
run_stages route 12 34
assert_stdout_exact "route: no match prints []" '[]'

# route: a default: true stage routes a card with no label and no path match
setup_case defaultstage "$CARD_PLAIN" "README.md"
run_stages route 12 34
assert_exit "route default: exit 0" 0
assert_stdout_exact "route default: a default true stage is printed for an unlabelled card with no path match" '["everyone"]'

# route: a stage without default is routed as before
setup_case defaultstage "$CARD_PLAIN" "src/auth/login.js"
run_stages route 12 34
assert_stdout_exact "route default: a stage without default is routed by paths only" '["security","everyone"]'

# route: truncated file list
setup_case labels "$CARD_PLAIN" "README.md" 400
run_stages route 12 35
assert_exit "route: truncated exit 0" 0
assert_stdout_exact "route: truncated list routes everywhere" '["security","ux"]'
assert_stderr_contains "route: truncated warning" "PR #35 changes more files than gh listed; routing it to every review stage"
assert_eq "route: truncated adds ux label" "$(cnt issue edit 12 --repo acme/toy --add-label needs-ux-review)" 1

# route: files unreadable
setup_case labels "$CARD_PLAIN" "src/auth/login.js"
run_stages route 12 36
assert_exit "route: files unreadable -> exit 1" 1
assert_stdout_exact "route: files unreadable prints nothing" ''

# route: no stages configured
setup_case nostages "$CARD_PLAIN" "src/auth/login.js"
run_stages route 12 34
assert_exit "route: no stages exit 0" 0
assert_stdout_exact "route: no stages prints []" '[]'
assert_eq "route: no stages, no gh edit" "$(cnt_prefix issue edit)" 0
assert_eq "route: no stages, no gh call at all" "$(ls "$FAKE_GH_DIR/argv" 2>/dev/null | wc -l | tr -d ' ')" 0

# route: usage
run_stages route 12
assert_exit "route: missing PR -> exit 2" 2
run_stages route x 34
assert_exit "route: non-numeric card -> exit 2" 2

# match: the stages whose globs match the PR's current files; read-only
setup_case labels "$CARD_PLAIN" "src/auth/login.js README.md"
run_stages match 34
assert_exit "match: exit 0" 0
assert_stdout_exact "match: prints the matching names" '["security"]'
assert_eq "match: adds no label" "$(cnt_prefix issue edit)" 0
assert_eq "match: does not read the card" "$(cnt api repos/acme/toy/issues/12)" 0

# match: a stage label on the card does not count (globs only)
setup_case labels "$CARD_UX" "README.md"
run_stages match 34
assert_stdout_exact "match: no glob match prints []" '[]'

# match: both stages
setup_case labels "$CARD_PLAIN" "src/auth/a.js src/ui/b.js"
run_stages match 34
assert_stdout_exact "match: config order" '["security","ux"]'

# match: truncated list matches every stage with non-empty paths
setup_case labelonly "$CARD_PLAIN" "README.md" 400
run_stages match 35
assert_exit "match: truncated exit 0" 0
assert_stdout_exact "match: truncated skips the label-only stage" '["security","ux"]'
assert_stderr_contains "match: truncated warning" "PR #35 changes more files than gh listed; routing it to every review stage"
assert_eq "match: truncated adds no label" "$(cnt_prefix issue edit)" 0

# match: files unreadable
setup_case labels "$CARD_PLAIN" "src/auth/login.js"
run_stages match 36
assert_exit "match: files unreadable -> exit 1" 1
assert_stdout_exact "match: files unreadable prints nothing" ''

# match: no stages configured
setup_case nostages "$CARD_PLAIN" "src/auth/login.js"
run_stages match 34
assert_exit "match: no stages exit 0" 0
assert_stdout_exact "match: no stages prints []" '[]'
assert_eq "match: no stages, no gh call at all" "$(ls "$FAKE_GH_DIR/argv" 2>/dev/null | wc -l | tr -d ' ')" 0

# match: usage
run_stages match
assert_exit "match: missing PR -> exit 2" 2
run_stages match x
assert_exit "match: non-numeric PR -> exit 2" 2
run_stages match 34 35
assert_exit "match: extra argument -> exit 2" 2

# route: truncated list still routes a label-only stage (route's own rule)
setup_case labelonly "$CARD_PLAIN" "README.md" 400
run_stages route 12 35
assert_stdout_exact "route: truncated routes the label-only stage too" '["security","ux","copy"]'

# next
setup_case labels "$CARD_UX" "x"
BOTH='["needs-security-review","needs-ux-review"]'
run_stages next --labels "$BOTH" 12
assert_stdout_exact "next: after in_review by default" 'security'
run_stages next --labels "$BOTH" --after review_security 12
assert_stdout_exact "next: after a stage" 'ux'
run_stages next --labels '["needs-ux-review"]' --done '["ux"]' 12
assert_stdout_exact "next: a done stage is skipped" ''
run_stages next --labels '["needs-security-review"]' --after review_ux 12
assert_stdout_exact "next: nothing after the last stage" ''
run_stages next --labels '[]' 12
assert_stdout_exact "next: no label, nothing" ''
run_stages next --labels "$BOTH" --done '["security"]' 12
assert_stdout_exact "next: skips a done stage for the following one" 'ux'
run_stages next 12
assert_stdout_exact "next: reads the card when --labels is absent" 'ux'
run_stages next --after review_nope 12
assert_exit "next: unknown --after -> exit 2" 2
run_stages next --after in_progress 12
assert_exit "next: non-stage --after -> exit 2" 2
run_stages next --labels 'not json' 12
assert_exit "next: bad --labels -> exit 2" 2
run_stages next --done '{"a":1}' 12
assert_exit "next: bad --done -> exit 2" 2

# setup (local backend): stage labels are plain strings in card files; no gh call at all
setup_case local "$CARD_PLAIN" "x"
run_stages setup
assert_exit "setup local: exit 0" 0
assert_eq "setup local: no label create" "$(cnt_prefix label create)" 0
assert_eq "setup local: no gh call at all" "$(ls "$FAKE_GH_DIR/argv" 2>/dev/null | wc -l | tr -d ' ')" 0

# local_store <labels-json>: a local store holding card #12 with those labels,
# and a routes file that answers only the PR file lookups; any other gh call
# (an issue read or edit) has no route and exits 99
local_store() {
  mkdir -p "$REPO/.fleet-board/cards"
  echo 13 > "$REPO/.fleet-board/next"
  jq -n --argjson l "$1" '{number: 12, title: "Card", body: "## Acceptance\n- x", state: "in_progress",
    labels: $l, next_comment_id: 1, comments: [], created_at: "2026-11-06T00:00:00Z"}' \
    > "$REPO/.fleet-board/cards/12.json"
  cat > "$ROUTES" << ROUTESEOF
pr view 34 --repo acme/toy --json files*	0	$FAKE_GH_DIR/files.json
ROUTESEOF
}

# route (local backend): the label lands on the card file, never on GitHub
setup_case local "$CARD_PLAIN" "src/auth/login.js"
local_store '["keep"]'
run_stages route 12 34
assert_exit "route local: exit 0" 0
assert_stdout_exact "route local: prints the routed names" '["security"]'
assert_eq "route local: label on the card file" "$(jq -c .labels "$REPO/.fleet-board/cards/12.json")" '["keep","needs-security-review"]'
assert_eq "route local: no issue edit" "$(cnt_prefix issue edit)" 0
assert_eq "route local: the only gh call is the PR file list" "$(ls "$FAKE_GH_DIR/argv" 2>/dev/null | wc -l | tr -d ' ')" 1

# route (local backend): a label-only stage's label already on the card routes, no write
setup_case labelonly "$CARD_PLAIN" "README.md"
local_store '["needs-copy-review"]'
run_stages route 12 34
assert_exit "route local label-only: exit 0" 0
assert_stdout_exact "route local label-only: routed by the card's label" '["copy"]'
assert_eq "route local label-only: labels unchanged" "$(jq -c .labels "$REPO/.fleet-board/cards/12.json")" '["needs-copy-review"]'

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
