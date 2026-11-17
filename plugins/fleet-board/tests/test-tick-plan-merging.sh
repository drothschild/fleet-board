#!/usr/bin/env bash
#
# Plain-bash tests for tick-plan.sh: merging, update_branch, settle mode and merging only reviewed heads
# (offline, fake gh; routes under fixtures/gh/tick/<case>/). One of the tick-plan suites
# split from the old single test-tick-plan.sh; the shared helpers are in tick-plan-lib.sh.
#
# Usage: bash plugins/fleet-board/tests/test-tick-plan-merging.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SCRIPT_DIR/tick-plan-lib.sh"

echo "Test: tick-plan.sh (merging and settle mode)"
echo ""

# in-review-merge-auto
plan in-review-merge-auto "$(printf 'merge:\n  policy: auto')"
assert_jq "in-review-merge-auto: action" "$(card 12 action)" '"merge"'
assert_jq "in-review-merge-auto: dispatchable" '.dispatchable' 'true'

# auto policy with a red rollup waits
plan in-review-merge-auto-red "$(printf 'merge:\n  policy: auto')"
assert_jq "in-review-merge-auto-red: action" "$(card 12 action)" '"wait"'

# AC4.7 merged-verify
plan merged-verify
assert_jq "merged-verify: action" "$(card 12 action)" '"verify_main"'
assert_jq "merged-verify: dispatchable" '.dispatchable' 'true'

# merged with main_check set: finish
plan merged-finish
assert_jq "merged-finish: action" "$(card 12 action)" '"finish"'

# merging (merge.policy auto only): the column is planned, with its own rows
plan merging-open-merge "$AUTO"
assert_jq "merging-open-merge: action" "$(card 12 action)" '"merge"'
assert_jq "merging-open-merge: state" "$(card 12 state)" '"merging"'
assert_jq "merging-open-merge: head sha for the merge" "$(card 12 head_sha)" '"abc1234"'
assert_jq "merging-open-merge: dispatchable" '.dispatchable' 'true'

plan merging-open-no-marker "$AUTO"
assert_jq "merging-open-no-marker: open PR, nothing in flight, plans merge" "$(card 12 action)" '"merge"'

plan merging-open-in-flight "$AUTO"
assert_jq "merging-open-in-flight: action" "$(card 12 action)" '"skip"'
assert_jq "merging-open-in-flight: reason" "$(card 12 reason)" '"merge in flight or refused; supervisor decides"'

plan merging-open-head-moved "$AUTO"
assert_jq "merging-open-head-moved: a head other than the journaled one is not merged" "$(card 12 action)" '"skip"'

plan merging-open-head-unreviewed "$AUTO"
assert_jq "merging-open-head-unreviewed: head moved since the review plans skip" "$(card 12 action)" '"skip"'
assert_jq "merging-open-head-unreviewed: reason" "$(card 12 reason)" '"PR head def5678 differs from the reviewed head abc1234; supervisor decides"'
plan merging-open-red "$AUTO"
assert_jq "merging-open-red: red checks plan skip" "$(card 12 action)" '"skip"'
assert_jq "merging-open-red: reason ends with supervisor decides" "$(jq -r "$(card 12 reason)" <<<"$LAST_OUT" | grep -c 'supervisor decides$')" '1'
plan merging-open-draft "$AUTO"
assert_jq "merging-open-draft: a draft PR plans skip" "$(card 12 action)" '"skip"'
plan merging-open-merge "$(printf 'merge:\n  policy: human')"
assert_jq "merging-open-merge: merge.policy human plans skip" "$(card 12 action)" '"skip"'

# merging after a review of an advisory stage with findings: the findings count as clean
plan merging-advisory-last "$(printf '%s\n%s' "$AUTO" "$STAGES_ADVISORY_YAML")"
assert_jq "merging-advisory-last: an advisory stage's findings do not stop the merge" "$(card 12 action)" '"merge"'
plan merging-blocking-last "$(printf '%s\n%s' "$AUTO" "$STAGES_ADVISORY_YAML")"
assert_jq "merging-blocking-last: a non-advisory stage's findings still skip" "$(card 12 action)" '"skip"'

plan merging-merged-verify "$AUTO"
assert_jq "merging-merged-verify: action" "$(card 12 action)" '"verify_main"'

