#!/usr/bin/env bash
#
# Plain-bash tests for settle.sh (offline: tests/fake-gh.sh answers every gh
# call from a routes file the test builds per case; real scripts do the rest).
# The fake board is static, so a case that needs "the board afterwards"
# rebuilds the routes from what settle.sh wrote (note body, comments).
# No framework, no dependencies beyond POSIX tools, jq and git.
#
# Usage: bash plugins/fleet-board/tests/test-settle.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/../scripts/settle.sh"
PLAN_SH="${SCRIPT_DIR}/../scripts/tick-plan.sh"
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
assert_contains() { # <desc> <text> <fixed string>
  case "$2" in
    *"$3"*) pass "$1" ;;
    *) fail "$1" "expected '$3' in: $2" ;;
  esac
}
assert_not_contains() {
  case "$2" in
    *"$3"*) fail "$1" "did not expect '$3' in: $2" ;;
    *) pass "$1" ;;
  esac
}

run_settle() {
  local tmpout tmperr
  tmpout="$(mktemp)"
  tmperr="$(mktemp)"
  "$BASH_EXE" "$SCRIPT" "$@" > "$tmpout" 2> "$tmperr" </dev/null
  LAST_EXIT=$?
  LAST_OUT="$(cat "$tmpout")"
  LAST_ERR="$(cat "$tmperr")"
  rm -f "$tmpout" "$tmperr"
}

# ---------------------------------------------------------------------------
# Case setup

# setup_case [extra YAML appended to the config]
setup_case() {
  REPO="$(mktemp -d)"
  git init -q "$REPO"
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test User"
  {
    printf 'board:\n  repo: acme/toy\n'
    printf 'worktrees:\n  dir: .fw\n'
    printf 'human_qa_paths: ["src/components/**"]\n'
    [ -n "${1:-}" ] && printf '%s\n' "$1"
  } > "$REPO/.fleet-board.yml"
  git -C "$REPO" add .fleet-board.yml
  git -C "$REPO" commit -q -m "initial"

  FAKE_GH_DIR="$(mktemp -d)"
  FX="$FAKE_GH_DIR/fx"
  mkdir -p "$FX" "$FAKE_GH_DIR/bin"
  ln -s "$SCRIPT_DIR/fake-gh.sh" "$FAKE_GH_DIR/bin/gh"
  PATH="$FAKE_GH_DIR/bin:$ORIG_PATH"
  FAKE_GH_ROUTES="$FAKE_GH_DIR/routes"
  export FAKE_GH_DIR FAKE_GH_ROUTES PATH
  unset CDPATH FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT FLEET_BOARD_CONFIG || true
  cd "$REPO"
  BASE="$(mkdir -p "$REPO/.fw" && cd "$REPO/.fw" && pwd -P)"
  CLEANUP_DIRS+=("$REPO" "$FAKE_GH_DIR")

  R_FIRST="$FX/routes-first"
  R_MAIN="$FX/routes-main"
  : > "$R_FIRST"
  : > "$R_MAIN"
  INPROG=()
  INREV=()
  # Writes every case allows (a failing route is added before these)
  route 'issue edit *' 0 -
  route 'issue comment *' 0 -
  route 'api -X POST repos/acme/toy/issues/*/comments *' 0 "$FX/created.json"
  route 'api -X PATCH repos/acme/toy/issues/comments/* *' 0 -
  route 'api -X PUT *' 0 -
  route 'pr ready *' 0 -
  route 'api user' 0 "$FX/user.json"
  printf '{"login":"fleet-bot"}\n' > "$FX/user.json"
  printf '{"id":9001}\n' > "$FX/created.json"
}

