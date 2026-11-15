#!/usr/bin/env bash
#
# Plain-bash tests for tick-plan.sh: the Ready column: start, in-progress and the dependency gate
# (offline, fake gh; routes under fixtures/gh/tick/<case>/). One of the tick-plan suites
# split from the old single test-tick-plan.sh; the shared helpers are in tick-plan-lib.sh.
#
# Usage: bash plugins/fleet-board/tests/test-tick-plan-ready.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SCRIPT_DIR/tick-plan-lib.sh"

echo "Test: tick-plan.sh (ready and dependency gates)"
echo ""

# ---------------------------------------------------------------------------
# AC1.1 ready-start
plan ready-start
assert_exit "ready-start: exit" 0
assert_jq "ready-start: one card" '.cards | length' 1
assert_jq "ready-start: action start" "$(card 12 action)" '"start"'
assert_jq "ready-start: branch" "$(card 12 branch)" '"fleet/12-add-subtract"'
assert_jq "ready-start: worktree under the normalized base" "$(card 12 worktree)" "\"$BASE/12-add-subtract\""
assert_jq "ready-start: models.implementor sonnet" "$(card 12 models.implementor)" '"sonnet"'
assert_jq "ready-start: models" "$(card 12 models)" "$DEFAULT_MODELS"
assert_jq "ready-start: not escalated" "$(card 12 escalated)" 'false'
assert_jq "ready-start: state, title, pr, round" "(.cards[0] | [.state, .title, .pr, .round])" '["ready","Add subtract",null,null]'
assert_jq "ready-start: needs_human_qa and comment_needed are null" "(.cards[0] | [.needs_human_qa, .comment_needed])" '[null,null]'
assert_jq "ready-start: dispatchable" '.dispatchable' 'true'
# AC6.3 with the defaults, no warning
assert_jq "shared-model-warning: defaults give warnings == []" '.warnings' '[]'

# AC6.3 shared-model-warning
plan ready-start "$(printf 'models:\n  implementor: opus')"
assert_exit "shared-model-warning: exit" 0
assert_jq "shared-model-warning: exact warning" '.warnings' '["implementor and reviewer share model opus; the reviewer shares the writer'"'"'s blind spots"]'
assert_jq "shared-model-warning: contains 'share model opus'" '[.warnings[] | select(contains("share model opus"))] | length' 1

# AC1.6 ready-no-acceptance-first
plan ready-no-acceptance-first
assert_exit "ready-no-acceptance-first: exit" 0
assert_jq "ready-no-acceptance-first: action" "$(card 13 action)" '"skip_no_acceptance"'
assert_jq "ready-no-acceptance-first: comment_needed" "$(card 13 comment_needed)" 'true'
assert_jq "ready-no-acceptance-first: dispatchable" '.dispatchable' 'true'

# AC1.6 ready-no-acceptance-repeat
plan ready-no-acceptance-repeat
assert_exit "ready-no-acceptance-repeat: exit" 0
assert_jq "ready-no-acceptance-repeat: only card" '[.cards[].number]' '[13]'
assert_jq "ready-no-acceptance-repeat: action" "$(card 13 action)" '"skip_no_acceptance"'
assert_jq "ready-no-acceptance-repeat: comment_needed" "$(card 13 comment_needed)" 'false'
assert_jq "ready-no-acceptance-repeat: dispatchable" '.dispatchable' 'false'

# slug-fallback
plan slug-fallback
assert_jq "slug-fallback: branch" "$(card 12 branch)" '"fleet/12-card"'
assert_jq "slug-fallback: worktree" "$(card 12 worktree)" "\"$BASE/12-card\""

# note-branch-wins
plan note-branch-wins
assert_exit "note-branch-wins: exit" 0
assert_jq "note-branch-wins: branch from the note" "$(card 12 branch)" '"fleet/12-custom"'