# A merged, verified merging card finishes only after the merger reported done for this merge
plan merging-merged-finish "$AUTO"
assert_jq "merger gate: merged and verified with no merger result plans after_merge" "$(card 12 action)" '"after_merge"'
assert_jq "merger gate: after_merge is dispatchable" '.dispatchable' 'true'
plan merging-merged-merger-done "$AUTO"
assert_jq "merger gate: merger done for this head plans finish" "$(card 12 action)" '"finish"'
plan merging-merged-merger-attention "$AUTO"
assert_jq "merger gate: merger attention plans skip" "$(card 12 action)" '"skip"'
assert_jq "merger gate: attention reason" "$(card 12 reason)" '"merger needs attention; a person decides"'
plan merging-merged-merger-refusal "$AUTO"
assert_jq "merger gate: a refusal-mode merger record is no after-merge result" "$(card 12 action)" '"after_merge"'
setup_case merging-merged-finish "$AUTO"; run_check "$SCRIPT" --candidates
assert_jq "merger gate: --candidates carries after_merge" '[.candidates[] | select(.number == 12) | .action]' '["after_merge"]'

plan merging-closed-block "$AUTO"
assert_jq "merging-closed-block: action" "$(card 12 action)" '"block"'
assert_jq "merging-closed-block: reason" "$(card 12 reason)" '"PR #34 closed without a merge"'

# a merging card is settled: settle keeps merge and verify_main when --settle-merge
setup_case merging-merged-verify "$AUTO"; run_check "$SCRIPT" --settle-merge 12
assert_jq "settle-merge: a merging card plans verify_main" "$(card 12 action)" '"verify_main"'
setup_case merging-open-merge "$AUTO"; run_check "$SCRIPT" --settle-merge 12
assert_jq "settle-merge: a merging card plans merge" "$(card 12 action)" '"merge"'
settle_skips_merging merging-merged-finish 12
assert_jq "settle: a merging card's finish waits for the next tick" "$(card 12 action)" '"skip"'
setup_case merging-closed-block "$AUTO"; run_check "$SCRIPT" --settle-merge 12
assert_jq "settle: a merging card with a closed PR blocks" "$(card 12 action)" '"block"'

# a merging card appears in the plan's cards without the settle flags (it is listed)
plan merging-open-merge "$AUTO"
assert_jq "merging is listed in the plan" '[.cards[].number]' '[12]'


plan_mergeable in-review-fix 34 CONFLICTING
assert_exit "update_branch: in review, conflicting: exit" 0
assert_jq "update_branch: in review, conflicting PR plans update_branch, not fix" "$(card 12 action)" '"update_branch"'
assert_jq "update_branch: in review, no dispatch action for the card" '[.cards[] | select(.action == "fix" or .action == "review" or .action == "start_review")] | length' '0'

plan_mergeable in-progress-draft-pr 34 CONFLICTING
assert_jq "update_branch: in progress, conflicting PR plans update_branch, not start_review" "$(card 12 action)" '"update_branch"'

plan_mergeable in-review-fix 34 MERGEABLE
assert_jq "update_branch: a mergeable PR keeps its action" "$(card 12 action)" '"fix"'

plan_mergeable in-review-fix 34 UNKNOWN
assert_jq "update_branch: an unknown mergeable state gets no update_branch" "$(card 12 action)" '"fix"'

plan_mergeable in-progress-draft-pr 34 MERGEABLE
assert_jq "update_branch: in progress, mergeable PR keeps start_review" "$(card 12 action)" '"start_review"'


plan_note "$CONFLICT_NOTE"
assert_exit "conflict files: exit" 0
assert_jq "conflict files: a note recording conflicted files plans the fixer" "$(card 12 action)" '"fix"'
assert_jq "conflict files: the findings are every conflicted file, test files included" \
  "$(card 12 findings)" '[{"severity":"Important","text":"merge conflict in src/calc.js"},{"severity":"Important","text":"merge conflict in src/util.js"},{"severity":"Important","text":"merge conflict in test/calc.test.js"}]'
plan_note "$CONFLICT_NOTE" CONFLICTING
assert_jq "conflict files: a still-conflicting PR plans fix, not update_branch again" "$(card 12 action)" '"fix"'

plan_note '{"state":"in_review","branch":"fleet/12-add-subtract","pr":34,"round":1,"last_review":null,"action_failures":0,"last_action_error":null,"conflicted_files":[]}'
assert_jq "resolved merge: last_review reset on the merged head plans review, not merge" "$(card 12 action)" '"review"'
assert_jq "resolved merge: no findings are planned" "$(card 12 findings)" 'null'