# route <glob> <exit> <fixture or ->      (after the failing routes)
route() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$R_MAIN"; }
# route_first <glob> <exit> <fixture or ->  (wins over every other route)
route_first() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$R_FIRST"; }
# The static routes file; call it before each run (it is rebuilt from the
# route calls, so a case can add routes between runs)
finalize() {
  local col arr
  # Rebuild the column listings from the in-progress / in-review lists
  for col in in_progress in_review; do
    if [ "$col" = in_progress ]; then arr=("${INPROG[@]+"${INPROG[@]}"}"); else arr=("${INREV[@]+"${INREV[@]}"}"); fi
    local items='[]' n
    for n in ${arr[@]+"${arr[@]}"}; do
      items="$(jq -c --argjson n "$n" '. + [{number:$n, title:"Add subtract", url:"u", labels:[{name:"fleet:'"$col"'"}]}]' <<<"$items")"
    done
    printf '%s\n' "$items" > "$FX/list-$col.json"
  done
  {
    cat "$R_FIRST"
    printf 'issue list --repo acme/toy --label fleet:in_progress *\t0\t%s\n' "$FX/list-in_progress.json"
    printf 'issue list --repo acme/toy --label fleet:in_review *\t0\t%s\n' "$FX/list-in_review.json"
    cat "$R_MAIN"
  } > "$FAKE_GH_ROUTES"
}

# card <n> <column> <note json or ""> [extra label]
# The card's issue, its comments (with the note), and its listing.
card() {
  local n="$1" col="$2" note="$3" extra="${4:-}"
  jq -cn --argjson n "$n" --arg l "fleet:$col" --arg x "$extra" \
    '{number:$n, title:"Add subtract", html_url:"https://github.com/acme/toy/issues/\($n)",
      body:"Subtract.\n\n## Acceptance\n- subtract(2,5) returns -3\n",
      labels:([{name:$l}] + (if $x == "" then [] else [{name:$x}] end))}' > "$FX/issue-$n.json"
  if [ -n "$note" ]; then
    jq -cn --arg m "$MARK" --arg j "$note" '
      [{id:555,user:{login:"fleet-bot"},
        body:($m + "\n### fleet-board manager note\nState: x\n\n```json\n" + $j + "\n```\n"),
        created_at:"2026-09-28T00:01:00Z"}]' > "$FX/comments-$n.json"
  else
    printf '[]\n' > "$FX/comments-$n.json"
  fi
  route "api repos/acme/toy/issues/$n" 0 "$FX/issue-$n.json"
  route "api --paginate repos/acme/toy/issues/$n/comments" 0 "$FX/comments-$n.json"
  case "$col" in
    in_progress) INPROG+=("$n") ;;
    in_review) INREV+=("$n") ;;
  esac
}

# pr <pr number> <draft true|false>: the PR's reads (plan, files, hand-off)
pr() {
  local p="$1" draft="$2"
  printf '{"isDraft":%s,"state":"OPEN","mergedAt":null,"statusCheckRollup":[{"conclusion":"SUCCESS"}],"headRefOid":"abc1234"}\n' "$draft" > "$FX/pr-$p.json"
  printf '{"files":[{"path":"src/calc.js"},{"path":"test/calc.test.js"}],"changedFiles":2}\n' > "$FX/files-$p.json"
  printf '{"isDraft":%s,"mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS"}]}\n' "$draft" > "$FX/handoff-$p.json"
  route "pr view $p --repo acme/toy --json isDraft,state,mergedAt,statusCheckRollup,headRefOid" 0 "$FX/pr-$p.json"
  route "pr view $p --repo acme/toy --json files*" 0 "$FX/files-$p.json"
  route "pr view $p --repo acme/toy --json isDraft,mergeable,statusCheckRollup" 0 "$FX/handoff-$p.json"
}

CLEAN_REVIEW_NOTE='{"state":"in_review","branch":"fleet/12-add-subtract","pr":34,"round":1,"last_review":{"round":1,"sha":"abc1234","critical":0,"important":0,"findings":[]}}'

