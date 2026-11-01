#!/usr/bin/env bash
#
# Plain-bash tests for accept.sh (a person records "I accepted this change" on
# a Blocked card) and for how tick-plan.sh and note.sh treat the note's
# `accepted` entry (offline, fake gh, a stub note.sh for accept.sh).
# No framework, no dependencies beyond POSIX tools, jq and git.
#
# Usage: bash plugins/fleet-board/tests/test-accept.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPTS_REAL="$(cd "$SCRIPT_DIR/../scripts" && pwd)"
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

assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}

assert_stderr_contains() {
  case "$LAST_ERR" in
    *"$2"*) pass "$1" ;;
    *) fail "$1" "expected to find '$2' in stderr, got: '$LAST_ERR'" ;;
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

jqc() { jq -c "$1" <<<"$LAST_OUT" 2>/dev/null || echo INVALID; }

# setup_case <issue-labels-json>: a repo, a copy of the scripts whose note.sh
# is a stub that logs its arguments (and the patch file it was given), and a
# fake gh with routes for card 12 whose PR is #34 with head def5678.
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

  STUB_SCRIPTS="$FAKE_GH_DIR/scripts"
  cp -R "$SCRIPTS_REAL" "$STUB_SCRIPTS"
  NOTE_LOG="$FAKE_GH_DIR/note-calls.log"
  PATCH_COPY="$FAKE_GH_DIR/patch-seen.json"
  cat > "$STUB_SCRIPTS/note.sh" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NOTE_LOG"
[ "${1:-}" = merge ] && cat "$3" > "$PATCH_COPY"
exit 0
STUB
  export NOTE_LOG PATCH_COPY

  printf '%s\n' "$1" > "$FAKE_GH_DIR/issue.json"
  printf '[]\n' > "$FAKE_GH_DIR/comments.json"
  printf '{"headRefOid":"def5678abc"}\n' > "$FAKE_GH_DIR/pr-head.json"
  ROUTES="$FAKE_GH_DIR/routes.txt"
  cat > "$ROUTES" << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
api repos/acme/toy/issues/12	0	$FAKE_GH_DIR/issue.json
api --paginate repos/acme/toy/issues/12/comments	0	$FAKE_GH_DIR/comments.json
pr view 34 --repo acme/toy --json headRefOid*	0	$FAKE_GH_DIR/pr-head.json
ROUTESEOF

  unset CDPATH FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT FLEET_BOARD_CONFIG || true
  PATH="$BIN:$ORIG_PATH"
  export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH

  cd "$REPO"
  CLEANUP_DIRS+=("$REPO")
  CLEANUP_DIRS+=("$FAKE_GH_DIR")
}

# set_note_json <json>: the card's comments hold one manager note (by fleet-bot)
set_note_json() {
  jq -cn --arg m "$MARK" --arg j "$1" '
    [{id:555,user:{login:"fleet-bot"},
      body:($m + "\n### fleet-board manager note\nState: x\n\n```json\n" + $j + "\n```\n"),
      created_at:"2026-09-28T00:01:00Z"}]' > "$FAKE_GH_DIR/comments.json"
}

BLOCKED='{"number":12,"title":"Add subtract","html_url":"https://github.com/acme/toy/issues/12","body":"x\n\n## Acceptance\n- subtract works\n","labels":[{"name":"fleet:blocked"}]}'
IN_REVIEW='{"number":12,"title":"Add subtract","html_url":"https://github.com/acme/toy/issues/12","body":"x\n\n## Acceptance\n- subtract works\n","labels":[{"name":"fleet:in_review"}]}'
NOTE='{"state":"blocked","branch":"fleet/12-add-subtract","pr":34,"round":2,"action_failures":4,"last_action_error":"fatal: stuck","last_review":{"round":2,"sha":"abc1234","critical":0,"important":1}}'

run_accept() { run_check "$STUB_SCRIPTS/accept.sh" "$@"; }

echo "accept.sh: a Blocked card"
setup_case "$BLOCKED"
set_note_json "$NOTE"
run_accept 12
assert_exit "accept: a Blocked card with a readable PR head: exit 0" 0
assert_eq "accept: one note.sh call in the stubbed log" "$(wc -l < "$NOTE_LOG" | tr -d ' ')" 1
assert_eq "accept: that call is a merge on card 12" "$(cut -d' ' -f1,2 "$NOTE_LOG")" "merge 12"
assert_eq "accept: failure count reset to 0 and error cleared" \
  "$(jq -c '[.action_failures, .last_action_error]' "$PATCH_COPY" 2>/dev/null)" '[0,null]'
assert_eq "accept: reviewed-sha baseline moved to the PR head" \
  "$(jq -c '.last_review.sha' "$PATCH_COPY" 2>/dev/null)" '"def5678abc"'
assert_eq "accept: records who accepted (authenticated login) and the sha" \
  "$(jq -c '[.accepted.login, .accepted.sha]' "$PATCH_COPY" 2>/dev/null)" '["fleet-bot","def5678abc"]'
assert_eq "accept: records when (UTC timestamp)" \
  "$(jq -r '.accepted.at | test("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\\z")' "$PATCH_COPY" 2>/dev/null)" true

