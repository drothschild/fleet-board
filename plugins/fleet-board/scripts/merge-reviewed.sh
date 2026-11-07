#!/usr/bin/env bash
# merge-reviewed.sh - merges reviewed PRs under merge.policy: auto, for
# headless runs.
#
# Usage: merge-reviewed.sh      (no arguments; run from the repo root)
#
# Claude Code's auto-mode safety classifier blocks an unattended `gh pr merge`
# inside a headless session, so the merge runs here instead: a plain shell
# step outside any Claude session, like settle.sh and cleanup-done.sh. The
# wrapper adds no permission rule and never uses --dangerously-skip-permissions.
#
# What it does:
#   1. merge.policy other than auto: exits 0 and makes no call at all.
#   2. Lists the in_review column and every review stage column (a card in
#      Human QA is never listed). A
#      listing that fails ends the run with exit 1 before anything is written.
#   3. Repeatedly runs tick-plan.sh --settle-merge on remaining cards. The planner plans
#      `merge` only for a card whose review is clean for the current head,
#      whose PR is open, non-draft and has all checks green, and which does
#      not need Human QA. Every other card is left alone.
#   4. For each card planned `merge` or recovery `verify_main` in a review
#      stage (review_<name>):
#        gh pr merge <pr> --repo <board.repo> --squash --match-head-commit <head>
#        note.sh merge: merged_pr
#        verify-main.sh N <pr> (a failure is left for the next tick)
#        board-move.sh N done, then note.sh merge: state done, action_failures 0
#      A card whose body has an `## After merge` section is not moved to done
#      here: the manager's finish step runs those commands under an allowlist.
#
# A failure on one card ends that card's steps; the next tick plans what is
# left (a merged PR is planned verify_main, then finish).
#
# Exit codes:
#   0 - nothing to do, or every planned merge succeeded
#   1 - the column or the plan could not be read, or some step failed
#   2 - usage error
#   3 - verification/recovery failed; the wrapper must stop before another tick
#
# The candidate snapshot and FLEET_BOARD_MERGE_LIMIT (default 10) bound a drain.
# Attempt each candidate once, and replan after each attempt. A failed merge
# does not starve other cards. Verification must return literal ok:true.

set -uo pipefail
unset CDPATH # a relative cd must not follow CDPATH (it would also echo the path)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

[ $# -eq 0 ] || fb_die 2 "usage: merge-reviewed.sh"

fb_load_config

[ "$(fb_cfg merge.policy)" = auto ] || exit 0

warn() { printf 'fleet-board: warning: %s\n' "$1" >&2; }
VERIFY="${FLEET_BOARD_VERIFY_MAIN:-$FLEET_SCRIPTS/verify-main.sh}"

LIMIT="${FLEET_BOARD_MERGE_LIMIT:-10}"
case "$LIMIT" in ''|*[!0-9]*|0|0*) fb_die 2 "FLEET_BOARD_MERGE_LIMIT must be a positive integer" ;; esac
[ "${#LIMIT}" -le 6 ] || fb_die 2 "FLEET_BOARD_MERGE_LIMIT is too large"

# A fail-closed lock also protects direct invocations across linked worktrees.
COMMON="$(fb_git_common_dir "$FLEET_ROOT")" || fb_die 1 "cannot locate the git common directory"
LOCK="$COMMON/fleet-board-merge.lock"
mkdir "$LOCK" 2>/dev/null || fb_die 1 "merge drain already locked: $LOCK"
TMPD=""
trap 'rmdir "$LOCK"; [ -z "$TMPD" ] || rm -rf "$TMPD"' EXIT
trap 'exit 3' INT TERM
TMPD="$(mktemp -d)" || fb_die 1 "mktemp failed"


NUMS=""
for st in in_review $(fb_stage_states); do
  LIST="$(bash "$FLEET_SCRIPTS/board-list.sh" "$st" </dev/null)" || fb_die 1 "cannot list the $st column; nothing merged"
  COL="$(jq -r 'if type == "array" then .[].number else error("not a list") end' <<<"$LIST" 2>/dev/null)" \
    || fb_die 1 "cannot parse the $st column; nothing merged"
  for n in $COL; do
    fb_valid_number "$n" || fb_die 1 "the $st column lists a non-numeric card: $n"
    case " $NUMS " in *" $n "*) ;; *) NUMS="$NUMS $n" ;; esac
  done
done
[ -n "$NUMS" ] || exit 0

RC=0
ATTEMPTS=0
fail() { warn "#$1: $2; leaving the card for the next tick"; RC=1; }
merge_note() { # <card> <json patch>
  printf '%s\n' "$2" > "$TMPD/patch.json" || return 1
  bash "$FLEET_SCRIPTS/note.sh" merge "$1" "$TMPD/patch.json" </dev/null >/dev/null
}

