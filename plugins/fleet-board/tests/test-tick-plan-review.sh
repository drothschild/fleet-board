#!/usr/bin/env bash
#
# Plain-bash tests for tick-plan.sh: in_review: review, fix, escalation, human QA, drift and re-review
# (offline, fake gh; routes under fixtures/gh/tick/<case>/). One of the tick-plan suites
# split from the old single test-tick-plan.sh; the shared helpers are in tick-plan-lib.sh.
#
# Usage: bash plugins/fleet-board/tests/test-tick-plan-review.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SCRIPT_DIR/tick-plan-lib.sh"

echo "Test: tick-plan.sh (in-review and re-review)"
echo ""

# ---------------------------------------------------------------------------
# in-review-needs-review
plan in-review-needs-review
assert_exit "in-review-needs-review: exit" 0
assert_jq "in-review-needs-review: action" "$(card 12 action)" '"review"'
assert_jq "in-review-needs-review: dispatchable" '.dispatchable' 'true'

# in-review-fix
plan in-review-fix
assert_jq "in-review-fix: action" "$(card 12 action)" '"fix"'

# in-review-head-moved: the round-1 review found an Important issue at
# abc1234, but the PR head is now def5678. A fixer already pushed and its
# report was never reconciled (no round bump), so fixing again would redo the
# work; the new commits need a review instead.
plan in-review-head-moved
assert_exit "in-review-head-moved: exit" 0
assert_jq "in-review-head-moved: action" "$(card 12 action)" '"review"'
assert_jq "in-review-head-moved: reason" "$(card 12 reason)" \
  '"PR head def5678 differs from the round 1 review at abc1234; review the new commits before fixing again"'
assert_jq "in-review-head-moved: round unchanged" "$(card 12 round)" '1'
assert_jq "in-review-head-moved: dispatchable" '.dispatchable' 'true'

# Review drift warnings: commits after the last reviewed sha (abc1234)
um='[.warnings[] | select(contains("unreviewed_merge"))] | length'
te='[.warnings[] | select(contains("test_edit_after_review"))] | length'

# A merge of main on the PR head, made after the last reviewed sha
plan drift-merge
assert_exit "drift-merge: exit" 0
assert_jq "drift-merge: unreviewed_merge warning" "$um" '1'
assert_jq "drift-merge: no test_edit_after_review (main's own commits are not the PR's)" "$te" '0'
assert_jq "drift-merge: action unchanged" "$(card 12 action)" '"review"'

# A commit after the last reviewed sha touches a file matching test_paths
plan drift-test-edit
assert_exit "drift-test-edit: exit" 0
assert_jq "drift-test-edit: test_edit_after_review warning" "$te" '1'
assert_jq "drift-test-edit: no unreviewed_merge" "$um" '0'
assert_jq "drift-test-edit: action unchanged" "$(card 12 action)" '"review"'

# Neither condition: no drift warning
plan drift-clean
assert_exit "drift-clean: exit" 0
assert_jq "drift-clean: no drift warnings" '[.warnings[] | select(contains("unreviewed_merge") or contains("test_edit_after_review"))] | length' '0'
assert_jq "drift-clean: warnings empty" '.warnings' '[]'

# The existing head-moved check is unchanged when the drift lookups are unroutable
plan in-review-head-moved
assert_jq "in-review-head-moved: no drift warnings" '.warnings' '[]'

# in-review-head-same-full-sha: the note holds the short sha abc1234 and the
# PR head is its full 40-character form. That is the same commit, so the plan
# stays fix; reading it as a move would plan a review on every tick.
plan in-review-head-same-full-sha
assert_jq "in-review-head-same-full-sha: action" "$(card 12 action)" '"fix"'
# AC6.2 escalation at round 1: not yet
assert_jq "escalation: round 1 models" "$(card 12 models)" "$DEFAULT_MODELS"
assert_jq "escalation: round 1 not escalated" "$(card 12 escalated)" 'false'

# AC6.2 escalation at round 2
plan escalation-round2
assert_jq "escalation: round 2 action fix" "$(card 12 action)" '"fix"'
assert_jq "escalation: round 2 models.implementor opus" "$(card 12 models.implementor)" '"opus"'
assert_jq "escalation: round 2 models.fixer opus" "$(card 12 models.fixer)" '"opus"'
assert_jq "escalation: round 2 models.reviewer unchanged" "$(card 12 models.reviewer)" '"opus"'
assert_jq "escalation: round 2 escalated" "$(card 12 escalated)" 'true'
assert_jq "escalation: round 2 round" "$(card 12 round)" '2'

