#!/usr/bin/env bash
#
# Plain-bash tests for tick-plan.sh: blocked cards, pending follow-ups, lookup failures and action failures
# (offline, fake gh; routes under fixtures/gh/tick/<case>/). One of the tick-plan suites
# split from the old single test-tick-plan.sh; the shared helpers are in tick-plan-lib.sh.
#
# Usage: bash plugins/fleet-board/tests/test-tick-plan-followups.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SCRIPT_DIR/tick-plan-lib.sh"

echo "Test: tick-plan.sh (follow-ups and failures)"
echo ""

# ---------------------------------------------------------------------------
# blocked-unblock and blocked-skip
plan blocked-unblock
assert_exit "blocked-unblock: exit" 0
assert_jq "blocked-unblock: action" "$(card 20 action)" '"unblock"'
assert_eq "blocked-unblock: exact blocking PR lookup" \
  "$(call_count pr view 41 --repo acme/toy --json state,mergedAt)" 1
assert_jq "blocked-unblock: dispatchable" '.dispatchable' 'true'
plan blocked-skip
assert_jq "blocked-skip: action" "$(card 20 action)" '"skip"'
assert_jq "blocked-skip: dispatchable" '.dispatchable' 'false'

# AC6.4 nothing-dispatchable: a waiting card and a skipped blocked card
plan nothing-dispatchable
assert_exit "nothing-dispatchable: exit" 0
assert_jq "nothing-dispatchable: cards in state order" '[.cards[] | [.number, .state, .action]]' '[[12,"in_review","wait"],[20,"blocked","skip"]]'
assert_jq "nothing-dispatchable: dispatchable" '.dispatchable' 'false'

# ---------------------------------------------------------------------------
# pending-followups-hold-card
plan pending-followups-hold-card
assert_exit "pending-followups-hold-card: exit" 0
assert_jq "pending-followups-hold-card: action" "$(card 12 action)" '"file_pending"'
assert_jq "pending-followups-hold-card: reason" "$(card 12 reason)" '"pending follow-ups"'
assert_jq "pending-followups-hold-card: dispatchable" '.dispatchable' 'false'
plan pending-followups-none
assert_jq "pending-followups-hold-card: null pending -> mark_ready" "$(card 12 action)" '"mark_ready"'
assert_jq "pending-followups-hold-card: with a PR, no wait-for-PR warning" '[.warnings[] | select(contains("wait for a PR"))] | length' 0
# A blocked card with pending follow-ups and no PR anywhere (pending.pr, note.pr,
# the plan's own lookup) files them without a PR: file_pending, no warning
plan pending-followups-blocked
assert_jq "pending-followups-no-pr: blocked -> file_pending" "$(card 20 action)" '"file_pending"'
assert_jq "pending-followups-no-pr: blocked has no wait-for-PR warning" '.warnings' '[]'
assert_jq "pending-followups-no-pr: blocked dispatchable" '.dispatchable' 'false'
done_case pending-followups-done 30 done '[{"title":"extract math utils"},{"title":"add CLI help"}]'
plan_routes "$DONE_CASE_DIR"
assert_exit "pending-followups-done: exit" 0
assert_jq "pending-followups-done: warning names each title" '[.warnings[] | select(contains("#30"))]' \
  '["pending follow-ups on #30 were never filed (card is done): extract math utils; add CLI help"]'
done_case pending-followups-wont-do 31 wont_do '[{"title":"retry flaky test"}]'
plan_routes "$DONE_CASE_DIR"
assert_jq "pending-followups-wont-do: warning names the title" '[.warnings[] | select(contains("#31"))]' \
  '["pending follow-ups on #31 were never filed (card is wont_do): retry flaky test"]'
plan pending-followups-no-pr-in-progress
assert_exit "pending-followups-no-pr: in_progress exit" 0
assert_jq "pending-followups-no-pr: in_progress -> continue_implementor" "$(card 12 action)" '"continue_implementor"'
assert_jq "pending-followups-no-pr: in_progress warning" '.warnings' '["pending follow-ups on #12 wait for a PR"]'
assert_jq "pending-followups-no-pr: in_progress dispatchable" '.dispatchable' 'true'
# pending.pr and note.pr null, but the plan discovers the PR by branch: filed
plan pending-followups-discovered-pr
assert_jq "pending-followups-discovered-pr: -> file_pending" "$(card 12 action)" '"file_pending"'
assert_jq "pending-followups-discovered-pr: pr 34" "$(card 12 pr)" '34'
assert_jq "pending-followups-discovered-pr: no warning" '.warnings' '[]'