plan_note '{"state":"in_review","branch":"fleet/12-add-subtract","pr":34,"round":1,"last_review":null,"action_failures":3,"last_action_error":"merge conflicts","conflicted_files":["src/calc.js"]}'
assert_jq "conflict failures: action_failures at review.max_rounds on a conflicted card plans block" "$(card 12 action)" '"block"'

# ---------------------------------------------------------------------------
setup_case in-review-fix; run_check "$SCRIPT" --settle 12
assert_exit "--settle is gone (the by-hand settle script was its only caller): exit" 2

settle in-review-human-qa-path 12
assert_exit "settle: clean review needing human QA: exit" 0
assert_jq "settle: clean-reviewed card where needs-human-qa.sh says true plans to_human_qa" "$(card 12 action)" '"to_human_qa"'
settle in-review-mark-ready-human 12
assert_jq "settle: clean-reviewed draft PR where needs-human-qa.sh says false plans mark_ready" "$(card 12 action)" '"mark_ready"'
settle in-progress-draft-pr 12
assert_jq "settle: in_progress card with a PR plans move_to_review" "$(card 12 action)" '"move_to_review"'
assert_jq "settle: move_to_review carries the pr" "$(card 12 pr)" '34'
plan in-progress-draft-pr
assert_jq "settle: a plan without --settle still plans start_review" "$(card 12 action)" '"start_review"'
settle in-review-block 12
assert_jq "settle: findings surviving the final round plan block" "$(card 12 action)" '"block"'

settle_skips ready-start 12 start
settle_skips in-progress-no-pr 12 continue_implementor
settle_skips in-review-needs-review 12 review
settle_skips in-review-fix 12 fix
# merge and verify_main are kept by --settle-merge (pinned in the merging cases above), so they are not here.
settle_skips merged-finish 12 finish
settle_skips blocked-unblock 20 unblock
settle_skips pending-followups-hold-card 12 file_pending

settle in-review-mark-ready-human 12
assert_jq "settle: dispatchable is false even for a to-be-acted card" '.dispatchable' 'false'

settle read-failure 12
assert_exit "settle: failed lookup: exit" 0
assert_jq "settle: failed lookup on a named card plans skip" "$(card 12 action)" '"skip"'
assert_jq "settle: failed lookup warns" '[.warnings[] | select(startswith("#12: lookup failed"))] | length' 1

settle in-review-fix 12
assert_jq "settle: output lists only the named card" '[.cards[].number]' '[12]'

plan in-review-fix
run_check "$SCRIPT" --settle-merge
assert_exit "settle: no card exits 2" 2
run_check "$SCRIPT" --settle-merge abc
assert_exit "settle: non-numeric card exits 2" 2
run_check "$SCRIPT" --settle-merge 12 x1
assert_exit "settle: a non-numeric second card exits 2" 2


plan_real conflict
assert_exit "merge-only-reviewed: conflict-resolving merge: exit" 0
assert_jq "merge-only-reviewed: conflict-resolving merge of main after last_review plans review" "$(card 12 action)" '"review"'

plan_real clean
assert_exit "merge-only-reviewed: clean merge: exit" 0
assert_jq "merge-only-reviewed: only a clean merge of main after last_review plans merge" "$(card 12 action)" '"merge"'

plan_real nonmerge
assert_exit "merge-only-reviewed: non-merge commit: exit" 0
assert_jq "merge-only-reviewed: a non-merge commit after last_review does not plan merge" "$(card 12 action | sed 's/^/(/; s/$/ != "merge")/')" 'true'

# A review with findings keeps the drift allowance too: a head moved only by a clean
# merge of main goes to the fixer, not to another review of the same findings.
# Anything else after the review still needs a review before fixing again.
plan_real clean "" "" findings
assert_exit "findings drift: clean merge of main: exit" 0
assert_jq "findings drift: head moved only by a clean merge of main after a review with findings plans fix" "$(card 12 action)" '"fix"'
plan_real conflict "" "" findings
assert_jq "findings drift: a conflict-resolving merge of main after a review with findings plans review" "$(card 12 action)" '"review"'
plan_real nonmerge "" "" findings
assert_jq "findings drift: a non-merge commit after a review with findings plans review" "$(card 12 action)" '"review"'
assert_jq "findings drift: that review gives the head-moved reason" "$(jq -r "$(card 12 reason)" <<<"$LAST_OUT" | grep -c 'review the new commits before fixing again$')" '1'

