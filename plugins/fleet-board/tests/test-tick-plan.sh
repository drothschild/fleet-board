#!/usr/bin/env bash
#
# Plain-bash tests for tick-plan.sh (offline, fake gh). One scenario per case;
# each has a committed routes file under fixtures/gh/tick/<case>/.
# No framework, no dependencies beyond POSIX tools, jq and git.
#
# Usage: bash plugins/fleet-board/tests/test-tick-plan.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SCRIPT_DIR/store-sync.sh" # the local store, rebuilt from the routes before each run
SCRIPT="${SCRIPT_DIR}/../scripts/tick-plan.sh"
NOTE_SH="${SCRIPT_DIR}/../scripts/note.sh"
TICK="$SCRIPT_DIR/../fixtures/gh/tick"
# The absolute scripts dir, as tick-plan.sh resolves its own (cd && pwd)
SCRIPTS_ABS="$(cd "$SCRIPT_DIR/../scripts" && pwd)"

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

assert_stdout_exact() {
  if [ "$LAST_OUT" = "$2" ]; then pass "$1"; else fail "$1" "expected stdout: '$2', got: '$LAST_OUT'"; fi
}

assert_stderr_exact() {
  if [ "$LAST_ERR" = "$2" ]; then pass "$1"; else fail "$1" "expected exact stderr: '$2', got: '$LAST_ERR'"; fi
}

assert_stderr_not_contains() {
  case "$LAST_ERR" in
    *"$2"*) fail "$1" "did not expect '$2' in stderr" ;;
    *) pass "$1" ;;
  esac
}

assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}