# ---------------------------------------------------------------------------
# lookup-failure-fails-closed
plan lookup-failure-pr-list
assert_exit "lookup-failure-fails-closed: pr list exit" 0
assert_jq "lookup-failure-fails-closed: pr list -> skip" "$(card 12 action)" '"skip"'
assert_jq "lookup-failure-fails-closed: pr list reason" "($(card 12 reason) | startswith(\"lookup failed\"))" 'true'
assert_jq "lookup-failure-fails-closed: pr list warning" '[.warnings[] | select(startswith("lookup failed") or contains("lookup failed"))] | length' 1
assert_jq "lookup-failure-fails-closed: pr list dispatchable" '.dispatchable' 'false'
plan lookup-failure-blocking
assert_jq "lookup-failure-fails-closed: blocking PR -> skip" "$(card 20 action)" '"skip"'
assert_jq "lookup-failure-fails-closed: blocking PR reason" "($(card 20 reason) | startswith(\"lookup failed\"))" 'true'
assert_jq "lookup-failure-fails-closed: blocking PR warning" '[.warnings[] | select(contains("lookup failed"))] | length' 1
assert_jq "lookup-failure-fails-closed: blocking PR dispatchable" '.dispatchable' 'false'
plan lookup-failure-pr-view
assert_jq "lookup-failure-fails-closed: card PR view -> skip" "$(card 12 action)" '"skip"'
assert_jq "lookup-failure-fails-closed: card PR view reason" "($(card 12 reason) | startswith(\"lookup failed\"))" 'true'
assert_jq "lookup-failure-fails-closed: card PR view dispatchable" '.dispatchable' 'false'
plan read-failure
assert_exit "lookup-failure-fails-closed: card read exit" 0
assert_jq "lookup-failure-fails-closed: card read -> skip" "$(card 12 action)" '"skip"'
assert_jq "lookup-failure-fails-closed: card read reason" "($(card 12 reason) | startswith(\"lookup failed\"))" 'true'

# A card whose manager note is invalid is skipped with a warning: note.sh
# merge refuses to write over it, so no action could record its effect
plan invalid-note
assert_exit "invalid-note: exit" 0
assert_jq "invalid-note: action skip" "$(card 12 action)" '"skip"'
assert_jq "invalid-note: reason" "$(card 12 reason)" '"invalid manager note: branch"'
assert_jq "invalid-note: warning" '.warnings' '["#12: invalid manager note: branch; fix or replace it (note.sh put)"]'
assert_jq "invalid-note: dispatchable" '.dispatchable' 'false'
assert_eq "invalid-note: no PR lookup" "$(call_count pr list --repo acme/toy --head fleet/12-add-subtract --state open --json number)" 0

