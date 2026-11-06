#!/usr/bin/env bash
# settle.sh - moves cards right after a tick, for the steps that start no agent.
#
# Usage: settle.sh      (no arguments; run from the repo root)
#
# The headless wrapper runs it after each successful tick, before
# cleanup-done.sh, so a board change that needs no agent (a clean review
# reaching Human QA, a PR that exists moving to In review) does not wait a
# whole tick. It starts no Claude session and costs no API key.
#
# What it does:
#   1. Lists the in_progress and in_review columns, and every review stage
#      column (review_<name>), with board-list.sh (no --allow-truncated). A listing that fails ends the run with exit 1 before
#      anything is written. With no cards it stops without running the planner.
#   2. Runs tick-plan.sh --settle <those cards> once.
#   3. Carries out each planned action, as the manager's action table does
#      (agents/manager.md 2.2, 2.10, 2.11):
#        move_to_review  board-move.sh N in_review; note.sh merge with round 1,
#                        pr and state in_review; then review-stages.sh route N <pr>
#                        (a failure is a failed step)
#        advance_stage   board-move.sh N review_<stage>; note.sh merge with stage,
#                        round 1, reviewed_stages (the old list plus the stage left,
#                        only when the card was in a stage column) and state
#                        review_<stage>
#        to_human_qa     commands.qa_build (when set) in the plan card's worktree,
#                        keeping its exit code and last 20 lines; board-move.sh
#                        N human_qa; only after that succeeds, human-qa-handoff.sh
#                        [--qa-summary <file>] N <pr>; then note.sh merge with
#                        state human_qa
#        mark_ready      gh pr ready <pr> --repo <board.repo>
#        block           board-move.sh N blocked; note.sh merge with blocked_from,
#                        blocked_findings and state blocked; then a comment
#                        listing the findings. A block whose reason starts with
#                        "no progress after" is left for the next tick (the
#                        manager has its own order for those, 2.D).
#        skip, other     nothing (a review_stage is planned as skip: it waits for
#                        the next tick, so settle never runs a review stage)
#   It never merges and never moves a card out of human_qa.
#
# Failures stay small: a failed step ends that card's action and the script
# moves to the next card. It writes no action_failures or last_action_error;
# the next tick plans the same action and counts it there.
#
# Run it outside any Claude session, after the manager has finished, so only
# one writer touches the board. A person's interactive /fleet-board:tick does
# not run it.
#
# Exit codes:
#   0 - every planned action succeeded (or there was nothing to do)
#   1 - a column could not be listed or the plan could not be built (nothing
#       written), or some step failed
#   2 - usage error

set -uo pipefail
unset CDPATH # a relative cd must not follow CDPATH (it would also echo the path)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

[ $# -eq 0 ] || fb_die 2 "usage: settle.sh"

fb_load_config

warn() { printf 'fleet-board: warning: %s\n' "$1" >&2; }

TMPD="$(mktemp -d)" || fb_die 1 "mktemp failed"
trap 'rm -rf "$TMPD"' EXIT

# Both columns are listed before anything is written
NUMS=""
for st in in_progress in_review $(fb_stage_states); do
  LIST="$(bash "$FLEET_SCRIPTS/board-list.sh" "$st" </dev/null)" || fb_die 1 "cannot list the $st column; nothing settled"
  COL="$(jq -r 'if type == "array" then .[].number else error("not a list") end' <<<"$LIST" 2>/dev/null)" \
    || fb_die 1 "cannot parse the $st column; nothing settled"
  for n in $COL; do
    fb_valid_number "$n" || fb_die 1 "the $st column lists a non-numeric card: $n"
    case " $NUMS " in *" $n "*) ;; *) NUMS="$NUMS $n" ;; esac
  done
done
[ -n "$NUMS" ] || exit 0

# shellcheck disable=SC2086 # word splitting intended: a list of card numbers
PLAN="$(bash "$FLEET_SCRIPTS/tick-plan.sh" --settle $NUMS </dev/null)" || fb_die 1 "cannot build the settle plan; nothing settled"
CARDS="$(jq -c 'if (.cards | type) == "array" then .cards[] else error("no cards") end' <<<"$PLAN" 2>/dev/null)" \
  || fb_die 1 "cannot parse the settle plan; nothing settled"

RC=0
# fail <card> <what>: a step failed; the card's action ends
fail() { warn "#$1: $2; leaving the card for the next tick"; RC=1; }

# merge_note <card> <json patch>
merge_note() {
  printf '%s\n' "$2" > "$TMPD/patch.json" || return 1
  bash "$FLEET_SCRIPTS/note.sh" merge "$1" "$TMPD/patch.json" </dev/null >/dev/null
}

do_move_to_review() { # <n> <pr>
  local n="$1" pr="$2"
  [ "$pr" != null ] || { fail "$n" "move_to_review has no PR"; return; }
  bash "$FLEET_SCRIPTS/board-move.sh" "$n" in_review </dev/null >/dev/null || { fail "$n" "board-move to in_review failed"; return; }
  merge_note "$n" "$(jq -cn --argjson pr "$pr" '{round: 1, pr: $pr, state: "in_review"}')" \
    || { fail "$n" "the manager note write failed"; return; }
  bash "$FLEET_SCRIPTS/review-stages.sh" route "$n" "$pr" </dev/null >/dev/null \
    || fail "$n" "routing the card to its review stages failed"
}