# note-round-null-ok: a default note with round and implementor_attempts null
plan note-round-null-ok
assert_exit "note-round-null-ok: plan exit" 0
assert_jq "note-round-null-ok: action start" "$(card 12 action)" '"start"'
assert_stderr_not_contains "note-round-null-ok: no warning from the plan" "warning"
run_check "$NOTE_SH" get 12
assert_exit "note-round-null-ok: note.sh get exit" 0
assert_stderr_exact "note-round-null-ok: note.sh get writes nothing to stderr" ""
assert_eq "note-round-null-ok: note.sh get returns the note" "$(jq -c '[.state, .round, .implementor_attempts, .out_of_scope_created]' <<<"$LAST_OUT" 2>/dev/null)" '["ready",null,null,[]]'

# ---------------------------------------------------------------------------
# in-progress-no-pr
plan in-progress-no-pr
assert_exit "in-progress-no-pr: exit" 0
assert_jq "in-progress-no-pr: action" "$(card 12 action)" '"continue_implementor"'
assert_jq "in-progress-no-pr: pr null" "$(card 12 pr)" 'null'
assert_eq "in-progress-no-pr: exact pr list lookup" \
  "$(call_count pr list --repo acme/toy --head fleet/12-add-subtract --state open --json number)" 1
assert_jq "in-progress-no-pr: dispatchable" '.dispatchable' 'true'

# implementor-attempts-bounded
plan implementor-attempts-bounded-3
assert_exit "implementor-attempts-bounded: 3 exit" 0
assert_jq "implementor-attempts-bounded: 3 attempts of 3 -> block" "$(card 12 action)" '"block"'
assert_jq "implementor-attempts-bounded: reason" "$(card 12 reason)" '"implementor produced no PR after 3 attempts"'
assert_eq "implementor-attempts-bounded: 3 still looked for a PR" \
  "$(call_count pr list --repo acme/toy --head fleet/12-add-subtract --state open --json number)" 1
plan implementor-attempts-bounded-1
assert_jq "implementor-attempts-bounded: 1 attempt -> continue_implementor" "$(card 12 action)" '"continue_implementor"'
assert_eq "implementor-attempts-bounded: 1 looked for a PR" \
  "$(call_count pr list --repo acme/toy --head fleet/12-add-subtract --state open --json number)" 1

# pr-discovered-by-branch
plan pr-discovered-by-branch
assert_exit "pr-discovered-by-branch: exit" 0
assert_jq "pr-discovered-by-branch: action" "$(card 12 action)" '"start_review"'
assert_jq "pr-discovered-by-branch: pr 34" "$(card 12 pr)" '34'

# AC1.2 in-progress-draft-pr
plan in-progress-draft-pr
assert_exit "in-progress-draft-pr: exit" 0
assert_jq "in-progress-draft-pr: action" "$(card 12 action)" '"start_review"'
assert_jq "in-progress-draft-pr: pr" "$(card 12 pr)" '34'
assert_eq "in-progress-draft-pr: one PR view" \
  "$(call_count pr view 34 --repo acme/toy --json isDraft,state,mergedAt,statusCheckRollup,headRefOid)" 1

# ---------------------------------------------------------------------------
# Dependency gate: a Ready card with an unmet blocker (blocked_by) waits

plan deps-wait
assert_exit "deps-wait: exit" 0
assert_jq "deps-wait: action wait" "$(card 12 action)" '"wait"'
assert_jq "deps-wait: reason names the dependency and its state" "$(card 12 reason)" '"waits for acme/toy#22 (backlog)"'
assert_jq "deps-wait: waiting_on lists the unmet refs" "$(card 12 waiting_on)" '["acme/toy#22"]'
assert_jq "deps-wait: the card stays in ready" "$(card 12 state)" '"ready"'
assert_jq "deps-wait: not dispatchable" '.dispatchable' 'false'
assert_jq "deps-wait: no warnings" '.warnings' '[]'

plan deps-met
assert_jq "deps-met: every dependency closed as completed, the card starts" "$(card 12 action)" '"start"'
assert_jq "deps-met: waiting_on is null" "$(card 12 waiting_on)" 'null'
assert_jq "deps-met: dispatchable" '.dispatchable' 'true'