# ---------------------------------------------------------------------------
# Action failures: a card on which the manager's action failed to make
# progress (a failed setup step, a report rejected twice, a failed gh, board
# or script call, a refused merge) review.max_rounds times in a row is
# blocked, whatever action would be next. file_pending still wins (it only
# files, and pending items are never dropped). A block that keeps failing
# (the count reaches 2 * max_rounds) and an unblock that keeps failing (a
# blocked card at max_rounds) are skipped with a warning for a human, so no
# action can leave a card dispatchable forever.
plan action-failures-ready-3
assert_exit "action-failures: ready 3 of 3: exit" 0
assert_jq "action-failures: ready 3 of 3 -> block" "$(card 12 action)" '"block"'
assert_jq "action-failures: ready 3 of 3: reason" "$(card 12 reason)" '"no progress after 3 attempts: fleet-board: cannot add a worktree for fleet/12-add-subtract"'
assert_jq "action-failures: ready 3 of 3: dispatchable" '.dispatchable' 'true'
plan action-failures-ready-2
assert_jq "action-failures: ready 2 of 3 -> start" "$(card 12 action)" '"start"'
plan action-failures-ready-3 "$(printf 'review:\n  max_rounds: 5')"
assert_jq "action-failures: ready 3 of max_rounds 5 -> start" "$(card 12 action)" '"start"'
plan action-failures-in-progress-no-error
assert_jq "action-failures: in_progress 3 -> block" "$(card 12 action)" '"block"'
assert_jq "action-failures: in_progress: reason without a recorded error" "$(card 12 reason)" '"no progress after 3 attempts: no error recorded"'
plan action-failures-in-review-3
assert_exit "action-failures: in_review 3: exit" 0
assert_jq "action-failures: in_review 3, review next -> block" "$(card 12 action)" '"block"'
assert_jq "action-failures: in_review 3: reason" "$(card 12 reason)" '"no progress after 3 attempts: fleet-board: cannot fetch the head of PR #34"'
assert_jq "action-failures: in_review 3: pr still carried" "$(card 12 pr)" '34'
plan action-failures-pending
assert_jq "action-failures: pending follow-ups with a PR -> file_pending" "$(card 12 action)" '"file_pending"'
plan action-failures-blocked-2
assert_jq "action-failures: blocked with merged blocker, 2 of 3 -> unblock" "$(card 20 action)" '"unblock"'
assert_jq "action-failures: blocked 2 of 3: no warning" '.warnings' '[]'
# A blocked card whose unblock keeps failing (the gate refuses the move to
# ready, a misconfigured Ready column) is skipped for a human once the count
# reaches review.max_rounds; it is not retried forever
plan action-failures-blocked
assert_exit "action-failures: blocked 3 of 3: exit" 0
assert_jq "action-failures: blocked 3 of 3 -> skip" "$(card 20 action)" '"skip"'
assert_jq "action-failures: blocked 3 of 3: reason" "$(card 20 reason)" '"unblock made no progress after 3 attempts: card #20 has no acceptance criteria"'
assert_jq "action-failures: blocked 3 of 3: warning" '.warnings' "$(warns_json "#20: unblock made no progress after 3 attempts: card #20 has no acceptance criteria; move the card by hand, then run: bash $SCRIPTS_ABS/note.sh reset-failures 20")"
assert_jq "action-failures: blocked 3 of 3: dispatchable" '.dispatchable' 'false'
plan action-failures-blocked "$(printf 'review:\n  max_rounds: 5')"
assert_jq "action-failures: blocked 3 of max_rounds 5 -> unblock" "$(card 20 action)" '"unblock"'
# The unblock rule only bounds an unblock the table would give: a blocked
# card with no blocking PR, or one not merged yet, is plainly "blocked" (no
# unblock was due, so none failed), whatever its count
plan action-failures-blocked-no-pr
assert_exit "action-failures: blocked 3 of 3, no blocking PR: exit" 0
assert_jq "action-failures: blocked 3 of 3, no blocking PR -> skip" "$(card 20 action)" '"skip"'
assert_jq "action-failures: blocked 3 of 3, no blocking PR: reason" "$(card 20 reason)" '"blocked"'
assert_jq "action-failures: blocked 3 of 3, no blocking PR: no warning" '.warnings' '[]'
plan action-failures-blocked-open-pr
assert_exit "action-failures: blocked 3 of 3, blocking PR open: exit" 0
assert_jq "action-failures: blocked 3 of 3, blocking PR open -> skip" "$(card 20 action)" '"skip"'
assert_jq "action-failures: blocked 3 of 3, blocking PR open: reason" "$(card 20 reason)" '"blocked"'
assert_jq "action-failures: blocked 3 of 3, blocking PR open: no warning" '.warnings' '[]'
# A block that itself keeps failing (board-move N blocked fails, so the card
# stays where it is and the count keeps rising) is retried from max_rounds up
# to 2 * max_rounds - 1, then skipped for a human
plan action-failures-ready-5
assert_jq "action-failures: ready 5 of 3 -> block" "$(card 12 action)" '"block"'
assert_jq "action-failures: ready 5 of 3: reason" "$(card 12 reason)" '"no progress after 5 attempts: fleet-board: cannot add a worktree for fleet/12-add-subtract"'
assert_jq "action-failures: ready 5 of 3: no warning" '.warnings' '[]'
plan action-failures-ready-6
assert_exit "action-failures: ready 6 of 3: exit" 0
assert_jq "action-failures: ready 6 of 3 -> skip" "$(card 12 action)" '"skip"'
assert_jq "action-failures: ready 6 of 3: reason" "$(card 12 reason)" '"could not be blocked after 6 attempts: fleet-board: cannot add a worktree for fleet/12-add-subtract"'
assert_jq "action-failures: ready 6 of 3: warning" '.warnings' "$(warns_json "#12: could not be blocked after 6 attempts: fleet-board: cannot add a worktree for fleet/12-add-subtract; fix the board, move the card by hand, then run: bash $SCRIPTS_ABS/note.sh reset-failures 12")"
assert_jq "action-failures: ready 6 of 3: dispatchable" '.dispatchable' 'false'
plan action-failures-in-review-6
assert_jq "action-failures: in_review 6 of 3 -> skip" "$(card 12 action)" '"skip"'
assert_jq "action-failures: in_review 6 of 3: warning" '.warnings' "$(warns_json "#12: could not be blocked after 6 attempts: fleet-board: cannot fetch the head of PR #34; fix the board, move the card by hand, then run: bash $SCRIPTS_ABS/note.sh reset-failures 12")"
assert_jq "action-failures: in_review 6 of 3: dispatchable" '.dispatchable' 'false'
plan action-failures-ready-6 "$(printf 'review:\n  max_rounds: 5')"
assert_jq "action-failures: ready 6 of max_rounds 5 -> block" "$(card 12 action)" '"block"'
plan action-failures-ready-10 "$(printf 'review:\n  max_rounds: 5')"
assert_jq "action-failures: ready 10 of max_rounds 5 -> skip" "$(card 12 action)" '"skip"'
assert_jq "action-failures: ready 10 of max_rounds 5: warning" '.warnings' "$(warns_json "#12: could not be blocked after 10 attempts: fleet-board: cannot add a worktree for fleet/12-add-subtract; fix the board, move the card by hand, then run: bash $SCRIPTS_ABS/note.sh reset-failures 12")"
assert_jq "action-failures: ready 10 of max_rounds 5: dispatchable" '.dispatchable' 'false'
# Failures that are not setup steps count the same: reviewer and fixer
# reports rejected twice (review next, fix next)
plan action-failures-rejected-review
assert_exit "action-failures: rejected reviewer reports: exit" 0
assert_jq "action-failures: rejected reviewer reports, review next -> block" "$(card 12 action)" '"block"'
assert_jq "action-failures: rejected reviewer reports: reason" "$(card 12 reason)" '"no progress after 3 attempts: reviewer report rejected twice: missing VERIFIED line"'
plan action-failures-rejected-review "$(printf 'review:\n  max_rounds: 5')"
assert_jq "action-failures: rejected reviewer reports under max_rounds 5 -> review" "$(card 12 action)" '"review"'
plan action-failures-rejected-fix
assert_exit "action-failures: rejected fixer reports: exit" 0
assert_jq "action-failures: rejected fixer reports, fix next -> block" "$(card 12 action)" '"block"'
assert_jq "action-failures: rejected fixer reports: reason" "$(card 12 reason)" '"no progress after 3 attempts: fixer report rejected twice: no Fixed section"'
plan action-failures-rejected-fix "$(printf 'review:\n  max_rounds: 5')"
assert_jq "action-failures: rejected fixer reports under max_rounds 5 -> fix" "$(card 12 action)" '"fix"'
# A note written before the rename (setup_failures, last_setup_error) is
# read as action_failures and last_action_error
plan action-failures-legacy-keys
assert_exit "action-failures: legacy setup keys: exit" 0
assert_jq "action-failures: legacy setup keys -> block" "$(card 12 action)" '"block"'
assert_jq "action-failures: legacy setup keys: reason" "$(card 12 reason)" '"no progress after 3 attempts: fleet-board: cannot add a worktree for fleet/12-add-subtract"'
assert_jq "action-failures: legacy setup keys: no warning" '.warnings' '[]'

# The reset command in the warning quotes a scripts dir that the shell would
# split (a space in the install path), so it can be pasted as printed
SPACED="$(mktemp -d)/fleet board"
mkdir -p "$SPACED"
cp -R "$SCRIPT_DIR/../scripts" "$SPACED/scripts"
CLEANUP_DIRS+=("$(dirname "$SPACED")")
setup_case action-failures-blocked
run_check "$SPACED/scripts/tick-plan.sh"
assert_exit "action-failures: scripts dir with a space: exit" 0
assert_jq "action-failures: scripts dir with a space: warning quotes the command path" '.warnings' \
  "$(warns_json "#20: unblock made no progress after 3 attempts: card #20 has no acceptance criteria; move the card by hand, then run: bash '$SPACED/scripts/note.sh' reset-failures 20")"

# A column that cannot be listed fails the whole plan
plan list-failure
assert_exit "list-failure: exit 1" 1
assert_stdout_exact "list-failure: no plan printed" ""


tp_finish
