#!/usr/bin/env bash
#
# Plain-bash tests for human-qa-handoff.sh (offline, fake gh).
# Usage: /bin/bash plugins/fleet-board/tests/test-human-qa-handoff.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SCRIPT_DIR/store-sync.sh" # the local store, rebuilt from the routes before each run
SCRIPT="${SCRIPT_DIR}/../scripts/human-qa-handoff.sh"
FIXTURES="$SCRIPT_DIR/../fixtures/gh"

unset FLEET_BOARD_CONFIG FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT || true

PASS=0
FAIL=0
LAST_EXIT=0
LAST_ERR=""
CLEANUP_DIRS=()
ORIG_PATH="$PATH"
SENTENCE="No agent moves this card out of Human QA; move it to Done yourself once it is merged and checked."

cleanup() {
  for dir in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do
    rm -rf "$dir" 2>/dev/null || true
  done
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

# setup_case <card body> <PR json>
setup_case() {
  local body="$1" pr="$2"
  REPO="$(mktemp -d)"
  git init -q "$REPO"
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test User"
  printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\n' > "$REPO/.fleet-board.yml"
  git -C "$REPO" add .fleet-board.yml
  git -C "$REPO" commit -q -m "initial"

  FAKE_GH_DIR="$(mktemp -d)"
  ROUTES="$FAKE_GH_DIR/routes.txt"
  BIN="$FAKE_GH_DIR/bin"
  mkdir -p "$BIN"
  ln -s "$SCRIPT_DIR/fake-gh.sh" "$BIN/gh"

  jq -n --arg b "$body" '{number:12,title:"Add subtract",html_url:"https://github.com/acme/toy/issues/12",body:$b,labels:[{name:"fleet:human_qa"}]}' > "$FAKE_GH_DIR/issue.json"
  printf '%s\n' "$pr" > "$FAKE_GH_DIR/pr.json"
  printf '[]\n' > "$FAKE_GH_DIR/comments.json"
  cat > "$ROUTES" << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
api repos/acme/toy/issues/12	0	$FAKE_GH_DIR/issue.json
api --paginate repos/acme/toy/issues/12/comments	0	$FAKE_GH_DIR/comments.json
pr view 34 --repo acme/toy --json *	0	$FAKE_GH_DIR/pr.json
issue comment 12 --repo acme/toy --body-file *	0	-
ROUTESEOF

  unset CDPATH FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT FLEET_BOARD_CONFIG || true
  PATH="$BIN:$ORIG_PATH"
  export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH
  cd "$REPO"
  CLEANUP_DIRS+=("$REPO" "$FAKE_GH_DIR")
  POSTED_TOTAL=0
}

# run_handoff: runs the script; BODY is the last posted comment (empty if none)
# (the comment lands on the local card: BODY is the newest comment the run
# added to card 12, and posted_count the comments the runs since setup_case
# added, as the fake gh's call log counted them)
run_handoff() {
  local before=0
  store_sync
  [ -f "$REPO/.fleet-board/cards/12.json" ] && before="$(jq '.comments | length' "$REPO/.fleet-board/cards/12.json")"
  /bin/bash "$SCRIPT" 12 34 > "$FAKE_GH_DIR/out" 2> "$FAKE_GH_DIR/err"
  LAST_EXIT=$?
  LAST_ERR="$(cat "$FAKE_GH_DIR/err")"
  BODY=""
  POSTED=0
  if [ -f "$REPO/.fleet-board/cards/12.json" ]; then
    POSTED=$(( $(jq '.comments | length' "$REPO/.fleet-board/cards/12.json") - before ))
    [ "$POSTED" -gt 0 ] && BODY="$(jq -r '.comments[-1].body' "$REPO/.fleet-board/cards/12.json")"
  fi
  POSTED_TOTAL=$(( ${POSTED_TOTAL:-0} + POSTED ))
}

posted_count() { echo "${POSTED_TOTAL:-0}"; }

assert_has() { # name text
  case "$BODY" in *"$2"*) pass "$1" ;; *) fail "$1" "expected '$2' in comment (exit $LAST_EXIT, stderr: $LAST_ERR): $BODY" ;; esac
}
assert_lacks() {
  [ -n "$BODY" ] || { fail "$1" "no comment was posted (exit $LAST_EXIT, stderr: $LAST_ERR)"; return; }
  case "$BODY" in *"$2"*) fail "$1" "did not expect '$2' in comment: $BODY" ;; *) pass "$1" ;; esac
}

PLAIN_BODY=$'Do it.\n\n## Acceptance\n- subtract(2,5) returns -3\n'
PR_OK='{"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS"}]}'

echo "Test: human-qa-handoff.sh"
echo ""

# Draft PR gets a mark-ready step
setup_case "$PLAIN_BODY" '{"isDraft":true,"mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS"}]}'
run_handoff
assert_has "draft PR: comment contains a step to mark it ready" "- [ ] Mark the PR ready for review"

# Conflicting PR gets a resolve-conflict step
setup_case "$PLAIN_BODY" '{"isDraft":false,"mergeable":"CONFLICTING","statusCheckRollup":[{"conclusion":"SUCCESS"}]}'
run_handoff
assert_has "conflicting PR: comment contains a step to resolve the conflict" "- [ ] Resolve the merge conflict"