echo "accept.sh: refusals leave the note unchanged"
setup_case "$IN_REVIEW"
set_note_json "$NOTE"
run_accept 12
assert_exit "accept: a card that is not Blocked: exit 1" 1
assert_stderr_contains "accept: not Blocked: says so" "not Blocked"
assert_eq "accept: not Blocked: no note.sh call" "$([ -f "$NOTE_LOG" ] && wc -l < "$NOTE_LOG" | tr -d ' ' || echo 0)" 0

setup_case "$BLOCKED"
set_note_json "$NOTE"
printf 'pr view 34 --repo acme/toy --json headRefOid*\t1\t-\n' > "$ROUTES.new"
grep -v '^pr view' "$ROUTES" >> "$ROUTES.new" && mv "$ROUTES.new" "$ROUTES"
printf 'pr view 34 --repo acme/toy --json headRefOid*\t1\t-\n' >> "$ROUTES"
run_accept 12
assert_exit "accept: PR head unreadable: exit 1" 1
assert_stderr_contains "accept: PR head unreadable: says so" "PR head"
assert_eq "accept: PR head unreadable: no note.sh call" "$([ -f "$NOTE_LOG" ] && wc -l < "$NOTE_LOG" | tr -d ' ' || echo 0)" 0

setup_case "$BLOCKED"
set_note_json '{"state":"blocked","branch":"fleet/12-add-subtract","round":2,"action_failures":4}'
run_accept 12
assert_exit "accept: note names no PR: exit 1" 1
assert_eq "accept: note names no PR: no note.sh call" "$([ -f "$NOTE_LOG" ] && wc -l < "$NOTE_LOG" | tr -d ' ' || echo 0)" 0

echo "note.sh: the accepted entry is validated"
setup_case "$BLOCKED"
set_note_json '{"state":"blocked","accepted":"yes"}'
printf 'api user\t0\t%s\n' "$FIXTURES/labels/user.json" > "$ROUTES"
printf 'api repos/acme/toy/issues/12\t0\t%s\n' "$FAKE_GH_DIR/issue.json" >> "$ROUTES"
printf 'api --paginate repos/acme/toy/issues/12/comments\t0\t%s\n' "$FAKE_GH_DIR/comments.json" >> "$ROUTES"
run_check "$SCRIPTS_REAL/note.sh" get 12
assert_eq "note.sh: a malformed accepted entry makes the note invalid ({})" "$LAST_OUT" "{}"
assert_stderr_contains "note.sh: names the field" "ignoring invalid manager note on #12: accepted"

echo "tick-plan.sh: the accepted baseline"
# tick_case <note-json> <pr-head>: card 12 in In Review with the given note
tick_case() {
  setup_case "$IN_REVIEW"
  set_note_json "$1"
  printf '{"isDraft":true,"state":"OPEN","mergedAt":null,"statusCheckRollup":[],"headRefOid":"%s"}\n' "$2" > "$FAKE_GH_DIR/pr-view.json"
  cat > "$ROUTES" << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
api repos/acme/toy/issues/12	0	$FAKE_GH_DIR/issue.json
api --paginate repos/acme/toy/issues/12/comments	0	$FAKE_GH_DIR/comments.json
pr view 34 --repo acme/toy --json isDraft,state,mergedAt,statusCheckRollup,headRefOid	0	$FAKE_GH_DIR/pr-view.json
issue list --repo acme/toy --label fleet:ready *	0	$FIXTURES/tick/common/empty.json
issue list --repo acme/toy --label fleet:in_progress *	0	$FIXTURES/tick/common/empty.json
issue list --repo acme/toy --label fleet:in_review *	0	$FIXTURES/tick/common/list-in_review-12.json
issue list --repo acme/toy --label fleet:blocked *	0	$FIXTURES/tick/common/empty.json
ROUTESEOF
  run_check "$SCRIPTS_REAL/tick-plan.sh"
}

BEFORE='{"state":"in_review","branch":"fleet/12-add-subtract","pr":34,"round":1,"last_review":{"round":1,"sha":"abc1234","critical":0,"important":1}}'
AFTER='{"state":"in_review","branch":"fleet/12-add-subtract","pr":34,"round":1,"action_failures":0,"last_review":{"round":1,"sha":"def5678abc","critical":0,"important":1},"accepted":{"login":"fleet-bot","at":"2026-10-30T10:00:00Z","sha":"def5678abc"}}'

tick_case "$BEFORE" def5678abc
assert_eq "tick-plan: before the accept the commits are flagged (review)" "$(jqc '.cards[0].action')" '"review"'
tick_case "$AFTER" def5678abc
assert_exit "tick-plan: after the accept: exit 0" 0
assert_eq "tick-plan: after the accept the earlier commits are not flagged" "$(jqc '.cards[0].action')" '"fix"'
tick_case "$AFTER" 9999999fff
assert_eq "tick-plan: a commit pushed after the accept is flagged again" "$(jqc '.cards[0].action')" '"review"'
tick_case "$(jq -c '.accepted.login = "mallory"' <<<"$AFTER")" def5678abc
assert_eq "tick-plan: an accept by another login is not honored (review)" "$(jqc '.cards[0].action')" '"review"'
assert_eq "tick-plan: the reason names the unhonored accept" \
  "$(jq -r '.cards[0].reason | contains("not honored")' <<<"$LAST_OUT")" true

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
