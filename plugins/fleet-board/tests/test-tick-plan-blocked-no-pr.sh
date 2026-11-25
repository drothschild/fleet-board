#!/usr/bin/env bash
#
# Plain-bash tests for tick-plan.sh: a Blocked card with no PR goes back to Ready, and when the
# returns stop (offline, fake gh; each scenario seeds one local card and its manager note). One of
# the tick-plan suites that share tick-plan-lib.sh.
#
# Usage: bash plugins/fleet-board/tests/test-tick-plan-blocked-no-pr.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SCRIPT_DIR/tick-plan-lib.sh"

echo "Test: tick-plan.sh (blocked with no PR)"
echo ""

# nopr_plan <note patch> [extra YAML]: card 20 in Blocked, as the implementor's block with no PR
# leaves it, with the patch merged into its note; then run the plan
nopr_plan() {
  setup_case ready-start "${2:-}"
  export FLEET_BOARD_USER=fleet-bot
  mkdir -p "$REPO/.fleet-board/cards"
  printf '100\n' > "$REPO/.fleet-board/next"
  jq -n '{number: 20, title: "Add subtract", body: "", state: "blocked", labels: [], acceptance: ["it works"],
    blocked_by: [], next_comment_id: 1, comments: [], created_at: "2026-01-01T00:00:00Z"}' \
    > "$REPO/.fleet-board/cards/20.json"
  jq -n --argjson p "$1" '{state: "blocked", blocked_from: "in_progress", branch: "fleet/20-add-subtract",
    blocked_findings: [{severity: "Important", text: "needs a script that does not exist yet"}]} + $p' \
    > "$FAKE_GH_DIR/note.json"
  bash "$NOTE_SH" put 20 "$FAKE_GH_DIR/note.json" >/dev/null || fail "nopr: cannot seed the note" "$1"
  printf '{"state":"OPEN","mergedAt":null}\n' > "$FAKE_GH_DIR/open.json"
  printf '{"state":"MERGED","mergedAt":"2026-01-02T00:00:00Z"}\n' > "$FAKE_GH_DIR/merged.json"
  {
    printf 'pr view 8 --repo acme/toy --json state,mergedAt\t0\t%s/open.json\n' "$FAKE_GH_DIR"
    printf 'pr view 9 --repo acme/toy --json state,mergedAt\t0\t%s/merged.json\n' "$FAKE_GH_DIR"
  } > "$FAKE_GH_DIR/routes"
  FAKE_GH_ROUTES="$FAKE_GH_DIR/routes"; export FAKE_GH_ROUTES
  run_check "$SCRIPT"
}

# ---------------------------------------------------------------------------
# blocked by the implementor with no PR: back to Ready
nopr_plan '{}'
assert_exit "nopr: exit" 0
assert_jq "a Blocked card with no PR, blocked_from in_progress, blocked by the implementor, plans unblock" "$(card 20 action)" '"unblock"'
assert_jq "nopr: reason blocked with no PR; back to Ready" "$(card 20 reason)" '"blocked with no PR; back to Ready"'
assert_jq "nopr: dispatchable" '.dispatchable' 'true'
assert_jq "nopr: no warning" '.warnings' '[]'
nopr_plan '{"no_progress_block": null, "no_pr_returns": 2}'
assert_jq "nopr: 2 returns of max_rounds 3 -> unblock" "$(card 20 action)" '"unblock"'

# ---------------------------------------------------------------------------
# these still wait
nopr_plan '{"pr": 34}'
assert_jq "a Blocked card with a PR still plans skip" "$(card 20 action)" '"skip"'
assert_jq "nopr: with a PR: reason" "$(card 20 reason)" '"blocked"'
nopr_plan '{"blocked_from": "merging"}'
assert_jq "a card blocked from merging still plans skip" "$(card 20 action)" '"skip"'
nopr_plan '{"blocked_from": "ready"}'
assert_jq "a card blocked from ready still plans skip" "$(card 20 action)" '"skip"'
nopr_plan '{"blocked_from": "review_security"}'
assert_jq "a card blocked from a review stage still plans skip" "$(card 20 action)" '"skip"'
nopr_plan '{"blocked_from": "in_review"}'
assert_jq "a card blocked from in_review still plans skip" "$(card 20 action)" '"skip"'
nopr_plan '{"blocked_from": null}'
assert_jq "a card a person blocked (no blocked_from) still plans skip" "$(card 20 action)" '"skip"'
nopr_plan '{"no_progress_block": true}'
assert_jq "a card the supervisor blocked for no progress still plans skip" "$(card 20 action)" '"skip"'
assert_jq "nopr: no-progress block: reason" "$(card 20 reason)" '"blocked"'
nopr_plan '{"blocking_pr": 8}'
assert_jq "a card with no PR that waits for an open blocking PR still plans skip" "$(card 20 action)" '"skip"'

# ---------------------------------------------------------------------------
# the returns stop at review.max_rounds
nopr_plan '{"no_pr_returns": 3}'
assert_jq "a card with no PR whose return count reached max_rounds plans skip" "$(card 20 action)" '"skip"'
assert_jq "nopr: bound: reason" "$(card 20 reason)" '"unblock made no progress after 3 attempts"'
assert_jq "nopr: bound: warning names reset-failures" '.warnings' "$(warns_json "#20: unblock made no progress after 3 attempts; move the card by hand, then run: bash $SCRIPTS_ABS/note.sh reset-failures 20")"
assert_jq "nopr: bound: not dispatchable" '.dispatchable' 'false'
nopr_plan '{"no_pr_returns": 3}' "$(printf 'review:\n  max_rounds: 5')"
assert_jq "nopr: 3 returns of max_rounds 5 -> unblock" "$(card 20 action)" '"unblock"'
nopr_plan '{"no_pr_returns": 3, "blocking_pr": 9}'
assert_jq "nopr: bound holds for a merged blocking PR too" "$(card 20 reason)" '"unblock made no progress after 3 attempts"'
nopr_plan '{"action_failures": 3, "last_action_error": "cannot move the card"}'
assert_jq "nopr: an unblock that keeps failing is skipped" "$(card 20 reason)" '"unblock made no progress after 3 attempts: cannot move the card"'

tp_finish