# models.escalation unset: escalated models equal the reviewer's, exactly as before
plan escalation-round2
assert_jq "escalation unset: models" "$(card 12 models)" "$ESCALATED_MODELS"
assert_jq "escalation unset: no warning" '.warnings' '[]'

# models.escalation: X sends implementor and fixer to X; reviewer unchanged
plan escalation-round2 "$(printf 'models:\n  escalation: fable')"
assert_exit "escalation set: exit" 0
assert_jq "escalation set: models" "$(card 12 models)" '{"implementor":"fable","reviewer":"opus","fixer":"fable"}'
assert_jq "escalation set: escalated" "$(card 12 escalated)" 'true'
assert_jq "escalation set: no warning" '.warnings' '[]'

# models.escalation set: before the escalation round the configured models still apply
plan in-review-fix "$(printf 'models:\n  escalation: fable')"
assert_jq "escalation set: round 1 models" "$(card 12 models)" "$DEFAULT_MODELS"

# models.escalation equal to models.reviewer: warn that the writer shares the reviewer's model
plan escalation-round2 "$(printf 'models:\n  escalation: opus')"
assert_jq "escalation equals reviewer: exact warning" '.warnings' '["escalation and reviewer share model opus; the escalated writer shares the reviewer'"'"'s blind spots"]'

# AC1.7 in-review-block
plan in-review-block
assert_exit "in-review-block: exit" 0
assert_jq "in-review-block: action" "$(card 12 action)" '"block"'
assert_jq "in-review-block: dispatchable" '.dispatchable' 'true'

# AC1.3 in-review-human-qa-label
plan in-review-human-qa-label
assert_jq "in-review-human-qa-label: action" "$(card 12 action)" '"to_human_qa"'
assert_jq "in-review-human-qa-label: needs_human_qa" "$(card 12 needs_human_qa)" 'true'

# AC1.3 in-review-human-qa-path
plan in-review-human-qa-path
assert_jq "in-review-human-qa-path: action" "$(card 12 action)" '"to_human_qa"'
assert_jq "in-review-human-qa-path: needs_human_qa" "$(card 12 needs_human_qa)" 'true'

# AC1.4 in-review-mark-ready-human
plan in-review-mark-ready-human
assert_exit "in-review-mark-ready-human: exit" 0
assert_jq "in-review-mark-ready-human: action" "$(card 12 action)" '"mark_ready"'
assert_jq "in-review-mark-ready-human: needs_human_qa false" "$(card 12 needs_human_qa)" 'false'
assert_jq "in-review-mark-ready-human: no card merges" '[.cards[] | select(.action == "merge")] | length' 0

# AC1.4 in-review-waits-human
plan in-review-waits-human
assert_jq "in-review-waits-human: action" "$(card 12 action)" '"wait"'
assert_jq "in-review-waits-human: no card merges" '[.cards[] | select(.action == "merge")] | length' 0
assert_jq "in-review-waits-human: dispatchable" '.dispatchable' 'false'

# in_review with no PR known: skip, never dispatch a reviewer at nothing
plan in-review-no-pr
assert_jq "in-review-no-pr: action" "$(card 12 action)" '"skip"'
assert_jq "in-review-no-pr: dispatchable" '.dispatchable' 'false'
assert_jq "in-review-no-pr: warning" '.warnings' '["#12: in review, but no PR is known"]'

# in_review with a PR closed without merge: skip with a warning
plan in-review-closed-pr
assert_jq "in-review-closed-pr: action" "$(card 12 action)" '"skip"'
assert_jq "in-review-closed-pr: a warning" '.warnings | length' 1

# The human-QA lookup gate matches the table: a clean review of a round at
# least the note's (last_review.round 2, note.round 1) is not "review", so the
# lookup must run, or the card would skip as "human-QA need unknown" forever
plan in-review-review-ahead
assert_exit "in-review-review-ahead: exit" 0
assert_jq "in-review-review-ahead: action mark_ready" "$(card 12 action)" '"mark_ready"'
assert_jq "in-review-review-ahead: needs_human_qa false" "$(card 12 needs_human_qa)" 'false'
assert_eq "in-review-review-ahead: one files lookup" "$(call_count pr view 34 --repo acme/toy --json files,changedFiles)" 1
assert_jq "in-review-review-ahead: no warning" '.warnings' '[]'