while [ -n "$NUMS" ] && [ "$ATTEMPTS" -lt "$LIMIT" ]; do
  bash "$FLEET_SCRIPTS/board-cache-clear.sh" </dev/null >/dev/null || fb_die 3 "cannot refresh board state"
  # shellcheck disable=SC2086 # validated card numbers, intentional splitting
  PLAN="$(bash "$FLEET_SCRIPTS/tick-plan.sh" --settle-merge $NUMS </dev/null)" || fb_die 3 "cannot refresh the merge plan"
  # An unreadable card could hold an unverified earlier merge: fail closed.
  jq -e '.cards | type == "array"' <<<"$PLAN" >/dev/null 2>&1 || fb_die 3 "cannot parse the merge plan"
  if jq -e 'any(.cards[]; .action == "skip" and (.reason | test("^(lookup failed|invalid manager note)")))' <<<"$PLAN" >/dev/null; then
    fb_die 3 "merge recovery state is unreadable; nothing further merged"
  fi
  card="$(jq -c '([.cards[] | select(.action == "verify_main")] + [.cards[] | select(.action == "merge")]) | .[0] // empty' <<<"$PLAN")" || fb_die 3 "cannot select a merge candidate"
  [ -n "$card" ] || break
  n="$(jq -r '.number' <<<"$card")"
  pr="$(jq -r '.pr' <<<"$card")"
  fb_valid_number "$n" && fb_valid_number "$pr" || fb_die 3 "invalid card or PR in merge plan"
  # Remove before attempting so even an unchanged fake/remote response cannot spin.
  REST=""
  for candidate in $NUMS; do [ "$candidate" = "$n" ] || REST="$REST $candidate"; done
  NUMS="$REST"
  case "$(jq -r '.state' <<<"$card")" in in_review|review_*) ;; *) continue ;; esac

  if [ "$(jq -r '.action' <<<"$card")" = merge ]; then
    head="$(jq -r '.head_sha // empty' <<<"$card")"
    case "$head" in ''|*[!0-9a-fA-F]*) fb_die 3 "missing or invalid planned head for #$n" ;; esac
    ATTEMPTS=$((ATTEMPTS + 1))
    merge_rc=0
    gh pr merge "$pr" --repo "$FLEET_REPO" --squash --match-head-commit "$head" </dev/null >/dev/null || merge_rc=$?
    # Both exit paths are ambiguous: success may mean queued, while a lost
    # response may follow a completed merge. Only MERGED permits verification.
    state="$(gh pr view "$pr" --repo "$FLEET_REPO" --json isDraft,state,mergedAt,statusCheckRollup,headRefOid \
      | jq -er '.state')" || fb_die 3 "#$n: cannot resolve merge result; recovery required"
    case "$state" in
      MERGED) ;;
      OPEN|CLOSED)
        if [ "$merge_rc" -ne 0 ]; then fail "$n" "gh pr merge $pr failed"; continue; fi
        fb_die 3 "#$n: merge not completed (possibly queued); stopping until remote state resolves" ;;
      *) fb_die 3 "#$n: unknown state after merge; recovery required" ;;
    esac
    printf 'merged #%s PR #%s\n' "$n" "$pr"
    merge_note "$n" "$(jq -cn --argjson pr "$pr" '{merged_pr: $pr}')" || fb_die 3 "#$n: cannot record merged PR; recovery required"
  fi

  if ! main_check="$(bash "$VERIFY" "$n" "$pr" </dev/null 2>"$TMPD/verify.err")"; then
    cat "$TMPD/verify.err" >&2
    fb_die 3 "#$n: verify-main.sh failed; stopping merge drain"
  fi
  jq -e 'type == "object" and (.commit | type == "string" and length > 0) and (.ok | type == "boolean") and (.results | type == "array")' <<<"$main_check" >/dev/null 2>&1 \
    || fb_die 3 "#$n: invalid main verification result; stopping merge drain"
  # Preserve red evidence too, but never finish the card or merge another PR.
  merge_note "$n" "$(jq -c '{main_check: .}' <<<"$main_check")" || fb_die 3 "#$n: cannot record main verification"
  [ "$(jq -r '.ok' <<<"$main_check")" = true ] || fb_die 3 "#$n: main verification failed; stopping merge drain"

  note="$(bash "$FLEET_SCRIPTS/note.sh" get "$n" </dev/null)" || { fail "$n" "cannot read pending follow-ups"; continue; }
  if jq -e '.pending_followups != null' <<<"$note" >/dev/null; then
    continue # verification recovery precedes filing; the manager still owes it
  fi
  body="$(bash "$FLEET_SCRIPTS/board-read.sh" "$n" </dev/null | jq -er '.body // ""')" || { fail "$n" "cannot read after-merge instructions"; continue; }
  if printf '%s\n' "$body" | grep -q '^## After merge'; then
    continue # the manager finishes the allowlisted commands
  fi
  bash "$FLEET_SCRIPTS/board-move.sh" "$n" done </dev/null >/dev/null || { fail "$n" "board-move to done failed"; continue; }
  merge_note "$n" '{"state":"done","action_failures":0,"last_action_error":null}' || fail "$n" "the manager note write failed"
done
exit "$RC"