# No checks
setup_case "$PLAIN_BODY" '{"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[]}'
run_handoff
assert_has "no checks: comment says no CI ran on the PR" "No CI ran on the PR"

# Human QA bullets become checklist items
setup_case $'Do it.\n\n## Acceptance\n- subtract(2,5) returns -3\n\n## Human QA\n- Open the app and subtract two numbers\n- Check the layout on a phone\n\n## Other\n- not a QA item\n' "$PR_OK"
run_handoff
assert_has "human qa bullet 1 appears as a checklist item" "- [ ] Open the app and subtract two numbers"
assert_has "human qa bullet 2 appears as a checklist item" "- [ ] Check the layout on a phone"
assert_lacks "bullets outside the Human QA section are not checklist items" "not a QA item"

# The sentence, asserted with grep -F
printf '%s\n' "$BODY" > "$FAKE_GH_DIR/body.txt"
if grep -F "$SENTENCE" "$FAKE_GH_DIR/body.txt" >/dev/null; then
  pass "comment contains the no-agent-moves sentence (grep -F)"
else
  fail "comment contains the no-agent-moves sentence (grep -F)" "missing sentence in: $BODY"
fi

# Nothing to do and no Human QA section: only the plain statement, no checklist
setup_case "$PLAIN_BODY" "$PR_OK"
run_handoff
assert_has "clean PR without Human QA section: plain statement is present" "$SENTENCE"
assert_lacks "clean PR without Human QA section: no empty checklist" "- [ ]"

# Posted once per hand-off
setup_case "$PLAIN_BODY" '{"isDraft":true,"mergeable":"MERGEABLE","statusCheckRollup":[]}'
run_handoff
first="$(posted_count)"
jq -n --arg b "$BODY" '[{id:700,user:{login:"fleet-bot"},body:$b,created_at:"2026-09-28T00:00:00Z"}]' > "$FAKE_GH_DIR/comments.json"
run_handoff
second="$(posted_count)"
if [ "$first" = 1 ] && [ "$second" = 1 ]; then
  pass "second tick on the same state posts nothing"
else
  fail "second tick on the same state posts nothing" "comment posts after first run: $first, after second: $second"
fi

# A clean PR with no Human QA section prints no checklist header either
setup_case "$PLAIN_BODY" "$PR_OK"
run_handoff
assert_lacks "clean PR without Human QA section: no checklist header" "Before merging:"

# Unresolved findings in the manager note become checklist items
note_comment() { # <note json>: a manager-note comment fed to the fake gh
  local nb
  nb="$(printf '<!-- fleet-board:manager-note -->\n## Manager note\n\nsummary\n\n```json\n%s\n```\n' "$1")"
  jq -n --arg b "$nb" '[{id:800,user:{login:"fleet-bot"},body:$b,created_at:"2026-09-28T00:00:00Z"}]' > "$FAKE_GH_DIR/comments.json"
}
setup_case "$PLAIN_BODY" "$PR_OK"
note_comment '{"blocked_findings":[{"severity":"Critical","text":"test was deleted"},{"severity":"Important","text":"subtract(2,5) returns 3"}]}'
run_handoff
assert_has "unresolved finding 1 appears as a checklist item" "- [ ] [Critical] test was deleted"
assert_has "unresolved finding 2 appears as a checklist item" "- [ ] [Important] subtract(2,5) returns 3"
assert_has "unresolved findings get a findings section" "Unresolved findings"

setup_case "$PLAIN_BODY" "$PR_OK"
note_comment '{"blocked_findings":[]}'
run_handoff
assert_lacks "no unresolved findings: no findings section" "Unresolved findings"
assert_lacks "no unresolved findings: no checklist" "- [ ]"

# card fields on the local backend: the Acceptance quote comes from the field
local_handoff() { # acceptance-json body
  setup_case "$PLAIN_BODY" "$PR_OK"
  printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\n' > "$REPO/.fleet-board.yml"
  mkdir -p "$REPO/.fleet-board/cards"
  echo 13 > "$REPO/.fleet-board/next"
  jq -n --argjson a "$1" --arg b "$2" \
    '{number: 12, title: "Add subtract", body: $b, acceptance: $a, blocked_by: [], state: "human_qa", labels: [], next_comment_id: 1, comments: [], created_at: "2026-11-06T00:00:00Z"}' \
    > "$REPO/.fleet-board/cards/12.json"
  /bin/bash "$SCRIPT" 12 34 > "$FAKE_GH_DIR/out" 2> "$FAKE_GH_DIR/err"
  LAST_EXIT=$?
  LAST_ERR="$(cat "$FAKE_GH_DIR/err")"
  BODY="$(jq -r '.comments[-1].body // ""' "$REPO/.fleet-board/cards/12.json")"
}
local_handoff '["subtract(2,5) returns -3","divide by zero errors"]' $'## Human QA\n- Open the app\n'
assert_has "local: acceptance field items are quoted" "> - subtract(2,5) returns -3"
assert_has "local: every acceptance item is quoted" "> - divide by zero errors"
assert_has "local: Human QA bullets still come from the body" "- [ ] Open the app"
local_handoff '[]' $'## Acceptance\n- stale body bullet\n'
assert_lacks "local: acceptance [] quotes nothing whatever the body says" "stale body bullet"

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