# When the human-QA answer is still unknown, the skip is not silent. The real
# needs-human-qa.sh never prints null, so a copy of the scripts dir with a
# stub that does stands in for it.
setup_case in-review-mark-ready-human
STUB_SCRIPTS="$(mktemp -d)"
CLEANUP_DIRS+=("$STUB_SCRIPTS")
cp -R "$SCRIPT_DIR/../scripts/." "$STUB_SCRIPTS/"
printf '#!/usr/bin/env bash\necho null\n' > "$STUB_SCRIPTS/needs-human-qa.sh"
run_check "$STUB_SCRIPTS/tick-plan.sh"
assert_exit "human-qa-unknown: exit" 0
assert_jq "human-qa-unknown: action skip" "$(card 12 action)" '"skip"'
assert_jq "human-qa-unknown: reason" "$(card 12 reason)" '"human-QA need unknown"'
assert_jq "human-qa-unknown: warning" '.warnings' '["human-QA need unknown for #12"]'
assert_jq "human-qa-unknown: dispatchable" '.dispatchable' 'false'

# A note worktree outside the current base (repo moved, worktrees.dir changed)
# reads as null; the plan says so in its warnings, not only on stderr
plan note-worktree-outside-base
assert_exit "note-worktree-outside-base: exit" 0
assert_jq "note-worktree-outside-base: action" "$(card 12 action)" '"continue_implementor"'
assert_jq "note-worktree-outside-base: worktree is the default under the base" "$(card 12 worktree)" "\"$BASE/12-add-subtract\""
assert_jq "note-worktree-outside-base: warning" '.warnings' \
  "[\"manager note on #12 names a worktree outside $BASE; treating it as null: /old-clone/.fw/12-add-subtract\"]"

# ---------------------------------------------------------------------------
plan in-review-mark-ready-human
assert_eq "gh-calls: clean current review (mark_ready): 3 per card" "$(per_card_calls)" 3
assert_eq "gh-calls: clean current review: one files lookup" "$(call_count pr view 34 --repo acme/toy --json files,changedFiles)" 1
plan in-review-fix
assert_eq "gh-calls: findings (fix): 2 per card, no files lookup" "$(per_card_calls)" 2
assert_jq "gh-calls: findings: needs_human_qa not computed" "$(card 12 needs_human_qa)" 'null'
plan in-review-needs-review
assert_eq "gh-calls: review not current (review): 2 per card, no files lookup" "$(per_card_calls)" 2
plan in-review-human-qa-label
assert_eq "gh-calls: labelled card: 2 per card, no files lookup" "$(per_card_calls)" 2
assert_jq "gh-calls: labelled card still -> to_human_qa" "$(card 12 action)" '"to_human_qa"'

# ---------------------------------------------------------------------------
# Re-review instead of fixing again (not_reproducible, and a card returned
# from Blocked). Variants of in-review-fix with a different note, built at run
# time under a temp tree that links the shared fixtures.
VROOT="$(mktemp -d)"
CLEANUP_DIRS+=("$VROOT")
mkdir -p "$VROOT/tick"
ln -s "$TICK/common" "$VROOT/tick/common"
ln -s "$SCRIPT_DIR/../fixtures/gh/labels" "$VROOT/labels"


# The latest fixer report is not_reproducible: plan review, not fix
variant fixer-not-reproducible pr-34-draft.json \
  "{\"state\":\"in_review\",$BASE_NOTE,$LR,\"last_fix\":{\"status\":\"not_reproducible\",\"round\":1}}"
assert_exit "fixer-not-reproducible: exit" 0
assert_jq "fixer-not-reproducible: action" "$(card 12 action)" '"review"'
assert_jq "fixer-not-reproducible: dispatchable" '.dispatchable' 'true'

# A fixer report that was a plain failure (blocked) still plans fix
variant fixer-blocked-last-fix pr-34-draft.json \
  "{\"state\":\"in_review\",$BASE_NOTE,$LR,\"last_fix\":{\"status\":\"blocked\",\"round\":1}}"
