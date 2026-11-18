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
  setup_case parallel-all-reported "$(printf '%s\n%s' "$AUTO" "${REVIEW_YAML:-$STAGES_ADVISORY_YAML}")"
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
# The fixer is not dispatched for a card whose only open findings are Declared test changes ([Minor])
R_DECL='{"round":1,"sha":"abc1234","critical":0,"important":0,"findings":[{"severity":"Minor","text":"test/x.sh: declared test change"}]}'
review_note "{"state":"in_review","branch":"fleet/12-add-subtract","pr":34,"round":1,"reviewed_stages":[],"last_review":,"reviews":{"evidence":,"security":{"round":1,"sha":"abc1234","critical":0,"important":0,"stage":"security"}}}"
assert_jq "Declared-only findings: the fixer is not dispatched (not fix)" "$(card 12 action | sed 's/^/(/; s/$/ != "fix")/')" 'true'

# ---------------------------------------------------------------------------
# A clean-reviewed PR whose checks finished red: re-run once, then hand the failure to a fixer
HEAD40=abc1234000000000000000000000000000000000
plan in-review-red-first "$AUTO"
assert_exit "red checks: exit" 0
assert_jq "red checks: a clean current review with a red check and no checks_rerun plans rerun_checks" "$(card 12 action)" '"rerun_checks"'
assert_jq "red checks: the reason names the PR, the head's first 7 characters and the check" "$(card 12 reason)" \
  '"PR #34 checks failed at abc1234 (test-suite); re-running the failed jobs once"'
assert_jq "red checks: rerun_checks is dispatchable" ".dispatchable" 'true'

plan in-review-red-rerun-same "$AUTO"
assert_jq "red checks: checks_rerun at the PR head plans checks_failed" "$(card 12 action)" '"checks_failed"'
assert_jq "red checks: the checks_failed reason" "$(card 12 reason)" \
  '"PR #34 checks still red at abc1234 after a re-run (test-suite)"'

plan in-review-red-rerun-older "$AUTO"
assert_jq "red checks: checks_rerun naming an older head plans rerun_checks again" "$(card 12 action)" '"rerun_checks"'

plan in-review-red-pending "$AUTO"
assert_jq "red checks: a red check beside a pending check waits" "$(card 12 action)" '"wait"'
assert_jq "red checks: the wait reason is unchanged" "$(card 12 reason)" '"waiting for a human merge or green checks"'

export FLEET_BOARD_TODAY=2026-11-11
plan in-review-ignore-red "$(printf 'merge:\n  policy: auto\n  ignore_checks:\n    - name: "lint-*"\n      reason: r\n      until: 2026-12-31\n    - name: "ci/legacy-?int"\n      reason: r\n      until: 2026-12-31\n')"
assert_jq "red checks: a red check matched by an unexpired ignore entry still merges" "$(card 12 action)" '"merge"'
unset FLEET_BOARD_TODAY

plan in-review-red-findings "$AUTO"
assert_jq "red checks: Important findings with red checks plan fix, not rerun_checks" "$(card 12 action)" '"fix"'

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

# A merge-conflict fix keeps its conflicted-files findings when a routed stage has findings at the head
review_note "{$FR_HEAD,\"round\":1,\"last_review\":$R_CLEAN,\"conflicted_files\":[\"src/calc.js\"],\"reviews\":{\"evidence\":$R_CLEAN,\"security\":$SEC_IMP}}"
assert_jq "one fixer pass: a conflict fix keeps its conflicted-files findings beside a stage finding" \
  "$FIXES[0].findings | map(.text)" '["merge conflict in src/calc.js"]'

# Per-reviewer round limits: a reviewer with findings at the head blocks the card when its own count of
# finding rounds reaches its max_rounds; a clean reviewer never blocks
SEC1_YAML="$(printf '%s\n' 'review:' '  stages:' '    - name: security' '      agent: "acme:sec"' '      model: opus' '      max_rounds: 1' \
  '    - name: ux' '      agent: ux-reviewer' '      model: sonnet' '      advisory: true' '      max_rounds: 1')"