do_advance_stage() { # <n> <stage object json> <from-state>
  local n="$1" stage="$2" from="$3" name note old
  name="$(jq -r '.name // ""' <<<"$stage" 2>/dev/null)"
  [ -n "$name" ] || { fail "$n" "advance_stage has no stage"; return; }
  note="$(bash "$FLEET_SCRIPTS/note.sh" get "$n" </dev/null 2>/dev/null)" || { fail "$n" "cannot read the manager note"; return; }
  old="$(jq -c '(if type == "object" then .reviewed_stages else null end) | if type == "array" then . else [] end' <<<"$note" 2>/dev/null)" \
    || { fail "$n" "cannot read the reviewed stages"; return; }
  bash "$FLEET_SCRIPTS/board-move.sh" "$n" "review_$name" </dev/null >/dev/null || { fail "$n" "board-move to review_$name failed"; return; }
  merge_note "$n" "$(jq -cn --arg s "$name" --arg from "$from" --argjson old "$old" '
    {stage: $s, round: 1,
     reviewed_stages: (if ($from | startswith("review_")) then $old + [$from | ltrimstr("review_")] else $old end),
     state: "review_\($s)"}')" \
    || fail "$n" "the manager note write failed"
}

do_to_human_qa() { # <n> <pr> <worktree>
  local n="$1" pr="$2" wt="$3" qa out rc summary=() note
  [ "$pr" != null ] || { fail "$n" "to_human_qa has no PR"; return; }
  qa="$(fb_cfg commands.qa_build)"
  if [ -n "$qa" ]; then
    if [ -d "$wt" ]; then
      out="$(cd "$wt" && bash -c "$qa" </dev/null 2>&1)"
      rc=$?
    else
      out="the worktree $wt does not exist"
      rc=1
    fi
    {
      printf 'QA build (`%s`): exit code %s\n\n```\n' "$qa" "$rc"
      printf '%s\n' "$out" | tail -20
      printf '```\n'
    } > "$TMPD/qa-summary.md"
    summary=(--qa-summary "$TMPD/qa-summary.md")
  fi
  bash "$FLEET_SCRIPTS/board-move.sh" "$n" human_qa </dev/null >/dev/null || { fail "$n" "board-move to human_qa failed"; return; }
  bash "$FLEET_SCRIPTS/human-qa-handoff.sh" ${summary[@]+"${summary[@]}"} "$n" "$pr" </dev/null >/dev/null \
    || { fail "$n" "the Human QA hand-off failed"; return; }
  merge_note "$n" '{"state":"human_qa"}' || fail "$n" "the manager note write failed"
}

do_mark_ready() { # <n> <pr>
  local n="$1" pr="$2"
  [ "$pr" != null ] || { fail "$n" "mark_ready has no PR"; return; }
  gh pr ready "$pr" --repo "$FLEET_REPO" </dev/null >/dev/null || fail "$n" "gh pr ready $pr failed"
}

do_block() { # <n> <state> <reason>
  local n="$1" from="$2" reason="$3" note findings
  case "$reason" in "no progress after"*) return ;; esac # the manager's own order (2.D)
  note="$(bash "$FLEET_SCRIPTS/note.sh" get "$n" </dev/null 2>/dev/null)" || { fail "$n" "cannot read the manager note"; return; }
  findings="$(jq -c --arg r "$reason" '
    ((if type == "object" then .last_review.findings else null end) // [])
    | if type == "array" then . else [] end
    | map(select(type == "object" and (.severity == "Critical" or .severity == "Important"))
          | {severity, text})
    | if length == 0 then [{severity: "Important", text: $r}] else . end' <<<"$note" 2>/dev/null)" \
    || { fail "$n" "cannot build the findings"; return; }
  bash "$FLEET_SCRIPTS/board-move.sh" "$n" blocked </dev/null >/dev/null || { fail "$n" "board-move to blocked failed"; return; }
  merge_note "$n" "$(jq -cn --arg from "$from" --argjson f "$findings" \
    '{blocked_from: $from, blocked_findings: $f, state: "blocked"}')" \
    || { fail "$n" "the manager note write failed"; return; }
  {
    printf 'This card was moved to Blocked: %s\n\n' "$reason"
    jq -r '.[] | "- [\(.severity)] \(.text | gsub("\n"; " "))"' <<<"$findings"
    printf '\nMove it back yourself once the findings are dealt with.\n'
  } > "$TMPD/block-comment.md"
  bash "$FLEET_SCRIPTS/board-comment.sh" "$n" "$TMPD/block-comment.md" </dev/null >/dev/null \
    || fail "$n" "the blocked comment failed"
}

while IFS= read -r card; do
  [ -n "$card" ] || continue
  n="$(jq -r '.number' <<<"$card")"
  fb_valid_number "$n" || { warn "the plan names a non-numeric card: $n"; RC=1; continue; }
  action="$(jq -r '.action' <<<"$card")"
  pr="$(jq -r '.pr' <<<"$card")"
  case "$action" in
    move_to_review) do_move_to_review "$n" "$pr" ;;
    advance_stage) do_advance_stage "$n" "$(jq -c '.stage // null' <<<"$card")" "$(jq -r '.state' <<<"$card")" ;;
    to_human_qa) do_to_human_qa "$n" "$pr" "$(jq -r '.worktree // ""' <<<"$card")" ;;
    mark_ready) do_mark_ready "$n" "$pr" ;;
    block) do_block "$n" "$(jq -r '.state' <<<"$card")" "$(jq -r '.reason' <<<"$card")" ;;
    *) ;; # skip, and anything else: nothing
  esac
done <<<"$CARDS"
exit "$RC"