plan deps-not-planned
assert_jq "deps-not-planned: action wait" "$(card 12 action)" '"wait"'
assert_jq "deps-not-planned: reason" "$(card 12 reason)" '"waits for acme/toy#22 (wont_do)"'
assert_jq "deps-not-planned: warning" '.warnings' '["#12 depends on acme/toy#22, which was closed as not planned"]'

plan deps-lookup-failure
assert_exit "deps-lookup-failure: exit" 0
assert_jq "deps-lookup-failure: action skip" "$(card 12 action)" '"skip"'
assert_jq "deps-lookup-failure: reason names the command" "$(card 12 reason)" '"lookup failed: local card #22"'
assert_jq "deps-lookup-failure: warning" '.warnings' '["#12: lookup failed: local card #22"]'
assert_jq "deps-lookup-failure: not dispatchable" '.dispatchable' 'false'

plan deps-bad-line
assert_jq "deps-bad-line: a line that is no dependency does not hold the card" "$(card 12 action)" '"start"'

plan deps-in-progress-not-gated
assert_jq "deps-in-progress-not-gated: in_progress is never gated" "$(card 12 action)" '"continue_implementor"'

# A body larger than the pipe buffer: the Depends on heading is found early,
# and the gate must still hold (a pre-check that SIGPIPEs would skip it)
BIG="$(mktemp -d)"
CLEANUP_DIRS+=("$BIG")
{ printf '## Depends on\n- #22\n\n'; head -c 80000 /dev/zero | tr '\0' 'x'; printf '\n\n## Acceptance\n- subtract(2,5) returns -3\n'; } > "$BIG/body.md"
jq -cn --rawfile b "$BIG/body.md" '{number: 12, title: "Add subtract", html_url: "u", body: $b, labels: [{name: "fleet:ready"}]}' > "$BIG/issue-12.json"
sed -e "s|\.\./common/issue-12-ready-dep22\.json|$BIG/issue-12.json|" -e "s|\.\./common/|$TICK/common/|" -e "s|\.\./\.\./labels/|$TICK/../labels/|" \
  "$TICK/deps-wait/routes" > "$BIG/routes"
setup_case deps-wait
FAKE_GH_ROUTES="$BIG/routes"
export FAKE_GH_ROUTES
run_check "$SCRIPT"
assert_jq "deps-large-body: the gate holds for a body bigger than the pipe buffer" "$(card 12 action)" '"wait"'

# The same with ## Acceptance first: the Acceptance check must find it too
{ printf '## Acceptance\n- subtract(2,5) returns -3\n\n## Depends on\n- #22\n\n'; head -c 80000 /dev/zero | tr '\0' 'x'; printf '\n'; } > "$BIG/body.md"
jq -cn --rawfile b "$BIG/body.md" '{number: 12, title: "Add subtract", html_url: "u", body: $b, labels: [{name: "fleet:ready"}]}' > "$BIG/issue-12.json"
setup_case deps-wait
FAKE_GH_ROUTES="$BIG/routes"
export FAKE_GH_ROUTES
run_check "$SCRIPT"
assert_jq "deps-large-body: Acceptance first in a large body is still found, the card waits" "$(card 12 action)" '"wait"'

plan deps-no-acceptance
assert_jq "deps-no-acceptance: no Acceptance wins over the gate" "$(card 13 action)" '"skip_no_acceptance"'

plan deps-other-card-starts
assert_jq "deps-other-card-starts: the card with the dependency waits" "$(card 12 action)" '"wait"'
assert_jq "deps-other-card-starts: the other card starts" "$(card 14 action)" '"start"'
assert_jq "deps-other-card-starts: dispatchable reflects the other card" '.dispatchable' 'true'
assert_jq "deps-other-card-starts: a card with no dependencies has waiting_on null" "$(card 14 waiting_on)" 'null'


tp_finish