assert_jq "fixer-blocked-last-fix: action stays fix" "$(card 12 action)" '"fix"'

# Returned from Blocked to In review: the note still says blocked, the head is
# the reviewed head, and an Important finding is open
variant returned-from-blocked pr-34-draft.json \
  "{\"state\":\"blocked\",\"blocked_from\":\"in_review\",\"blocked_findings\":[{\"severity\":\"Important\",\"text\":\"subtract ignores negatives\"}],$BASE_NOTE,$LR}"
assert_exit "returned-from-blocked: exit" 0
assert_jq "returned-from-blocked: action" "$(card 12 action)" '"review"'
assert_jq "returned-from-blocked: dispatchable" '.dispatchable' 'true'

# Returned from Blocked: the review carries the moved-back reason
variant returned-from-blocked-reason pr-34-draft.json \
  "{\"state\":\"blocked\",\"blocked_from\":\"in_review\",\"blocked_findings\":[{\"severity\":\"Important\",\"text\":\"subtract ignores negatives\"}],$BASE_NOTE,$LR}"
assert_jq "returned-from-blocked-reason: reason" "$(card 12 reason)" \
  '"moved back from Blocked; review PR head abc1234 again before fixing"'

# The head moved after the finding: unchanged from today (review, same reason)
variant returned-head-moved pr-34-draft-head-moved.json \
  "{\"state\":\"blocked\",\"blocked_from\":\"in_review\",\"blocked_findings\":[{\"severity\":\"Important\",\"text\":\"subtract ignores negatives\"}],$BASE_NOTE,$LR}"
assert_jq "returned-head-moved: action" "$(card 12 action)" '"review"'
assert_jq "returned-head-moved: reason is today's head-moved reason" "$(card 12 reason)" \
  '"PR head def5678 differs from the round 1 review at abc1234; review the new commits before fixing again"'

# An ordinary in-review card with an open finding and an unchanged head still fixes
variant in-review-note-state pr-34-draft.json \
  "{\"state\":\"in_review\",$BASE_NOTE,$LR}"
assert_jq "in-review-note-state: action stays fix" "$(card 12 action)" '"fix"'

# usage
plan ready-start
run_check "$SCRIPT" extra
assert_exit "usage: arguments rejected" 2


# A stage counts as done in In Review only by its own clean record at the head: a stage listed in
# reviewed_stages (kept when a card moves back from a retired stage column) with a Critical finding
# in reviews.security is not done, and the card is not merged.
# review_note <note-json>: the parallel-all-reported case on an open, green PR routed to security
review_note() {
  setup_case parallel-all-reported "$(printf '%s\n%s' "$AUTO" "$STAGES_ADVISORY_YAML")"
  local d="$FAKE_GH_DIR/routes.d"
  mkdir -p "$d"
  jq -cn --arg note "$1" '[{id: 555, user: {login: "fleet-bot"},
    body: ("<!-- fleet-board:manager-note -->\n### fleet-board manager note\nState: x\n\n```json\n" + $note + "\n```\n"),
    created_at: "2026-09-28T00:01:00Z"}]' > "$d/comments.json"
  sed -e "s#	\.\./#	$TICK/#" -e "s#	comments-12.json#	$d/comments.json#" \
      -e "s#issue-12-in_review-security-ux#issue-12-in_review-${2:-security}#" -e "s#pr-34-draft#pr-34-open-green#" \
      "$TICK/parallel-all-reported/routes" > "$d/routes"
  FAKE_GH_ROUTES="$d/routes"; export FAKE_GH_ROUTES
  run_check "$SCRIPT"
}
R_CLEAN='{"round":1,"sha":"abc1234","critical":0,"important":0,"findings":[]}'
review_note "{\"state\":\"in_review\",\"branch\":\"fleet/12-add-subtract\",\"pr\":34,\"round\":1,\"reviewed_stages\":[\"security\"],\"last_review\":$R_CLEAN,\"reviews\":{\"evidence\":$R_CLEAN,\"security\":{\"round\":1,\"sha\":\"abc1234\",\"critical\":1,\"important\":0,\"stage\":\"security\"}}}"
assert_exit "reviewed_stages vs reviews: exit" 0
assert_jq "reviewed_stages vs reviews: a stage in reviewed_stages with a Critical finding in reviews.security is not merged" "$(card 12 action | sed 's/^/(/; s/$/ != "merge")/')" 'true'
assert_jq "reviewed_stages vs reviews: the card is fixed for security's finding, not merged (fix)" "$(card 12 action)" '"fix"'
review_note "{\"state\":\"in_review\",\"branch\":\"fleet/12-add-subtract\",\"pr\":34,\"round\":1,\"reviewed_stages\":[],\"last_review\":$R_CLEAN,\"reviews\":{\"evidence\":$R_CLEAN,\"security\":{\"round\":1,\"sha\":\"abc1234\",\"critical\":0,\"important\":0,\"stage\":\"security\"}}}"
assert_jq "reviewed_stages vs reviews: a clean security record at the head still merges" "$(card 12 action)" '"merge"'