# A merging card keeps the review row's drift allowance: a head moved only by a clean
# merge of main stays mergeable, unless the PR now needs human QA
plan_real clean merging
assert_exit "merging drift: clean merge of main: exit" 0
assert_jq "merging drift: head moved only by a clean merge of main plans merge" "$(card 12 action)" '"merge"'
plan_real clean merging qa
assert_jq "merging drift: the same head needing human QA plans skip" "$(card 12 action)" '"skip"'
assert_jq "merging drift: that skip ends with supervisor decides" "$(jq -r "$(card 12 reason)" <<<"$LAST_OUT" | grep -c 'supervisor decides$')" '1'
plan_real conflict merging
assert_jq "merging drift: a conflict-resolving merge of main plans skip" "$(card 12 action)" '"skip"'
plan_real nonmerge merging
assert_jq "merging drift: a non-merge commit after the review plans skip" "$(card 12 action)" '"skip"'

# A merging card judged by reviews[<stage>], as the In Review row judges it: every routed stage has a
# clean record at the head, and the evidence reviewer is clean at the head. last_review holds whichever
# report came last, so a stage-less (evidence) record there must not skip a card routed to a stage.
# merging_note <note-json>: the merging-routed-first case with that note, routed to security
merging_note() {
  setup_case merging-routed-first "$(printf '%s\n%s' "$AUTO" "$STAGES_ADVISORY_YAML")"
  local d="$FAKE_GH_DIR/routes.d"
  mkdir -p "$d"
  jq -cn --arg note "$1" '[{id: 555, user: {login: "fleet-bot"},
    body: ("<!-- fleet-board:manager-note -->\n### fleet-board manager note\nState: merging\n\n```json\n" + $note + "\n```\n"),
    created_at: "2026-09-28T00:01:00Z"}]' > "$d/comments.json"
  sed -e "s#	\.\./#	$TICK/#" -e "s#	comments-12.json#	$d/comments.json#" "$TICK/merging-routed-first/routes" > "$d/routes"
  FAKE_GH_ROUTES="$d/routes"; export FAKE_GH_ROUTES
  run_check "$SCRIPT"
}
M_CLEAN='{"round":1,"sha":"abc1234","critical":0,"important":0,"findings":[]}'
M_HEAD='"state":"merging","branch":"fleet/12-add-subtract","pr":34,"round":1,"stage":null'

merging_note "{$M_HEAD,\"reviewed_stages\":[],\"last_review\":$M_CLEAN,\"reviews\":{\"evidence\":$M_CLEAN,\"security\":$(jq -c '.stage="security"' <<<"$M_CLEAN")}}"
assert_jq "merging reviews[]: routed to security, evidence and security clean at the head, last_review the evidence record, plans merge" "$(card 12 action)" '"merge"'

merging_note "{$M_HEAD,\"reviewed_stages\":[],\"last_review\":$M_CLEAN,\"reviews\":{\"evidence\":$M_CLEAN,\"security\":{\"round\":1,\"sha\":\"abc1234\",\"critical\":0,\"important\":1,\"stage\":\"security\"}}}"
assert_jq "merging reviews[]: security holding an Important finding at the head plans skip" "$(card 12 action)" '"skip"'
assert_jq "merging reviews[]: the Important finding's reason names the security stage" "$(jq -r "$(card 12 reason)" <<<"$LAST_OUT" | grep -c 'security')" '1'

merging_note "{$M_HEAD,\"reviewed_stages\":[],\"last_review\":$M_CLEAN,\"reviews\":{\"evidence\":$M_CLEAN}}"
assert_jq "merging reviews[]: no reviews.security record plans skip" "$(card 12 action)" '"skip"'
assert_jq "merging reviews[]: the missing record's reason names security as not reviewed yet" "$(jq -r "$(card 12 reason)" <<<"$LAST_OUT" | grep -c 'security not reviewed yet')" '1'

merging_note "{$M_HEAD,\"reviewed_stages\":[\"security\"],\"last_review\":$M_CLEAN,\"reviews\":{\"evidence\":$M_CLEAN,\"security\":{\"round\":1,\"sha\":\"abc1234\",\"critical\":1,\"important\":0,\"stage\":\"security\"}}}"
assert_jq "merging reviews[]: reviewed_stages listing security does not hide a Critical finding in reviews.security (skip)" "$(card 12 action)" '"skip"'
assert_jq "merging reviews[]: that skip's reason names security" "$(jq -r "$(card 12 reason)" <<<"$LAST_OUT" | grep -c 'security')" '1'


tp_finish