PERF2_YAML="$(printf '%s\n' 'review:' '  stages:' '    - name: perf' '      agent: "acme:perf"' '      model: opus' '      label: needs-security-review' '      max_rounds: 2')"
mr_rec() { printf '{"round":%s,"sha":"abc1234","critical":0,"important":%s,%s"findings":[]}' "$1" "$2" "$3"; }
ACTIONS='[.cards[] | select(.number == 12) | .action]'

REVIEW_YAML="$SEC1_YAML"
SEC_I1="$(mr_rec 1 1 '"stage":"security",')"
review_note "{$FR_HEAD,\"round\":1,\"last_review\":$SEC_I1,\"finding_rounds\":{\"security\":{\"count\":1,\"last_round\":1}},\"reviews\":{\"evidence\":$R_CLEAN,\"security\":$SEC_I1}}"
assert_jq "max_rounds: security (max_rounds 1) with a finding and count 1 plans block" "$ACTIONS" '["block"]'
assert_jq "max_rounds: the reason names the reviewer and its limit" "$(card 12 reason) | (contains(\"security\") and contains(\"max_rounds 1\"))" 'true'

# an advisory stage with max_rounds 1 and findings never blocks and is not counted
UX_I1="$(mr_rec 1 1 '"stage":"ux",')"
review_note "{$FR_HEAD,\"round\":1,\"last_review\":$UX_I1,\"finding_rounds\":{\"ux\":{\"count\":1,\"last_round\":1}},\"reviews\":{\"evidence\":$R_CLEAN,\"security\":$(mr_rec 1 0 '"stage":"security",'),\"ux\":$UX_I1}}" security-ux
assert_jq "max_rounds: an advisory stage with findings never blocks" "$ACTIONS" '["merge"]'

# a clean security record at the head never blocks, however high its count
review_note "{$FR_HEAD,\"round\":3,\"last_review\":$(mr_rec 3 0 ''),\"finding_rounds\":{\"security\":{\"count\":5,\"last_round\":2}},\"reviews\":{\"evidence\":$(mr_rec 3 0 ''),\"security\":$(mr_rec 3 0 '"stage":"security",')}}"
assert_jq "max_rounds: a clean reviewer over its limit plans merge" "$ACTIONS" '["merge"]'

# a stage first routed at round 3 has its own count: below its limit the card is fixed, at the limit it blocks
REVIEW_YAML="$PERF2_YAML"
PERF_I3="$(mr_rec 3 1 '"stage":"perf",')"
review_note "{$FR_HEAD,\"round\":3,\"last_review\":$PERF_I3,\"finding_rounds\":{\"perf\":{\"count\":1,\"last_round\":3}},\"reviews\":{\"evidence\":$(mr_rec 3 0 ''),\"perf\":$PERF_I3}}"
assert_jq "max_rounds: perf (max_rounds 2) first routed at round 3 with count 1 plans fix" "$ACTIONS" '["fix"]'
review_note "{$FR_HEAD,\"round\":3,\"last_review\":$PERF_I3,\"finding_rounds\":{\"perf\":{\"count\":2,\"last_round\":3}},\"reviews\":{\"evidence\":$(mr_rec 3 0 ''),\"perf\":$PERF_I3}}"
assert_jq "max_rounds: perf with count 2 plans block" "$ACTIONS" '["block"]'
unset REVIEW_YAML

# the evidence reviewer keeps the default limit of 3: round 3 with findings blocks, with or without finding_rounds
EV_I3="$(mr_rec 3 1 '')"
review_note "{$FR_HEAD,\"round\":3,\"last_review\":$EV_I3,\"finding_rounds\":{\"evidence\":{\"count\":3,\"last_round\":3}},\"reviews\":{\"evidence\":$EV_I3,\"security\":$(mr_rec 3 0 '"stage":"security",')}}"
assert_jq "max_rounds: an evidence finding at round 3 with count 3 plans block" "$ACTIONS" '["block"]'
review_note "{$FR_HEAD,\"round\":3,\"last_review\":$EV_I3,\"reviews\":{\"evidence\":$EV_I3,\"security\":$(mr_rec 3 0 '"stage":"security",')}}"
assert_jq "max_rounds: an evidence finding at round 3 with no finding_rounds plans block" "$ACTIONS" '["block"]'

tp_finish