# One fixer pass for every reviewer's findings. Card 12 is routed to security (blocking); with the
# issue "security-ux" it is routed to ux (advisory) as well.
fr_imp() { printf '{"round":1,"sha":"abc1234","critical":0,"important":1,%s"findings":[{"severity":"Important","text":"%s"}]}' "$1" "$2"; }
FR_HEAD='"state":"in_review","branch":"fleet/12-add-subtract","pr":34'
EV_IMP="$(fr_imp '' 'evidence flaw')"
SEC_IMP="$(fr_imp '"stage":"security",' 'security flaw')"
UX_IMP="$(fr_imp '"stage":"ux",' 'ux flaw')"
FIXES='[.cards[] | select(.number == 12 and .action == "fix")]'

review_note "{$FR_HEAD,\"round\":1,\"last_review\":$SEC_IMP,\"reviews\":{\"evidence\":$EV_IMP,\"security\":$SEC_IMP}}"
assert_jq "one fixer pass: findings from both reviewers plan one fix row" "$FIXES | length" '1'
assert_jq "one fixer pass: the row lists both findings, each labelled with its reviewer" "$FIXES[0].findings | map({reviewer, text})" \
  '[{"reviewer":"evidence","text":"evidence flaw"},{"reviewer":"security","text":"security flaw"}]'

review_note "{$FR_HEAD,\"round\":1,\"last_review\":$SEC_IMP,\"reviews\":{\"evidence\":$R_CLEAN,\"security\":$SEC_IMP}}"
assert_jq "one fixer pass: a clean evidence record with a security finding plans fix" "$FIXES | length" '1'
assert_jq "one fixer pass: the finding is labelled security" "$FIXES[0].findings | map({reviewer, text})" '[{"reviewer":"security","text":"security flaw"}]'

review_note "{$FR_HEAD,\"round\":1,\"last_review\":$EV_IMP,\"reviews\":{\"evidence\":$EV_IMP}}"
assert_jq "one fixer pass: an evidence finding with no security record at the head plans no fix" "$FIXES | length" '0'
assert_jq "one fixer pass: security is planned to review" '[.cards[] | select(.number == 12 and .action == "review_stage") | .stage.name]' '["security"]'

review_note "{$FR_HEAD,\"round\":1,\"last_review\":$UX_IMP,\"reviews\":{\"evidence\":$R_CLEAN,\"security\":$R_CLEAN,\"ux\":$UX_IMP}}" security-ux
assert_jq "one fixer pass: an advisory stage's findings cause no fix" "$FIXES | length" '0'
review_note "{$FR_HEAD,\"round\":1,\"last_review\":$UX_IMP,\"reviews\":{\"evidence\":$EV_IMP,\"security\":$R_CLEAN,\"ux\":$UX_IMP}}" security-ux
assert_jq "one fixer pass: an advisory stage's findings are left out of the row" "$FIXES[0].findings | map(.reviewer)" '["evidence"]'

# After a fix moves the head (records at round 1, the card at round 2), every routed reviewer reviews again
review_note "{$FR_HEAD,\"round\":2,\"last_review\":$SEC_IMP,\"reviews\":{\"evidence\":$R_CLEAN,\"security\":$SEC_IMP}}"
assert_jq "one fixer pass: after the fix both review and review_stage are planned" \
  '[.cards[] | select(.number == 12) | .action] | sort' '["review","review_stage"]'

tp_finish
