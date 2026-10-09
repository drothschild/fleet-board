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
    printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\n'
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
# gh calls for one in_review card: one card read (api user, issue, comments),
# the PR view, and the files lookup only when the review is clean and current.
# Before the note and labels were taken from the card read: 11 per card.
per_card_calls() { echo $(( $(wc -l < "$FAKE_GH_DIR/calls.log") - $(grep -c $'\tissue list' "$FAKE_GH_DIR/calls.log") )); }
plan in-review-mark-ready-human
assert_eq "gh-calls: clean current review (mark_ready): 5 per card" "$(per_card_calls)" 5
assert_eq "gh-calls: clean current review: one card read" "$(call_count api repos/acme/toy/issues/12)" 1
assert_eq "gh-calls: clean current review: one files lookup" "$(call_count pr view 34 --repo acme/toy --json files,changedFiles)" 1
plan in-review-fix
assert_eq "gh-calls: findings (fix): 4 per card, no files lookup" "$(per_card_calls)" 4
assert_jq "gh-calls: findings: needs_human_qa not computed" "$(card 12 needs_human_qa)" 'null'
plan in-review-needs-review
assert_eq "gh-calls: review not current (review): 4 per card, no files lookup" "$(per_card_calls)" 4
plan in-review-human-qa-label
assert_eq "gh-calls: labelled card: 4 per card, no files lookup" "$(per_card_calls)" 4
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
# Pending follow-ups with no PR anywhere (pending.pr, note.pr, the plan's own
# lookup) cannot be filed: the card is not held; it falls through with a warning
plan pending-followups-blocked
assert_jq "pending-followups-no-pr: blocked with merged blocker -> unblock" "$(card 20 action)" '"unblock"'
assert_jq "pending-followups-no-pr: blocked warning" '.warnings' '["pending follow-ups on #20 wait for a PR"]'
assert_jq "pending-followups-no-pr: blocked dispatchable" '.dispatchable' 'true'
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
assert_jq "action-failures: blocked 3 of 3: reason" "$(card 20 reason)" '"unblock made no progress after 3 attempts: card #20 has no '"'"'## Acceptance'"'"' section"'
assert_jq "action-failures: blocked 3 of 3: warning" '.warnings' "$(warns_json "#20: unblock made no progress after 3 attempts: card #20 has no '## Acceptance' section; move the card by hand, then run: bash $SCRIPTS_ABS/note.sh reset-failures 20")"
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
  "$(warns_json "#20: unblock made no progress after 3 attempts: card #20 has no '## Acceptance' section; move the card by hand, then run: bash '$SPACED/scripts/note.sh' reset-failures 20")"

# A column that cannot be listed fails the whole plan
plan list-failure
assert_exit "list-failure: exit 1" 1
assert_stdout_exact "list-failure: no plan printed" ""

# usage
plan ready-start
run_check "$SCRIPT" extra
assert_exit "usage: arguments rejected" 2

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