# count of calls.log lines matching a fixed string (0 when no log)
cnt() {
  if [ -f "$FAKE_GH_DIR/calls.log" ]; then grep -cF -- "$1" "$FAKE_GH_DIR/calls.log" || true; else echo 0; fi
}
# Every board, note or PR write
all_writes() {
  local t=0 p c
  for p in "issue edit" "issue comment" "api -X" "pr ready" "pr merge"; do
    c="$(cnt "$p")"; t=$((t + c))
  done
  echo "$t"
}
# The note's JSON as last written (the last input with a manager-note body)
last_note() {
  local f best=""
  for f in "$FAKE_GH_DIR"/inputs/*; do
    [ -f "$f" ] || continue
    if jq -e '.body | startswith("'"$MARK"'")' "$f" >/dev/null 2>&1; then best="$f"; fi
  done
  [ -n "$best" ] || { echo '{}'; return; }
  jq -r '.body' "$best" | awk '/^```json$/{on=1;next} /^```$/{on=0} on' | jq -c .
}
# The text of every comment posted with --body-file
bodies() {
  local f
  for f in "$FAKE_GH_DIR"/bodies/*; do [ -f "$f" ] && { cat "$f"; echo "-----"; }; done
}
handoffs() { bodies | grep -c 'What to check in Human QA' || true; }

echo "Test: settle.sh"
echo ""

# ---------------------------------------------------------------------------
echo "usage"
setup_case
finalize
run_settle extra
assert_exit "an argument is a usage error" 2
assert_eq "usage: no gh call" "$(cnt "")" 0

# ---------------------------------------------------------------------------
echo "no cards: stop without running the planner"
setup_case
finalize
run_settle
assert_exit "empty columns: exit 0" 0
assert_eq "empty columns: only the two listings were made" "$(cnt "")" 2
assert_eq "empty columns: no card read" "$(cnt "api repos")" 0

# ---------------------------------------------------------------------------
echo "in_progress card with a PR moves to in_review (no agent)"
setup_case
card 12 in_progress '{"state":"in_progress","branch":"fleet/12-add-subtract","round":0,"implementor_attempts":1}'
route "pr list --repo acme/toy --head fleet/12-add-subtract --state open --json number" 0 "$FX/prlist.json"
printf '[{"number":34}]\n' > "$FX/prlist.json"
pr 34 true
finalize
run_settle
assert_exit "move_to_review: exit 0" 0
assert_eq "move_to_review: the label moves to in_review" "$(cnt "issue edit 12 --repo acme/toy --add-label fleet:in_review")" 1
assert_eq "move_to_review: the old label is removed" "$(cnt "issue edit 12 --repo acme/toy --remove-label fleet:in_progress")" 1
NOTE="$(last_note)"
assert_eq "move_to_review: note round 1" "$(jq -c .round <<<"$NOTE")" 1
assert_eq "move_to_review: note pr 34" "$(jq -c .pr <<<"$NOTE")" 34
assert_eq "move_to_review: note keeps the branch" "$(jq -c .branch <<<"$NOTE")" '"fleet/12-add-subtract"'
assert_eq "move_to_review: note state in_review" "$(jq -c .state <<<"$NOTE")" '"in_review"'
assert_eq "move_to_review: no PR merge, no ready, no comment" "$(( $(cnt "pr merge") + $(cnt "pr ready") + $(cnt "issue comment") ))" 0

# The board afterwards: the card is in in_review with that note. A tick plan
# gives it the review action.
NOTE_BODY="$(for f in "$FAKE_GH_DIR"/inputs/*; do jq -e '.body | startswith("'"$MARK"'")' "$f" >/dev/null 2>&1 && jq -r .body "$f"; done | tail -n +1)"
setup_case
jq -cn --arg b "$NOTE_BODY" '[{id:555,user:{login:"fleet-bot"},body:$b,created_at:"2026-09-28T00:01:00Z"}]' > "$FX/after-comments.json"
card 12 in_review ""
route_first "api --paginate repos/acme/toy/issues/12/comments" 0 "$FX/after-comments.json"
pr 34 true
INPROG=()
finalize
for col in ready blocked; do printf 'issue list --repo acme/toy --label fleet:%s *\t0\t%s\n' "$col" "$FX/empty.json" >> "$FAKE_GH_ROUTES"; done
printf '[]\n' > "$FX/empty.json"
run_settle_plan() {
  local tmpout; tmpout="$(mktemp)"
  "$BASH_EXE" "$PLAN_SH" > "$tmpout" 2>/dev/null
  LAST_EXIT=$?
  LAST_OUT="$(cat "$tmpout")"
  rm -f "$tmpout"
}
run_settle_plan
assert_exit "plan after settle: exit 0" 0
assert_eq "plan after settle: the card gets the review action" "$(jq -r '.cards[0].action' <<<"$LAST_OUT")" "review"
assert_eq "plan after settle: round 1" "$(jq -r '.cards[0].round' <<<"$LAST_OUT")" 1
assert_eq "plan after settle: pr 34" "$(jq -r '.cards[0].pr' <<<"$LAST_OUT")" 34

# ---------------------------------------------------------------------------
echo "clean review where needs-human-qa is true: human_qa, hand-off once"
setup_case
card 12 in_review "$CLEAN_REVIEW_NOTE" needs-human-qa
pr 34 false
finalize
run_settle
assert_exit "to_human_qa: exit 0" 0
assert_eq "to_human_qa: the label moves to human_qa" "$(cnt "issue edit 12 --repo acme/toy --add-label fleet:human_qa")" 1
assert_eq "to_human_qa: one hand-off comment" "$(handoffs)" 1
MOVE_LINE="$(grep -nF 'issue edit 12 --repo acme/toy --add-label fleet:human_qa' "$FAKE_GH_DIR/calls.log" | head -1 | cut -d: -f1)"
COMMENT_LINE="$(grep -nF 'issue comment 12' "$FAKE_GH_DIR/calls.log" | head -1 | cut -d: -f1)"
assert_eq "to_human_qa: the move comes before the comment" "$([ -n "$MOVE_LINE" ] && [ -n "$COMMENT_LINE" ] && [ "$MOVE_LINE" -lt "$COMMENT_LINE" ] && echo yes || echo no)" yes
assert_eq "to_human_qa: note state human_qa" "$(jq -c .state <<<"$(last_note)")" '"human_qa"'
assert_contains "to_human_qa: no QA build configured says so in the comment" "$(bodies)" "What to check in Human QA"
assert_eq "to_human_qa: no PR merge" "$(cnt "pr merge")" 0

# Run twice: the board keeps the card listed in in_review, now with the
# hand-off comment on it; the second run posts no second one
jq -cn --arg b "$(cat "$FAKE_GH_DIR"/bodies/*)" --arg m "$MARK" --arg j "$CLEAN_REVIEW_NOTE" '
  [{id:555,user:{login:"fleet-bot"},body:($m + "\n### n\n\n```json\n" + $j + "\n```\n"),created_at:"2026-09-28T00:01:00Z"},
   {id:600,user:{login:"fleet-bot"},body:$b,created_at:"2026-09-28T00:02:00Z"}]' > "$FX/comments-12.json"
run_settle
assert_exit "to_human_qa twice: exit 0" 0
assert_eq "to_human_qa twice: still one hand-off comment" "$(handoffs)" 1

# With the card in human_qa, a later run lists nothing and does nothing
INREV=()
before="$(cnt "")"
finalize
run_settle
assert_exit "to_human_qa after the move: exit 0" 0
assert_eq "to_human_qa after the move: only the two listings" "$(( $(cnt "") - before ))" 2

# qa_build runs in the plan card's worktree; its exit code and output reach the comment
setup_case "$(printf 'commands:\n  qa_build: "pwd -P; echo built-ok; exit 3"')"
mkdir -p "$BASE/12-add-subtract"
card 12 in_review "$CLEAN_REVIEW_NOTE" needs-human-qa
pr 34 false
finalize
run_settle
assert_exit "qa_build: exit 0 (a failed build is reported, not a failure)" 0
assert_contains "qa_build: the summary holds the exit code" "$(bodies)" "exit code 3"
assert_contains "qa_build: the summary holds the output" "$(bodies)" "built-ok"
assert_contains "qa_build: it ran in the worktree" "$(bodies)" "$BASE/12-add-subtract"
assert_eq "qa_build: the card still moved" "$(cnt "issue edit 12 --repo acme/toy --add-label fleet:human_qa")" 1

# ---------------------------------------------------------------------------
echo "board-move fails: no hand-off for that card, the next card is handled, exit 1"
setup_case
card 12 in_review "$CLEAN_REVIEW_NOTE" needs-human-qa
card 13 in_review "$(jq -c '.branch = "fleet/13-add-subtract" | .pr = 35' <<<"$CLEAN_REVIEW_NOTE")" needs-human-qa
pr 34 false
pr 35 false
route_first "issue edit 12 *" 1 -
finalize
run_settle
assert_exit "move fails: exit 1" 1
assert_eq "move fails: no comment posted for card 12" "$(cnt "issue comment 12")" 0
assert_eq "move fails: card 13 still moved" "$(cnt "issue edit 13 --repo acme/toy --add-label fleet:human_qa")" 1
assert_eq "move fails: card 13 got its hand-off" "$(cnt "issue comment 13")" 1
assert_eq "move fails: only card 13 wrote a note" "$(cnt "api -X")" 1
assert_eq "move fails: no action_failures counted" "$(jq -c '[.action_failures, .last_action_error]' <<<"$(last_note)")" '[0,null]'

# ---------------------------------------------------------------------------
echo "clean-reviewed draft PR where needs-human-qa is false: gh pr ready"
setup_case
card 12 in_review "$CLEAN_REVIEW_NOTE"
pr 34 true
finalize
run_settle
assert_exit "mark_ready: exit 0" 0
assert_eq "mark_ready: gh pr ready 34 ran once" "$(cnt "pr ready 34 --repo acme/toy")" 1
assert_eq "mark_ready: no merge" "$(cnt "pr merge")" 0
assert_eq "mark_ready: no board edit" "$(cnt "issue edit")" 0

echo "mark_ready fails: exit 1, next card handled"
setup_case
card 12 in_review "$CLEAN_REVIEW_NOTE"
card 13 in_review "$(jq -c '.branch = "fleet/13-add-subtract" | .pr = 35' <<<"$CLEAN_REVIEW_NOTE")"
pr 34 true
pr 35 true
route_first "pr ready 34 *" 1 -
finalize
run_settle
assert_exit "mark_ready fails: exit 1" 1
assert_eq "mark_ready fails: card 13 was still handled" "$(cnt "pr ready 35 --repo acme/toy")" 1

# ---------------------------------------------------------------------------
echo "findings surviving the final round: blocked with blocked_from and blocked_findings"
setup_case
card 12 in_review '{"state":"in_review","branch":"fleet/12-add-subtract","pr":34,"round":3,"last_review":{"round":3,"sha":"abc1234","critical":1,"important":0,"findings":[{"severity":"Critical","text":"test deleted"},{"severity":"Minor","text":"typo"}]}}'
pr 34 false
finalize
run_settle
assert_exit "block: exit 0" 0
assert_eq "block: the label moves to blocked" "$(cnt "issue edit 12 --repo acme/toy --add-label fleet:blocked")" 1
NOTE="$(last_note)"
assert_eq "block: blocked_from in_review" "$(jq -c .blocked_from <<<"$NOTE")" '"in_review"'
assert_eq "block: blocked_findings are the Critical and Important ones" "$(jq -c .blocked_findings <<<"$NOTE")" '[{"severity":"Critical","text":"test deleted"}]'
assert_eq "block: note state blocked" "$(jq -c .state <<<"$NOTE")" '"blocked"'
assert_contains "block: the comment lists the finding" "$(bodies)" "test deleted"
assert_not_contains "block: the Minor finding is not listed" "$(bodies)" "typo"
assert_eq "block: one comment" "$(cnt "issue comment 12")" 1
assert_eq "block: action_failures untouched" "$(jq -c '[.action_failures, .last_action_error]' <<<"$NOTE")" '[0,null]'

echo "an in_progress card the plan blocks with no findings uses the plan's reason"
setup_case
card 12 in_progress '{"state":"in_progress","branch":"fleet/12-add-subtract","round":0,"implementor_attempts":3}'
route "pr list --repo acme/toy --head fleet/12-add-subtract --state open --json number" 0 "$FX/prlist-empty.json"
printf '[]\n' > "$FX/prlist-empty.json"
finalize
run_settle
assert_exit "block no PR: exit 0" 0
NOTE="$(last_note)"
assert_eq "block no PR: blocked_from in_progress" "$(jq -c .blocked_from <<<"$NOTE")" '"in_progress"'
assert_eq "block no PR: blocked_findings holds the plan's reason" "$(jq -c .blocked_findings <<<"$NOTE")" \
  '[{"severity":"Important","text":"implementor produced no PR after 3 attempts"}]'

# ---------------------------------------------------------------------------
echo "a block whose reason starts with 'no progress after' is left for the next tick"
setup_case
card 12 in_review '{"state":"in_review","branch":"fleet/12-add-subtract","pr":34,"round":1,"action_failures":3,"last_action_error":"boom"}'
pr 34 false
finalize
run_settle
assert_exit "no progress: exit 0" 0
assert_eq "no progress: the plan did say block (it was read)" "$(cnt "pr view 34 --repo acme/toy --json isDraft")" 1
assert_eq "no progress: no board, note or PR write at all" "$(all_writes)" 0

# ---------------------------------------------------------------------------
echo "skip actions: no board or note write, and never gh pr merge"
setup_case "$(printf 'merge:\n  policy: auto')"
card 12 in_review "$CLEAN_REVIEW_NOTE"
card 13 in_review '{"state":"in_review","branch":"fleet/13-add-subtract","pr":35,"round":1}'
pr 34 false
pr 35 false
finalize
run_settle
assert_exit "skip: exit 0" 0
assert_eq "skip: clean green non-draft PR on merge.policy auto is not merged" "$(cnt "pr merge")" 0
assert_eq "skip: no board, note or PR write at all" "$(all_writes)" 0

# ---------------------------------------------------------------------------
echo "settle writes no action_failures or last_action_error"
setup_case
card 12 in_review '{"state":"in_review","branch":"fleet/12-add-subtract","pr":34,"round":3,"action_failures":1,"last_action_error":"earlier","last_review":{"round":3,"sha":"abc1234","critical":1,"important":0,"findings":[{"severity":"Critical","text":"x"}]}}'
pr 34 false
route_first "issue edit 12 *" 1 -
finalize
run_settle
assert_exit "failed block: exit 1" 1
assert_eq "failed block: no note write, so the stored count stays for the next tick" "$(cnt "api -X")" 0
assert_eq "failed block: no comment" "$(cnt "issue comment")" 0

# ---------------------------------------------------------------------------
echo "a column listing fails: exit 1, nothing written"
setup_case
card 12 in_progress '{"state":"in_progress","branch":"fleet/12-add-subtract","round":0}'
pr 34 true
route_first "issue list --repo acme/toy --label fleet:in_review *" 1 -
finalize
run_settle
assert_exit "list fails: exit 1" 1
assert_eq "list fails: no write of any kind" "$(all_writes)" 0
assert_eq "list fails: no card was read" "$(cnt "api repos")" 0

echo ""
echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