run_check() {
  store_sync
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

# jq -c of the last stdout; INVALID when it does not parse
jqc() { jq -c "$1" <<<"$LAST_OUT" 2>/dev/null || echo INVALID; }

# assert_jq <desc> <filter> <expected compact JSON>
assert_jq() { assert_eq "$1" "$(jqc "$2")" "$3"; }

# setup_case <case> [extra YAML appended to the config]
setup_case() {
  REPO="$(mktemp -d)"
  git init -q "$REPO"
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test User"
  {
    printf 'board:\n  repo: acme/toy\n'
    [ -n "${3:-}" ] && printf '%s\n' "$3"
    printf 'worktrees:\n  dir: .fw\n'
    printf 'human_qa_paths: ["src/components/**"]\n'
    [ -n "${2:-}" ] && printf '%s\n' "$2"
  } > "$REPO/.fleet-board.yml"
  git -C "$REPO" add .fleet-board.yml
  git -C "$REPO" commit -q -m "initial"

  FAKE_GH_DIR="$(mktemp -d)"
  BIN="$FAKE_GH_DIR/bin"
  mkdir -p "$BIN"
  ln -s "$SCRIPT_DIR/fake-gh.sh" "$BIN/gh"

  # Reset environment between cases
  unset CDPATH FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT FLEET_BOARD_CONFIG || true
  PATH="$BIN:$ORIG_PATH"
  FAKE_GH_ROUTES="$TICK/$1/routes"
  export FAKE_GH_DIR FAKE_GH_ROUTES PATH

  cd "$REPO"
  BASE="$(mkdir -p "$REPO/.fw" && cd "$REPO/.fw" && pwd -P)"

  CLEANUP_DIRS+=("$REPO")
  CLEANUP_DIRS+=("$FAKE_GH_DIR")
}

# plan <case> [extra YAML]: set up and run tick-plan.sh
plan() { setup_case "$@"; run_check "$SCRIPT"; }

# warns_json <text>...: the compact JSON array of the given warnings
warns_json() { jq -cn '$ARGS.positional' --args "$@"; }

# card <n> <field>: jq path of one card in the plan
card() { printf '(.cards[] | select(.number == %d)).%s' "$1" "$2"; }

# The calls whose argv (one element per line) is exactly the given words
call_count() {
  local want f n=0
  want="$(printf '%s\n' "$@")"
  for f in "$FAKE_GH_DIR"/argv/*; do
    [ -f "$f" ] || continue
    [ "$(cat "$f")" = "$want" ] && n=$((n + 1))
  done
  echo "$n"
}

DEFAULT_MODELS='{"implementor":"sonnet","reviewer":"opus","fixer":"sonnet"}'
ESCALATED_MODELS='{"implementor":"opus","reviewer":"opus","fixer":"opus"}'

echo "Test: tick-plan.sh"
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
AUTO="$(printf 'merge:\n  policy: auto')"
STAGES_ADVISORY_YAML="$(printf '%s\n' 'review:' '  stages:' '    - name: security' '      agent: "acme:sec"' '      model: opus' '    - name: ux' '      agent: ux-reviewer' '      model: sonnet' '      advisory: true')"
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
settle_skips_merging() { setup_case "$1" "$AUTO"; run_check "$SCRIPT" --settle-merge "$2"; }
settle_skips_merging merging-merged-finish 12
assert_jq "settle: a merging card's finish waits for the next tick" "$(card 12 action)" '"skip"'
setup_case merging-closed-block "$AUTO"; run_check "$SCRIPT" --settle-merge 12
assert_jq "settle: a merging card with a closed PR blocks" "$(card 12 action)" '"block"'

# a merging card appears in the plan's cards without the settle flags (it is listed)
plan merging-open-merge "$AUTO"
assert_jq "merging is listed in the plan" '[.cards[].number]' '[12]'

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
# gh calls for one in_review card: the card is read from the local store (no
# gh call), then the PR view, the mergeable lookup, and the files lookup only
# when the review is clean and current. (On the GitHub board the card read
# added three: api user, issue, comments; before the note and labels were taken
# from the card read: 11 per card.)
per_card_calls() { echo $(( $(wc -l < "$FAKE_GH_DIR/calls.log") - $(grep -c $'\tissue list' "$FAKE_GH_DIR/calls.log") )); }
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
# Other columns with no PR still wait
# A done card that still holds pending items warns, naming each title.
# done_case <dir-name> <n> <state> <titles json>: writes a routes file (absolute
# paths, in a temp dir) for one card in <state> holding those pending items
done_case() {
  local d n st t body c
  d="$(mktemp -d)"; CLEANUP_DIRS+=("$d"); n="$2"; st="$3"; t="$4"
  jq -nc --argjson n "$n" --arg st "$st" '{number:$n,title:"Old card",html_url:"u",body:"Done.\n\n## Acceptance\n- it works\n",labels:[{name:("fleet:"+$st)}]}' > "$d/issue.json"
  jq -nc --argjson n "$n" --arg st "$st" '[{number:$n,title:"Old card",url:"u",labels:[{name:("fleet:"+$st)}]}]' > "$d/list.json"
  body="$(printf '<!-- fleet-board:manager-note -->\n### fleet-board manager note\nState: %s\n\n```json\n%s\n```\n' "$st" \
    "$(jq -nc --arg st "$st" --argjson t "$t" '{state:$st,branch:"x",pr:null,round:null,pending_followups:{out_of_scope:$t,bugs:[],pr:null}}')")"
  jq -nc --arg b "$body" '[{id:555,user:{login:"fleet-bot"},body:$b,created_at:"2026-09-28T00:01:00Z"}]' > "$d/comments.json"
  {
    printf 'api user\t0\t%s/labels/user.json\n' "$TICK/.."
    printf 'api repos/acme/toy/issues/%s\t0\t%s/issue.json\n' "$n" "$d"
    printf 'api --paginate repos/acme/toy/issues/%s/comments\t0\t%s/comments.json\n' "$n" "$d"
    for c in ready in_progress in_review blocked; do printf 'issue list --repo acme/toy --label fleet:%s *\t0\t%s/common/empty.json\n' "$c" "$TICK"; done
    printf 'issue list --repo acme/toy --label fleet:%s *\t0\t%s/list.json\n' "$st" "$d"
  } > "$d/routes"
  DONE_CASE_DIR="$d"
}
plan_routes() {
  # like plan, with the routes file at "$1/routes"
  setup_case ready-start
  FAKE_GH_ROUTES="$1/routes"; export FAKE_GH_ROUTES
  run_check "$SCRIPT"
}
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

# update_branch: a PR whose mergeable state is CONFLICTING is brought up to
# date by a merge. Routes are built at run time from an existing scenario plus
# a "pr view <pr> --json mergeable" answer, so no fixture directory is needed.
plan_mergeable() { # <case> <pr> <mergeable>
  setup_case "$1"
  local d="$FAKE_GH_DIR/routes.d"
  mkdir -p "$d"
  printf '{"mergeable":"%s"}\n' "$3" > "$d/mergeable.json"
  {
    printf 'pr view %s --repo acme/toy --json mergeable\t0\t%s\n' "$2" "$d/mergeable.json"
    sed -e "s#	\.\./#	$TICK/#" -e "s#	comments-#	$TICK/$1/comments-#" "$TICK/$1/routes"
  } > "$d/routes"
  FAKE_GH_ROUTES="$d/routes"; export FAKE_GH_ROUTES
  run_check "$SCRIPT"
}

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

# Conflicted files in the note: update-branch.sh recorded them after aborting a
# conflicting merge, so the card plans the fixer with those files as findings.
# plan_note builds the card's comments at run time from an existing in-review
# scenario and the given note JSON, so no fixture directory is needed.
plan_note() { # <note-json> [mergeable]
  setup_case action-failures-in-review-3
  local d="$FAKE_GH_DIR/routes.d"
  mkdir -p "$d"
  jq -cn --arg note "$1" '[{id: 555, user: {login: "fleet-bot"},
    body: ("<!-- fleet-board:manager-note -->\n### fleet-board manager note\nState: x\n\n```json\n" + $note + "\n```\n"),
    created_at: "2026-09-28T00:01:00Z"}]' > "$d/comments.json"
  {
    if [ -n "${2:-}" ]; then
      printf '{"mergeable":"%s"}\n' "$2" > "$d/mergeable.json"
      printf 'pr view 34 --repo acme/toy --json mergeable\t0\t%s\n' "$d/mergeable.json"
    fi
    sed -e "s#	\.\./#	$TICK/#" -e "s#	comments-12.json#	$d/comments.json#" "$TICK/action-failures-in-review-3/routes"
  } > "$d/routes"
  FAKE_GH_ROUTES="$d/routes"; export FAKE_GH_ROUTES
  run_check "$SCRIPT"
}
CONFLICT_NOTE='{"state":"in_review","branch":"fleet/12-add-subtract","pr":34,"round":1,"last_review":{"round":1,"sha":"abc1234","critical":0,"important":0,"findings":[]},"action_failures":1,"last_action_error":"merge conflicts","conflicted_files":["src/calc.js","src/util.js","test/calc.test.js"]}'

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
# settle mode: tick-plan.sh --settle-merge <n>... (merge-reviewed.sh's planner) plans only the steps that
# start no agent, plus merge and verify_main. The by-hand --settle flag went with the by-hand settle script (0.27.0).
# settle <case> <n> [extra YAML]: set up the case and run --settle-merge <n>
settle() { local c="$1" n="$2"; shift 2; setup_case "$c" "$@"; run_check "$SCRIPT" --settle-merge "$n"; }
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

# every other table action is skipped, with a reason naming the action
settle_skips() { # <case> <card> <table action> [extra YAML]
  settle "$1" "$2" "${4:-}"
  assert_jq "settle: table action $3 plans skip ($1)" "$(card "$2" action)" '"skip"'
  assert_jq "settle: skip reason names $3 ($1)" "$(card "$2" reason)" "$(jq -cn --arg a "$3" '"\($a) waits for the next tick"')"
  assert_jq "settle: dispatchable false for $3 ($1)" '.dispatchable' 'false'
}
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

# Merge only reviewed heads: a clean review whose head moved past last_review.
# plan_real <kind>: builds real commits in the case repo (the plan checks them
# with git merge-tree) and routes the fake gh to them. kind is conflict (a
# merge of main whose conflict a person resolved), clean (a merge of main with
# no conflict) or nonmerge (an ordinary commit).
plan_real() {
  local kind="$1" b0 r m h dir main_msg mrg="${2:-}" qa="${3:-}" issue=in_review inrev=list-in_review-12.json files=files-plain.json
  [ -z "$mrg" ] || { issue=merging; inrev=empty.json; }
  [ -z "$qa" ] || files=files-components.json
  setup_case drift-clean "$(printf 'merge:\n  policy: auto')"
  dir="$FAKE_GH_DIR/real"; mkdir -p "$dir"
  printf 'base\n' > "$REPO/f.txt"; git -C "$REPO" add f.txt; git -C "$REPO" commit -q -m "add f"
  b0="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q -b feat
  printf 'feature\n' > "$REPO/f.txt"; git -C "$REPO" commit -q -am "feature change"
  r="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q -b mainline "$b0"
  if [ "$kind" = conflict ]; then printf 'mainline\n' > "$REPO/f.txt"; else printf 'other\n' > "$REPO/g.txt"; git -C "$REPO" add g.txt; fi
  git -C "$REPO" commit -q -am "change on main"
  m="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q feat
  case "$kind" in
    clean) git -C "$REPO" merge -q --no-edit -m "Merge branch 'main' into feat" mainline ;;
    conflict)
      git -C "$REPO" merge -q --no-edit mainline >/dev/null 2>&1
      printf 'resolved by hand\n' > "$REPO/f.txt"; git -C "$REPO" add f.txt
      git -C "$REPO" commit -q -m "Merge branch 'main' into feat" ;;
    nonmerge) printf 'more\n' > "$REPO/h.txt"; git -C "$REPO" add h.txt; git -C "$REPO" commit -q -m "more work" ;;
  esac
  h="$(git -C "$REPO" rev-parse HEAD)"
  if [ "$kind" = nonmerge ]; then
    jq -n --arg h "$h" --arg r "$r" '{commits: [{sha: $h, parents: [{sha: $r}], commit: {message: "more work"}}]}' > "$dir/compare.json"
  else
    jq -n --arg h "$h" --arg r "$r" --arg m "$m" --arg b "$b0" \
      '{commits: [{sha: $m, parents: [{sha: $b}], commit: {message: "change on main"}},
                  {sha: $h, parents: [{sha: $r}, {sha: $m}], commit: {message: "Merge branch '"'"'main'"'"' into feat"}}]}' > "$dir/compare.json"
  fi
  printf '{"files":[{"filename":"src/calc.js"}]}\n' > "$dir/commit.json"
  jq -n --arg h "$h" '{isDraft: false, state: "OPEN", mergedAt: null, headRefOid: $h,
    statusCheckRollup: [{__typename: "CheckRun", conclusion: "SUCCESS"}]}' > "$dir/pr.json"
  sed -e "s/abc1234/$r/g" -e 's/\\"important\\":1/\\"important\\":0/' "$TICK/drift-merge/comments-12.json" > "$dir/comments.json"
  if [ -n "$mrg" ]; then sed -i.bak 's/\\"state\\":\\"in_review\\"/\\"state\\":\\"merging\\"/' "$dir/comments.json"; fi
  {
    printf 'api user\t0\t%s/labels/user.json\n' "$TICK/.."
    printf 'api repos/acme/toy/issues/12\t0\t%s/common/issue-12-%s.json\n' "$TICK" "$issue"
    printf 'api --paginate repos/acme/toy/issues/12/comments\t0\t%s/comments.json\n' "$dir"
    printf 'pr view 34 --repo acme/toy --json isDraft,state,mergedAt,statusCheckRollup,headRefOid\t0\t%s/pr.json\n' "$dir"
    printf 'pr view 34 --repo acme/toy --json files*\t0\t%s/common/%s\n' "$TICK" "$files"
    printf 'issue list --repo acme/toy --label fleet:ready *\t0\t%s/common/empty.json\n' "$TICK"
    printf 'issue list --repo acme/toy --label fleet:in_progress *\t0\t%s/common/empty.json\n' "$TICK"
    printf 'issue list --repo acme/toy --label fleet:in_review *\t0\t%s/common/%s\n' "$TICK" "$inrev"
    printf 'issue list --repo acme/toy --label fleet:merging *\t0\t%s/common/list-merging-12.json\n' "$TICK"
    printf 'issue list --repo acme/toy --label fleet:blocked *\t0\t%s/common/empty.json\n' "$TICK"
    printf 'api repos/acme/toy/compare/%s...%s\t0\t%s/compare.json\n' "$r" "$h" "$dir"
    printf 'api repos/acme/toy/commits/%s\t0\t%s/commit.json\n' "$h" "$dir"
  } > "$dir/routes"
  FAKE_GH_ROUTES="$dir/routes"; export FAKE_GH_ROUTES
  run_check "$SCRIPT"
}

plan_real conflict
assert_exit "merge-only-reviewed: conflict-resolving merge: exit" 0
assert_jq "merge-only-reviewed: conflict-resolving merge of main after last_review plans review" "$(card 12 action)" '"review"'

plan_real clean
assert_exit "merge-only-reviewed: clean merge: exit" 0
assert_jq "merge-only-reviewed: only a clean merge of main after last_review plans merge" "$(card 12 action)" '"merge"'

plan_real nonmerge
assert_exit "merge-only-reviewed: non-merge commit: exit" 0
assert_jq "merge-only-reviewed: a non-merge commit after last_review does not plan merge" "$(card 12 action | sed 's/^/(/; s/$/ != "merge")/')" 'true'

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

# Scope overlap and one merge per tick. Fixtures are built at run time.
# scope_issue <dir> <n> <label> <scope section text, or NONE>: writes the issue
scope_issue() {
  local dir="$1" n="$2" label="$3" scope="$4" body
  body="Work."$'\n\n'
  if [ "$scope" != NONE ]; then body="$body## Scope"$'\n'"$scope"$'\n\n'; fi
  body="$body## Acceptance"$'\n'"- it works"$'\n'
  jq -n --argjson n "$n" --arg l "fleet:$label" --arg b "$body" \
    '{number: $n, title: "Card \($n)", html_url: "https://github.com/acme/toy/issues/\($n)", body: $b, labels: [{name: $l}]}' \
    > "$dir/issue-$n.json"
}

# scope_routes <dir> <ready numbers> <in_review numbers> [<stage columns>]:
# routes for those cards. <stage columns> is "review_<name>:<numbers> ...",
# one word per configured stage (cards in a stage column get PR routes too).
scope_routes() {
  local dir="$1" n pr stage_nums="" sc
  for sc in ${4:-}; do stage_nums="$stage_nums ${sc#*:}"; done
  {
    printf 'api user\t0\t%s/labels/user.json\n' "$TICK/.."
    for n in $2 $3 $stage_nums; do
      printf 'api repos/acme/toy/issues/%s\t0\t%s/issue-%s.json\n' "$n" "$dir" "$n"
      if [ -f "$dir/comments-$n.json" ]; then
        printf 'api --paginate repos/acme/toy/issues/%s/comments\t0\t%s/comments-%s.json\n' "$n" "$dir" "$n"
      else
        printf 'api --paginate repos/acme/toy/issues/%s/comments\t0\t%s/common/empty.json\n' "$n" "$TICK"
      fi
    done
    for n in $3 $stage_nums; do
      pr=$((n + 22))
      printf 'pr view %s --repo acme/toy --json isDraft,state,mergedAt,statusCheckRollup,headRefOid\t0\t%s/common/pr-34-open-green.json\n' "$pr" "$TICK"
      printf 'pr view %s --repo acme/toy --json files*\t0\t%s/common/files-plain.json\n' "$pr" "$TICK"
    done
    for st in ready:"$2" in_progress: in_review:"$3" ${4:-} blocked:; do
      local col="${st%%:*}" nums="${st#*:}" arr="[]" x
      arr="$(for x in $nums; do jq -cn --argjson n "$x" --arg l "fleet:$col" '{number: $n, title: "Card \($n)", url: "u", labels: [{name: $l}]}'; done | jq -cs '.')"
      printf '%s\n' "$arr" > "$dir/list-$col.json"
      printf 'issue list --repo acme/toy --label fleet:%s *\t0\t%s/list-%s.json\n' "$col" "$dir" "$col"
    done
  } > "$dir/routes"
  FAKE_GH_ROUTES="$dir/routes"; export FAKE_GH_ROUTES
}

# scope_review_note <dir> <n>: a clean round 1 review note for card n, PR n+22
scope_review_note() {
  sed -e "s/fleet\\/12-add-subtract/fleet\\/$2-card/" -e "s/\\\\\"pr\\\\\":34/\\\\\"pr\\\\\":$(($2 + 22))/" \
    "$TICK/in-review-merge-auto/comments-12.json" > "$1/comments-$2.json"
}

# plan_scope <ready card's scope text or NONE>: ready card 14, in_review card 12 naming src/a.sh
plan_scope() {
  setup_case ready-start
  local dir="$FAKE_GH_DIR/scope"; mkdir -p "$dir"
  scope_issue "$dir" 12 in_review '- Modify `src/a.sh`: the change'
  scope_issue "$dir" 14 ready "$1"
  scope_review_note "$dir" 12
  scope_routes "$dir" "14" "12"
  run_check "$SCRIPT"
}

plan_scope '- Modify `src/a.sh`: another change'
assert_exit "scope-overlap: exit" 0
assert_jq "scope-overlap: a Ready card sharing a path with an in_review card waits" "$(card 14 action)" '"wait"'
assert_jq "scope-overlap: the reason names the other card" "$(card 14 reason | sed 's/^/(/; s/$/ | contains("#12"))/')" 'true'

plan_scope '- Modify `src/b.sh`: another change'
assert_exit "scope-disjoint: exit" 0
assert_jq "scope-disjoint: cards naming different paths start" "$(card 14 action)" '"start"'

plan_scope 'Everything in the card, no file named here.'
assert_exit "scope-none: exit" 0
assert_jq "scope-none: a Ready card whose Scope names no paths starts" "$(card 14 action)" '"start"'

# Three cards eligible to merge: exactly one merge, lowest number first
setup_case in-review-merge-auto "$(printf 'merge:\n  policy: auto')"
dir="$FAKE_GH_DIR/scope"; mkdir -p "$dir"
for n in 12 13 15; do
  scope_issue "$dir" "$n" in_review NONE
  scope_review_note "$dir" "$n"
done
scope_routes "$dir" "" "15 12 13"
run_check "$SCRIPT"
assert_exit "merge-one: exit" 0
assert_jq "merge-one: exactly one of three eligible cards is merge" '[.cards[] | select(.action == "merge")] | length' 1
assert_jq "merge-one: the merge is the lowest card number" '[.cards[] | select(.action == "merge") | .number]' '[12]'
assert_jq "merge-one: the others wait" '[.cards[] | select(.action == "wait") | .number] | sort' '[13,15]'

# commands.preflight: one board-level alert instead of a failure on each card
PRE_DIR="$(mktemp -d)"; CLEANUP_DIRS+=("$PRE_DIR")
printf '#!/usr/bin/env bash\necho ran >> "%s/ran"\nfor i in $(seq 1 25); do echo "preflight line $i"; done\nexit 1\n' "$PRE_DIR" > "$PRE_DIR/fail.sh"
printf '#!/usr/bin/env bash\necho ran >> "%s/ran"\necho fine\nexit 0\n' "$PRE_DIR" > "$PRE_DIR/ok.sh"

# mutating_calls: gh calls that edit, comment or write (a plan only reads)
mutating_calls() {
  local f n=0
  for f in "$FAKE_GH_DIR"/argv/*; do
    [ -f "$f" ] || continue
    grep -qxE 'edit|comment|create|close|-X|--method|--input' "$f" && n=$((n + 1))
  done
  echo "$n"
}

for pcase in ready-start in-review-needs-review action-failures-ready-3; do
  plan "$pcase"
  UNSET_OUT="$LAST_OUT"
  rm -f "$PRE_DIR/ran"
  plan "$pcase" "$(printf 'commands:\n  preflight: bash %s/fail.sh' "$PRE_DIR")"
  assert_exit "preflight-fail $pcase: exit" 0
  assert_jq "preflight-fail $pcase: no start, review, fix or other dispatch action" \
    '[.cards[] | select(.action | IN("start","continue_implementor","start_review","review","fix","merge","block","unblock","file_pending","verify_main","finish","update_branch","mark_ready","to_human_qa"))] | length' 0
  assert_jq "preflight-fail $pcase: exactly one warning starts with 'preflight failed:'" \
    '[.warnings[] | select(startswith("preflight failed:"))] | length' 1
  assert_jq "preflight-fail $pcase: the warning holds the command" \
    '[.warnings[] | select(startswith("preflight failed:") and contains("fail.sh"))] | length' 1
  assert_jq "preflight-fail $pcase: the warning holds the last 20 lines of output" \
    '.warnings[] | select(startswith("preflight failed:")) | [contains("preflight line 25"), contains("preflight line 6"), contains("preflight line 5")]' '[true,true,false]'
  assert_jq "preflight-fail $pcase: dispatchable is false" '.dispatchable' 'false'
  assert_eq "preflight-fail $pcase: every card keeps its state" \
    "$(jq -c '[.cards[] | [.number, .state, .round]]' <<<"$LAST_OUT")" \
    "$(jq -c '[.cards[] | [.number, .state, .round]]' <<<"$UNSET_OUT")"
  assert_eq "preflight-fail $pcase: nothing is written to the board" "$(mutating_calls)" "0"
  assert_eq "preflight-fail $pcase: the preflight ran once" "$(wc -l < "$PRE_DIR/ran" | tr -d ' ')" "1"
done

# exit 0: the plan equals the plan with the key unset
for pcase in ready-start in-review-needs-review; do
  plan "$pcase"
  UNSET_OUT="${LAST_OUT//$BASE/BASE}" # the worktree base differs per run
  rm -f "$PRE_DIR/ran"
  plan "$pcase" "$(printf 'commands:\n  preflight: bash %s/ok.sh' "$PRE_DIR")"
  assert_exit "preflight-ok $pcase: exit" 0
  assert_eq "preflight-ok $pcase: plan equals the plan with the key unset" "${LAST_OUT//$BASE/BASE}" "$UNSET_OUT"
  assert_eq "preflight-ok $pcase: the preflight ran once" "$(wc -l < "$PRE_DIR/ran" | tr -d ' ')" "1"
done

# key unset: no preflight command runs (another commands key must not be run)
rm -f "$PRE_DIR/ran"
plan ready-start "$(printf 'commands:\n  test_one: bash %s/ok.sh {file}' "$PRE_DIR")"
assert_exit "preflight-unset: exit" 0
assert_eq "preflight-unset: no command ran" "$([ -e "$PRE_DIR/ran" ] && echo ran || echo none)" "none"
assert_jq "preflight-unset: no preflight warning" '[.warnings[] | select(startswith("preflight"))] | length' 0

# the docs name the key
grep -qF 'commands.preflight' "$SCRIPT_DIR/../docs/config.md" \
  && pass "preflight-docs: docs/config.md names commands.preflight" \
  || fail "preflight-docs: docs/config.md names commands.preflight" "grep -F found nothing"

# ---------------------------------------------------------------------------
# Re-review instead of fixing again (not_reproducible, and a card returned
# from Blocked). Variants of in-review-fix with a different note, built at run
# time under a temp tree that links the shared fixtures.
VROOT="$(mktemp -d)"
CLEANUP_DIRS+=("$VROOT")
mkdir -p "$VROOT/tick"
ln -s "$TICK/common" "$VROOT/tick/common"
ln -s "$SCRIPT_DIR/../fixtures/gh/labels" "$VROOT/labels"

# variant <name> <pr json file under common> <note json>
variant() {
  local d="$VROOT/tick/$1"
  mkdir -p "$d"
  sed "s#comments-12.json#$d/comments-12.json#; s#\.\./common/pr-34-draft.json#../common/$2#" "$TICK/in-review-fix/routes" > "$d/routes"
  jq -c --argjson note "$3" '
    .[1].body = ("<!-- fleet-board:manager-note -->\n### fleet-board manager note\n\n```json\n" + ($note | tojson) + "\n```\n")
  ' "$TICK/in-review-fix/comments-12.json" > "$d/comments-12.json"
  TICK="$VROOT/tick" plan "$1"
}
LR='"last_review":{"round":1,"sha":"abc1234","critical":0,"important":1,"findings":[{"severity":"Important","text":"subtract ignores negatives"}]}'
BASE_NOTE='"branch":"fleet/12-add-subtract","pr":34,"round":1'

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

# ---------------------------------------------------------------------------
# Review stages: stage columns, advance_stage and review_stage. The config has
# the three stages of fixtures/config/stages.yml (security with max_rounds 2).
STAGES_YAML="$(printf '%s\n' \
  'review:' \
  '  stages:' \
  '    - name: security' \
  '      agent: "acme:sec"' \
  '      model: opus' \
  '      paths: ["src/auth/**"]' \
  '      max_rounds: 2' \
  '    - name: ux' \
  '      agent: ux-reviewer' \
  '      model: sonnet' \
  '      advisory: true' \
  '    - name: compliance' \
  '      provider: openai' \
  '      model: gpt-test' \
  '      price: { input: 1, output: 2 }')"  # an old price key: config.sh ignores it
unset OPENAI_API_KEY || true
splan() { plan "$1" "$STAGES_YAML"; }
ssettle() { settle "$1" "$2" "$STAGES_YAML"; }

# in_review, clean current review, label needs-security-review -> advance_stage
splan stage-advance-from-review
assert_exit "stage-advance: exit" 0
assert_jq "stage-advance: action" "$(card 12 action)" '"advance_stage"'
assert_jq "stage-advance: reason" "$(card 12 reason)" '"review clean; next stage security"'
assert_jq "stage-advance: entering security" "$(card 12 stage.name)" '"security"'
assert_jq "stage-advance: agent carried" "$(card 12 stage.agent)" '"acme:sec"'
assert_eq "stage-advance: one files lookup (match; no needs-human-qa)" "$(call_count pr view 34 --repo acme/toy --json files,changedFiles)" 1
assert_jq "stage-advance: dispatchable" '.dispatchable' 'true'
# in review_security, note stage security round 1, no last_review -> review_stage
splan stage-review-needed
assert_exit "stage-review: exit" 0
assert_jq "stage-review: action" "$(card 12 action)" '"review_stage"'
assert_jq "stage-review: reason" "$(card 12 reason)" '"round 1 of security not reviewed yet"'
assert_jq "stage-review: model" "$(card 12 stage.model)" '"opus"'
assert_jq "stage-review: dispatchable" '.dispatchable' 'true'
# agent_stage_plan_card_has_null_provider
assert_jq "agent_stage_plan_card_has_null_provider: provider" "$(card 12 stage.provider)" 'null'
assert_jq "agent_stage_plan_card_has_null_provider: agent" "$(card 12 stage.agent)" '"acme:sec"'
assert_jq "stage-review: stage object is the config stage whole" "$(card 12 stage) | keys" \
  '["advisory","agent","brief","label","max_diff_bytes","max_output_tokens","max_rounds","model","name","paths","provider","timeout"]'
# no_warning_when_stage_not_acted_on: no card in the provider stage
assert_jq "no_warning_when_stage_not_acted_on: no card in the stage" '.warnings' '[]'
# last_review from in_review (stage null, round 1) does not count
splan stage-stale-record
assert_jq "stage-stale: action" "$(card 12 action)" '"review_stage"'
assert_jq "stage-stale: reason" "$(card 12 reason)" '"round 1 of security not reviewed yet"'
# findings in round 1 of 2 -> fix with stage
splan stage-fix
assert_jq "stage-fix: action" "$(card 12 action)" '"fix"'
assert_jq "stage-fix: stage present" "$(card 12 stage.name)" '"security"'
# findings in round 2 of 2 -> block at the stage's max
splan stage-block
assert_jq "stage-block: action" "$(card 12 action)" '"block"'
assert_jq "stage-block: reason" "$(card 12 reason)" '"1 Critical/Important findings survive round 2 of 2 in security"'
# advisory stage with findings and no later label -> tail (draft PR -> mark_ready)
splan stage-advisory-tail
assert_jq "stage-advisory: action" "$(card 12 action)" '"mark_ready"'
assert_jq "stage-advisory: stage ux" "$(card 12 stage.name)" '"ux"'
# clean in security, ux label present -> advance to ux
splan stage-advance-next
assert_jq "stage-advance-next: action" "$(card 12 action)" '"advance_stage"'
assert_jq "stage-advance-next: ux" "$(card 12 stage.name)" '"ux"'
assert_jq "stage-advance-next: reason" "$(card 12 reason)" '"review clean; next stage ux"'
# clean in security, ux label present but reviewed_stages has ux -> tail
splan stage-skip-done
assert_jq "stage-skip-done: not revisited" "$(card 12 action)" '"mark_ready"'
# Re-matching: the PR's current files are matched against every stage's paths
# at each clean, current review, so a file added after routing still routes.
# in_review, no routing label, PR files now include src/auth/login.js
splan stage-rematch-in-review
assert_exit "rematch in_review: exit" 0
assert_jq "rematch in_review: advance_stage" "$(card 12 action)" '"advance_stage"'
assert_jq "rematch in_review: into security" "$(card 12 stage.name)" '"security"'
assert_eq "rematch in_review: adds no label" "$(grep -c $'\tissue edit' "$FAKE_GH_DIR/calls.log")" 0
# review_ux, clean, security never visited and now matched -> back to security
splan stage-rematch-earlier
assert_jq "rematch earlier stage: advance_stage" "$(card 12 action)" '"advance_stage"'
assert_jq "rematch earlier stage: into security" "$(card 12 stage.name)" '"security"'
assert_jq "rematch earlier stage: reason" "$(card 12 reason)" '"review clean; next stage security"'
# review_ux, clean, security already in reviewed_stages -> not revisited
splan stage-rematch-done
assert_jq "rematch done stage: not revisited" "$(card 12 action)" '"mark_ready"'
# head moved after a clean stage review -> review_stage
splan stage-head-moved
assert_jq "stage-head-moved: action" "$(card 12 action)" '"review_stage"'
# a card labelled fleet:review_legacy with no such stage in the config: settle plan by number
ssettle stage-not-configured 12
assert_exit "stage-missing: exit 0" 0
assert_jq "stage-missing: action skip" "$(card 12 action)" '"skip"'
assert_jq "stage-missing: not dispatchable" '.dispatchable' 'false'
# settle keeps advance_stage, drops review_stage
ssettle stage-advance-from-review 12
assert_jq "settle: advance_stage kept" "$(card 12 action)" '"advance_stage"'
ssettle stage-review-needed 12
assert_jq "settle: review_stage skipped" "$(card 12 action)" '"skip"'
assert_jq "settle: review_stage waits" "$(card 12 reason)" '"review_stage waits for the next tick"'
# action_failures rule covers a stage column (note action_failures 3, review.max_rounds 3)
splan stage-action-failures-3
assert_jq "stage failures: block" "$(card 12 action)" '"block"'
assert_jq "stage failures: reason" "$(card 12 reason)" '"no progress after 3 attempts: fleet-board: cannot fetch the head of PR #34"'

# Provider stages
COMPLIANCE_WARN='stage compliance: OPENAI_API_KEY is not set; provider reviews will fail'
# review_stage_plan_card_has_provider
splan stage-provider-review
assert_exit "review_stage_plan_card_has_provider: exit" 0
assert_jq "review_stage_plan_card_has_provider: provider" "$(card 12 stage.provider)" '"openai"'
assert_jq "review_stage_plan_card_has_provider: agent null" "$(card 12 stage.agent)" 'null'
assert_jq "review_stage_plan_card_has_provider: model" "$(card 12 stage.model)" '"gpt-test"'
assert_jq "review_stage_plan_card_has_provider: key unset holds as wait" "$(card 12 action)" '"wait"'
assert_jq "review_stage_plan_card_has_provider: hold reason" "$(card 12 reason)" '"stage compliance: OPENAI_API_KEY is not set"'
assert_jq "review_stage_plan_card_has_provider: nothing else dispatchable" '.dispatchable' 'false'
assert_jq "review_stage_plan_card_has_provider: key unset warns" '.warnings' "$(warns_json "$COMPLIANCE_WARN")"
# unset_key_warns_once: card 12 review_stage and card 13 fix, both in review_compliance
splan stage-provider-two
assert_jq "unset_key_warns_once: card 12 review_stage held" "$(card 12 action)" '"wait"'
assert_jq "unset_key_warns_once: card 12 hold reason" "$(card 12 reason)" '"stage compliance: OPENAI_API_KEY is not set"'
assert_jq "unset_key_warns_once: dispatchable through the fix" '.dispatchable' 'true'
assert_jq "unset_key_warns_once: card 13 fix" "$(card 13 action)" '"fix"'
assert_jq "unset_key_warns_once: one warning" '.warnings' "$(warns_json "$COMPLIANCE_WARN")"
# set_key_no_warning
setup_case stage-provider-two "$STAGES_YAML"
OPENAI_API_KEY=x; export OPENAI_API_KEY
run_check "$SCRIPT"
unset OPENAI_API_KEY
assert_jq "set_key_no_warning: review_stage planned" "$(card 12 action)" '"review_stage"'
assert_jq "set_key_no_warning: actions unchanged" '[.cards[].action]' '["review_stage","fix"]'
assert_jq "set_key_no_warning: no warning" '.warnings' '[]'
# an empty variable counts as unset
setup_case stage-provider-two "$STAGES_YAML"
OPENAI_API_KEY=; export OPENAI_API_KEY
run_check "$SCRIPT"
unset OPENAI_API_KEY
assert_jq "empty key warns" '.warnings' "$(warns_json "$COMPLIANCE_WARN")"
# no_warning_when_stage_not_acted_on: a clean provider review plans the tail
splan stage-provider-clean
assert_jq "no_warning_when_stage_not_acted_on: action" "$(card 12 action)" '"mark_ready"'
assert_jq "no_warning_when_stage_not_acted_on: no warning" '.warnings' '[]'
# settle: review_stage is skipped there, so no warning
ssettle stage-provider-review 12
assert_jq "no_warning_when_stage_not_acted_on: settle skip" '.warnings' '[]'
# advance_into_provider_stage_warns: the manager runs review_stage right after
# advance_stage, so entering a provider stage with its key unset warns once
splan stage-advance-to-provider
assert_exit "advance_into_provider_stage_warns: exit" 0
assert_jq "advance_into_provider_stage_warns: action" "$(card 12 action)" '"advance_stage"'
assert_jq "advance_into_provider_stage_warns: stage" "$(card 12 stage.name)" '"compliance"'
assert_jq "advance_into_provider_stage_warns: one warning" '.warnings' "$(warns_json "$COMPLIANCE_WARN")"
setup_case stage-advance-to-provider "$STAGES_YAML"
OPENAI_API_KEY=x; export OPENAI_API_KEY
run_check "$SCRIPT"
unset OPENAI_API_KEY
assert_jq "advance_into_provider_stage_warns: key set, no warning" '.warnings' '[]'
# a failed preflight holds a stage action too (advance_stage into a provider stage)
rm -f "$PRE_DIR/ran"
plan stage-advance-to-provider "$STAGES_YAML
$(printf 'commands:\n  preflight: bash %s/fail.sh' "$PRE_DIR")"
assert_jq "preflight-fail stage-advance-to-provider: held as wait" "$(card 12 action)" '"wait"'
assert_jq "preflight-fail stage-advance-to-provider: dispatchable is false" '.dispatchable' 'false'
assert_jq "preflight-fail stage-advance-to-provider: one preflight warning" '[.warnings[] | select(startswith("preflight failed:"))] | length' 1
# advance into an agent stage never warns
splan stage-advance-from-review
assert_jq "advance into an agent stage: no warning" '.warnings' '[]'

# scope overlap covers stage columns: a Ready card whose Scope names a path a
# card in review_security names waits, as it does for an in_review card
setup_case ready-start "$STAGES_YAML"
dir="$FAKE_GH_DIR/scope"; mkdir -p "$dir"
scope_issue "$dir" 12 review_security '- Modify `src/a.sh`: the change'
scope_issue "$dir" 14 ready '- Modify `src/a.sh`: another change'
scope_review_note "$dir" 12
scope_routes "$dir" "14" "" "review_security:12 review_ux: review_compliance:"
run_check "$SCRIPT"
assert_exit "scope-overlap stage column: exit" 0
assert_jq "scope-overlap stage column: the review_security card is planned" "$(card 12 action) != null" 'true'
assert_jq "scope-overlap stage column: the Ready card waits" "$(card 14 action)" '"wait"'
assert_jq "scope-overlap stage column: the reason names the stage card" "$(card 14 reason)" '"Scope overlaps #12 on src/a.sh"'

# no_stages_no_next_lookup: with no review stages configured, a clean, current
# in_review card never runs review-stages.sh next and plans the old tail. A
# copy of the scripts dir whose review-stages.sh records its call and fails
# stands in for it.
NEXT_STUB="$(mktemp -d)"
CLEANUP_DIRS+=("$NEXT_STUB")
cp -R "$SCRIPT_DIR/../scripts/." "$NEXT_STUB/"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/next-calls"\nexit 1\n' "$NEXT_STUB" > "$NEXT_STUB/review-stages.sh"
setup_case in-review-mark-ready-human
run_check "$NEXT_STUB/tick-plan.sh"
assert_exit "no_stages_no_next_lookup: exit" 0
assert_jq "no_stages_no_next_lookup: old tail" "$(card 12 action)" '"mark_ready"'
assert_eq "no_stages_no_next_lookup: review-stages.sh (match or next) not run" "$([ -e "$NEXT_STUB/next-calls" ] && echo called || echo none)" none
# control: with stages configured the same stub is run (and its failure skips the card)
setup_case stage-advance-from-review "$STAGES_YAML"
run_check "$NEXT_STUB/tick-plan.sh"
assert_jq "no_stages_no_next_lookup control: lookup failed (match runs first)" "$(card 12 reason)" '"lookup failed: review-stages.sh match 34"'
assert_eq "no_stages_no_match_lookup: the stub ran match first" "$(sed -n 1p "$NEXT_STUB/next-calls")" "match 34"
assert_eq "no_stages_no_next_lookup control: stub ran" "$([ -e "$NEXT_STUB/next-calls" ] && echo called || echo none)" called

provider_models='models:
  reviewer: { provider: codex, model: gpt-6-astra, price: { input: 0, output: 0 } }
  escalation: opus'
plan escalation-round2 "$provider_models"
assert_exit "provider reviewer: planner exits 0" 0
assert_jq "provider reviewer: passes merged object through" "$(card 12 models.reviewer)" '{"provider":"codex","model":"gpt-6-astra","timeout":1500}'
assert_jq "provider reviewer: escalation applies to both writers" "$(card 12 models) | [.implementor,.fixer]" '["opus","opus"]'
assert_jq "provider reviewer: no price warning (tokens only)" '.warnings' '[]'
plan escalation-round2 "$provider_models
  implementor: gpt-6-astra"
assert_jq "provider reviewer: shared implementor model warns" '[.warnings[] | select(startswith("implementor and reviewer share model gpt-6-astra"))] | length' 1
plan escalation-round2 "${provider_models/escalation: opus/escalation: gpt-6-astra}"
assert_jq "provider reviewer: shared escalation model warns" '[.warnings[] | select(startswith("escalation and reviewer share model gpt-6-astra"))] | length' 1

# Candidate mode exposes the same workflow decision without tick-local admission.
candidate_empty_human_qa_route() {
  local route_dir
  route_dir="$(mktemp -d)"
  CLEANUP_DIRS+=("$route_dir")
  local route_base
  route_base="$(cd "$(dirname "$FAKE_GH_ROUTES")" && pwd)"
  awk -F '\t' -v OFS='\t' -v base="$route_base" \
    '$3 != "-" && substr($3, 1, 1) != "/" { $3 = base "/" $3 } { print }' \
    "$FAKE_GH_ROUTES" > "$route_dir/routes"
  FAKE_GH_ROUTES="$route_dir/routes"
  export FAKE_GH_ROUTES
  printf 'issue list --repo acme/toy --label fleet:human_qa *\t0\t%s/common/empty.json\n' "$TICK" >> "$FAKE_GH_ROUTES"
}
setup_case ready-start
candidate_empty_human_qa_route
run_check "$SCRIPT" --candidates
assert_exit "candidate mode: exit" 0
assert_jq "candidate mode: schema version" '.schema_version' '2'
assert_jq "candidate mode: action parity" '.candidates[0].action' '"start"'
assert_jq "candidate mode: preconditions and scope contract" '(.candidates[0] | [has("preconditions"), has("declared_paths"), has("actual_paths"), has("scope_complete"), has("dependencies"), has("stage"), has("head_sha"), has("round"), has("priority"), has("state_revision")])' '[true,true,true,true,true,true,true,true,true,true]'
assert_jq "candidate mode: declared paths" '.candidates[0].declared_paths' '[]'
assert_jq "candidate mode: empty actual paths are complete" '(.candidates[0] | [.actual_paths, .scope_complete])' '[[],true]'

# A malformed labels payload from the board-read contract must not silently clear priority metadata.
setup_case ready-start
candidate_empty_human_qa_route
MALFORMED_STUB="$(mktemp -d)"
CLEANUP_DIRS+=("$MALFORMED_STUB")
cp -R "$SCRIPT_DIR/../scripts/." "$MALFORMED_STUB/"
cat > "$MALFORMED_STUB/board-read.sh" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"number":12,"title":"Add subtract","state":"ready","body":"Subtract two numbers.\n\n## Acceptance\n- subtract(2,5) returns -3\n","labels":"malformed","manager_note":null,"comments":[]}
JSON
EOF
chmod +x "$MALFORMED_STUB/board-read.sh"
run_check "$MALFORMED_STUB/tick-plan.sh" --candidates
assert_exit "candidate mode: malformed labels keep planner read successful" 0
assert_jq "candidate mode: malformed labels fail closed" '.candidates[0].action' '"skip"'
assert_jq "candidate mode: malformed labels report attention" '.candidates[0].reason' '"lookup failed: board-read.sh 12 (malformed labels)"'
assert_jq "candidate mode: malformed labels do not start work" '[.candidates[] | select(.action == "start")] | length' '0'

# Candidate rows carry the dispatch fields the full plan row has.
setup_case in-review-fix
candidate_empty_human_qa_route
run_check "$SCRIPT" --candidates
assert_exit "candidates_carry_dispatch_fields: exit" 0
assert_jq "candidates_carry_dispatch_fields: schema version" '.schema_version' '2'
assert_jq "candidates_carry_dispatch_fields: branch" '.candidates[0].branch' '"fleet/12-add-subtract"'
assert_jq "candidates_carry_dispatch_fields: pr" '.candidates[0].pr' '34'
assert_jq "candidates_carry_dispatch_fields: fixer model" '.candidates[0].models.fixer' '"sonnet"'
assert_jq "candidates_carry_dispatch_fields: every field present" '(.candidates[0] | [has("title"),has("state"),has("branch"),has("worktree"),has("pr"),has("models"),has("escalated"),has("findings"),has("waiting_on"),has("needs_human_qa"),has("comment_needed"),has("lint"),has("lint_marker")] | all)' 'true'

plan_note "$CONFLICT_NOTE"
candidate_empty_human_qa_route
run_check "$SCRIPT" --candidates
assert_exit "candidates_carry_conflict_findings: exit" 0
assert_jq "candidates_carry_conflict_findings: first finding" '.candidates[0].findings[0].text' '"merge conflict in src/calc.js"'

run_check "$SCRIPT" --unknown-mode
assert_exit "candidate mode: invalid mode rejected" 2
run_check "$SCRIPT" --candidates --settle-merge 12
assert_exit "candidate mode: cannot combine with settle" 2

# merge.ignore_checks: a red check whose name matches an unexpired entry counts as green
IGN_YAML() { # IGN_YAML <until-lint> <until-legacy>
  printf 'merge:\n  policy: auto\n  ignore_checks:\n    - name: "lint-*"\n      reason: "docs lint is flaky"\n      until: %s\n    - name: "ci/legacy-?int"\n      reason: "legacy status"\n      until: %s\n' "$1" "$2"
}
export FLEET_BOARD_TODAY=2026-11-11
for row in in-review merging; do
  plan $row-ignore-red "$(IGN_YAML 2026-12-31 2026-11-11)"
  assert_jq "$row-ignore: unexpired entries (through today) plan merge" "$(card 12 action)" '"merge"'
  assert_jq "$row-ignore: the planner lists the checks it ignored" "$(card 12 ignored_checks)" \
    '[{"name":"lint-docs","reason":"docs lint is flaky","until":"2026-12-31","state":"red"},{"name":"ci/legacy-lint","reason":"legacy status","until":"2026-11-11","state":"red"}]'
  assert_jq "$row-ignore: no expiry warning" '.warnings' '[]'
  plan $row-ignore-red "$(IGN_YAML 2026-12-31 2026-11-10)"
  assert_jq "$row-ignore-expired: an expired entry no longer counts" "$(card 12 action)" "$([ $row = merging ] && echo '"skip"' || echo '"wait"')"
  assert_jq "$row-ignore-expired: warning names the entry and its date" '.warnings' '["merge.ignore_checks entry ci/legacy-?int expired 2026-11-10"]'
  plan $row-ignore-pending "$(IGN_YAML 2026-12-31 2026-12-31)"
  assert_jq "$row-ignore-pending: a pending check never counts as green" "$(card 12 action)" "$([ $row = merging ] && echo '"skip"' || echo '"wait"')"
  plan $row-ignore-other-red "$(IGN_YAML 2026-12-31 2026-12-31)"
  assert_jq "$row-ignore-other-red: a red check no entry matches still blocks" "$(card 12 action)" "$([ $row = merging ] && echo '"skip"' || echo '"wait"')"
done
# pending: true lets a matching check that is still running count as green
IGN_PENDING_YAML() { # IGN_PENDING_YAML <until>
  printf 'merge:\n  policy: auto\n  ignore_checks:\n    - name: "lint-*"\n      reason: "CI is asynchronous"\n      until: %s\n      pending: true\n    - name: "ci/legacy-?int"\n      reason: "legacy status"\n      until: 2026-12-31\n' "$1"
}
export FLEET_BOARD_TODAY=2026-11-11
for row in in-review merging; do
  plan $row-ignore-pending "$(IGN_PENDING_YAML 2026-12-31)"
  assert_jq "$row-ignore-pending: a pending check an entry with pending: true names counts as green" "$(card 12 action)" '"merge"'
  assert_jq "$row-ignore-pending: the planner lists the pending check it went past" "$(card 12 ignored_checks)" \
    '[{"name":"lint-docs","reason":"CI is asynchronous","until":"2026-12-31","state":"pending"},{"name":"ci/legacy-lint","reason":"legacy status","until":"2026-12-31","state":"red"}]'
  plan $row-ignore-pending "$(IGN_PENDING_YAML 2026-11-10)"
  assert_jq "$row-ignore-pending: an expired pending entry no longer counts" "$(card 12 action)" "$([ $row = merging ] && echo '"skip"' || echo '"wait"')"
  plan $row-ignore-other-red "$(IGN_PENDING_YAML 2026-12-31)"
  assert_jq "$row-ignore-pending: pending: true does not cover a red check it does not name" "$(card 12 action)" "$([ $row = merging ] && echo '"skip"' || echo '"wait"')"
  plan $row-ignore-red "$(IGN_PENDING_YAML 2026-12-31)"
  assert_jq "$row-ignore-pending: a pending: true entry also covers a red check of the same name" "$(card 12 action)" '"merge"'
  assert_jq "$row-ignore-pending: that red check is recorded as red" "$(card 12 ignored_checks)" \
    '[{"name":"lint-docs","reason":"CI is asynchronous","until":"2026-12-31","state":"red"},{"name":"ci/legacy-lint","reason":"legacy status","until":"2026-12-31","state":"red"}]'
done
# The check states are explicit sets: passed, red, pending; anything else is never green.
STAR_YAML() { # STAR_YAML [pending]: one "*" entry, with pending: true when asked
  printf 'merge:\n  policy: auto\n  ignore_checks:\n    - name: "*"\n      reason: "CI is asynchronous"\n      until: 2026-12-31\n'
  [ "${1:-}" = pending ] && printf '      pending: true\n'
  return 0
}
plan in-review-ignore-startup "$AUTO"
assert_jq "check-states: STARTUP_FAILURE and STALE are not green without an entry" "$(card 12 action)" '"wait"'
plan in-review-ignore-startup "$(STAR_YAML)"
assert_jq "check-states: a red-only entry covers STARTUP_FAILURE and STALE" "$(card 12 action)" '"merge"'
plan in-review-ignore-startup "$(STAR_YAML pending)"
assert_jq "check-states: under pending: true, STARTUP_FAILURE and STALE merge" "$(card 12 action)" '"merge"'
assert_jq "check-states: under pending: true, STARTUP_FAILURE and STALE are recorded as red" "$(card 12 ignored_checks)" \
  '[{"name":"e2e","reason":"CI is asynchronous","until":"2026-12-31","state":"red"},{"name":"deploy","reason":"CI is asynchronous","until":"2026-12-31","state":"red"}]'
plan in-review-ignore-weird "$(STAR_YAML pending)"
assert_jq "check-states: an unknown conclusion never merges, even under * with pending: true" "$(card 12 action)" '"wait"'
plan in-review-ignore-noconclusion "$(STAR_YAML pending)"
assert_jq "check-states: COMPLETED with a null conclusion never merges, even under * with pending: true" "$(card 12 action)" '"wait"'
plan in-review-ignore-nameless "$(STAR_YAML pending)"
assert_jq "check-states: a red check with no name is never ignored, even under *" "$(card 12 action)" '"wait"'
unset FLEET_BOARD_TODAY
plan in-review-merge-auto "$AUTO"
assert_jq "ignore_checks: an ordinary merge ignores nothing" "$(card 12 ignored_checks)" '[]'
plan in-review-ignore-red "$(IGN_YAML 2026-12-31 2026-12-31)" 
assert_jq "ignore_checks: case-sensitive glob (unchanged config matches)" "$(card 12 action)" '"merge"'
plan in-review-ignore-red "$(printf 'merge:\n  policy: auto\n  ignore_checks:\n    - name: "LINT-*"\n      reason: r\n      until: 2026-12-31\n')"
assert_jq "ignore_checks: glob matching is case-sensitive" "$(card 12 action)" '"wait"'
export FLEET_BOARD_TODAY=2027-01-01
plan in-review-ignore-red "$(IGN_YAML 2026-12-31 2026-12-31)"
assert_jq "ignore_checks: today is injectable (FLEET_BOARD_TODAY)" "$(card 12 action)" '"wait"'
unset FLEET_BOARD_TODAY

# A keyed refusal leaves pending_merge at the same head: the planner must not re-plan merge every cycle
plan merging-refused "$AUTO"
assert_jq "merge_refusal: a refusal at the current head with no merger decision plans merge_refusal" "$(card 12 action)" '"merge_refusal"'
plan merging-refused-attention "$AUTO"
assert_jq "merge_refusal: a merger attention decision plans skip" "$(card 12 action)" '"skip"'
assert_jq "merge_refusal: attention reason" "$(card 12 reason)" '"merger needs attention; a person decides"'
plan merging-refused-after-retry "$AUTO"
assert_jq "merge_refusal: a refusal after a retry decision plans merge_refusal again" "$(card 12 action)" '"merge_refusal"'
# After a retry decision the merge is planned again, carrying the retry time for the supervisor to hold it
setup_case merging-retry "$AUTO"; run_check "$SCRIPT" --candidates
assert_jq "merge retry: the merge is planned again" '[.candidates[] | select(.number == 12) | .action]' '["merge"]'
assert_jq "merge retry: retry_after is carried" '[.candidates[] | select(.number == 12) | .retry_after]' '["2026-11-11T00:05:00Z"]'
setup_case merging-open-no-marker "$AUTO"; run_check "$SCRIPT" --candidates
assert_jq "merge retry: no marker carries retry_after null" '[.candidates[] | select(.number == 12) | .retry_after]' '[null]'
# Stages are routed per card: a merging card merges once no routed stage remains, and only on a review
# of its last routed (or visited) stage, or a stage-less review when it was routed to none
plan merging-stage-remaining "$(printf '%s\n%s' "$AUTO" "$STAGES_ADVISORY_YAML")"
assert_jq "merging routed stages: a card that visited only the first stage, routed to no other, merges" "$(card 12 action)" '"merge"'
plan merging-routed-first "$(printf '%s\n%s' "$AUTO" "$STAGES_ADVISORY_YAML")"
assert_jq "merging routed stages: a card routed to only the first of two stages merges" "$(card 12 action)" '"merge"'
plan merging-routed-both "$(printf '%s\n%s' "$AUTO" "$STAGES_ADVISORY_YAML")"
assert_jq "merging routed stages: a routed stage remaining plans skip" "$(card 12 action)" '"skip"'
assert_jq "merging routed stages: the remaining stage is named" "$(jq -r "$(card 12 reason)" <<<"$LAST_OUT" | grep -c 'stage ux')" '1'
assert_jq "merging routed stages: reason ends with supervisor decides" "$(jq -r "$(card 12 reason)" <<<"$LAST_OUT" | grep -c 'supervisor decides$')" '1'
plan merging-open-merge "$(printf '%s\n%s' "$AUTO" "$STAGES_ADVISORY_YAML")"
assert_jq "merging routed stages: a card routed to no stage merges on its in_review review" "$(card 12 action)" '"merge"'
setup_case merging-routed-first "$(printf '%s\n%s' "$AUTO" "$STAGES_ADVISORY_YAML")"; run_check "$SCRIPT" --settle-merge 12
assert_jq "merging routed stages: --settle-merge (merge-reviewed.sh) plans the same merge" "$(card 12 action)" '"merge"'
# The human-QA question is asked for every merging card with an open PR, not only after its head moved
plan merging-open-qa "$AUTO"
assert_jq "merging human QA: a PR needing human QA at the reviewed head plans skip" "$(card 12 action)" '"skip"'
assert_jq "merging human QA: needs_human_qa is asked" "$(card 12 needs_human_qa)" 'true'
assert_jq "merging human QA: reason ends with supervisor decides" "$(jq -r "$(card 12 reason)" <<<"$LAST_OUT" | grep -c 'supervisor decides$')" '1'
plan merging-open-merge "$AUTO"
assert_jq "merging human QA: a PR needing none is asked and answers false" "$(card 12 needs_human_qa)" 'false'
plan merging-stage-remaining "$AUTO"
assert_jq "merging last stage: a stage record with no stages configured plans skip" "$(card 12 action)" '"skip"'
plan merging-advisory-last "$(printf '%s\n%s' "$AUTO" "$STAGES_ADVISORY_YAML")"
assert_jq "merging last stage: the last stage's review still merges" "$(card 12 action)" '"merge"'

# --candidates carries the planner's warnings (schema stays 2)
export FLEET_BOARD_TODAY=2026-11-11
setup_case merging-ignore-red "$(IGN_YAML 2026-12-31 2026-11-10)"
run_check "$SCRIPT" --candidates
assert_jq "candidates warnings: schema stays 2" '.schema_version' '2'
assert_jq "candidates warnings: the expired-entry warning is carried" '.warnings' '["merge.ignore_checks entry ci/legacy-?int expired 2026-11-10"]'
setup_case merging-open-merge "$AUTO"
run_check "$SCRIPT" --candidates
assert_jq "candidates warnings: none is an empty list" '.warnings' '[]'
unset FLEET_BOARD_TODAY

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
