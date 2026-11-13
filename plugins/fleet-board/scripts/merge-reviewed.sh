#!/usr/bin/env bash
# merge-reviewed.sh - merges reviewed PRs under merge.policy: auto, for
# headless runs.
#
# Usage: merge-reviewed.sh      (no arguments; run from the repo root)
#        merge-reviewed.sh --card <n> [--no-finish]
#        merge-reviewed.sh --card <n> --operation-key <key> --pr <pr> --head <sha> [--no-finish]
#        merge-reviewed.sh --inspect --card <n> --operation-key <key> --pr <pr> --head <sha>
#
# Claude Code's auto-mode safety classifier blocks an unattended `gh pr merge`
# inside a headless session, so the merge runs here instead: a plain shell
# step outside any Claude session, like cleanup-done.sh. The
# wrapper adds no permission rule and never uses --dangerously-skip-permissions.
#
# What it does:
#   1. merge.policy other than auto: exits 0 and makes no call at all.
#   2. Lists the in_review column, every review stage column and merging (a card in
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
# --no-finish (with --card, also the keyed form): merges, notes merged_pr (and
# merge_operation), verifies main and notes main_check, then stops. The card is
# not moved to done and no done note is written (the supervisor finishes it
# after the merger); exit codes are unchanged (3 on a failed verification).
# A card in merging is always handled as --no-finish, in every form (the
# legacy no-argument one included): only the supervisor finishes it.
#
# --inspect prints {status:"observed", ...} when the note's marker matches the
# key, PR and head; {status:"unmatched"} for another operation's marker; and
# {status:"absent", pr, planned_head, observed_head, state} when the note has
# no marker at all (nothing was attempted).
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
# Keyed single-card operations persist the controller key and exact PR/head
# before mutation. --inspect returns fresh note/PR/head/verification evidence.

set -uo pipefail
unset CDPATH # a relative cd must not follow CDPATH (it would also echo the path)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

NO_FINISH=0
ARGS=()
for a in "$@"; do
  if [ "$a" = --no-finish ]; then NO_FINISH=1; else ARGS+=("$a"); fi
done
set -- ${ARGS[@]+"${ARGS[@]}"}
[ "$NO_FINISH" = 0 ] || [ "$#" -gt 0 ] || fb_die 2 "--no-finish requires --card"

INSPECT=0
CARD_ONLY=""
OPERATION_KEY=""
EXPECTED_PR=""
EXPECTED_HEAD=""
if [ "$#" -gt 0 ]; then
  if [ "$1" = --inspect ]; then INSPECT=1; shift; fi
  [ "$#" -eq 2 ] || [ "$#" -eq 8 ] || fb_die 2 "invalid merge-reviewed.sh arguments"
  [ "$1" = --card ] || fb_die 2 "invalid merge-reviewed.sh arguments"
  CARD_ONLY="$2"
  fb_valid_number "$CARD_ONLY" || fb_die 2 "invalid merge-reviewed.sh card"
  if [ "$#" -eq 8 ]; then
    [ "$3" = --operation-key ] && [ "$5" = --pr ] && [ "$7" = --head ] || fb_die 2 "invalid bounded operation arguments"
    OPERATION_KEY="$4"; EXPECTED_PR="$6"; EXPECTED_HEAD="$8"
    case "$OPERATION_KEY" in ''|*[!A-Za-z0-9._:-]*) fb_die 2 "invalid controller operation key" ;; esac
    [ "${#OPERATION_KEY}" -le 128 ] || fb_die 2 "invalid controller operation key"
    fb_valid_number "$EXPECTED_PR" || fb_die 2 "invalid expected PR"
    case "$EXPECTED_HEAD" in ''|*[!0-9a-fA-F]*) fb_die 2 "invalid expected head" ;; esac
  fi
  [ "$INSPECT" = 0 ] || [ "$#" -eq 8 ] || fb_die 2 "inspection requires a keyed bounded operation"
  [ -z "$OPERATION_KEY" ] || [ "$#" -eq 8 ] || fb_die 2 "operation key requires PR and head bindings"
fi

fb_load_config

if [ "$INSPECT" = 1 ]; then
  note="$(bash "$FLEET_SCRIPTS/note.sh" get "$CARD_ONLY" </dev/null)" || fb_die 3 "cannot read merge recovery note"
  info="$(gh pr view "$EXPECTED_PR" --repo "$FLEET_REPO" --json isDraft,state,mergedAt,statusCheckRollup,headRefOid)" || fb_die 3 "cannot inspect merge recovery PR"
  jq -nc --arg key "$OPERATION_KEY" --argjson pr "$EXPECTED_PR" --arg head "$EXPECTED_HEAD" --argjson note "$note" --argjson info "$info" '
    ($note.merge_operation // $note.pending_merge // null) as $marker
    | if $marker == null then
        # no marker at all: no merge was attempted (the fresh plan skipped the card); the PR as it is now
        {status:"absent", pr:$pr, planned_head:$head, observed_head:$info.headRefOid, state:$info.state}
      elif ($marker.operation_key != $key or $marker.pr != $pr or $marker.head_sha != $head) then
        {status:"unmatched"}
      else
        {status:"observed", operation_key:$marker.operation_key, note_operation_key:$marker.operation_key,
         pr:$pr, planned_head:$head, observed_head:$info.headRefOid, state:$info.state,
         main_check:$marker.main_check}
      end' || fb_die 3 "cannot build merge recovery evidence"
  exit 0
fi

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
for st in in_review $(fb_stage_states) merging; do
  LIST="$(bash "$FLEET_SCRIPTS/board-list.sh" "$st" </dev/null)" || fb_die 1 "cannot list the $st column; nothing merged"
  COL="$(jq -r 'if type == "array" then .[].number else error("not a list") end' <<<"$LIST" 2>/dev/null)" \
    || fb_die 1 "cannot parse the $st column; nothing merged"
  for n in $COL; do
    fb_valid_number "$n" || fb_die 1 "the $st column lists a non-numeric card: $n"
    case " $NUMS " in *" $n "*) ;; *) NUMS="$NUMS $n" ;; esac
  done
done
[ -z "$CARD_ONLY" ] || case " $NUMS " in *" $CARD_ONLY "*) NUMS=" $CARD_ONLY" ;; *) NUMS="" ;; esac
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
  head="$(jq -r '.head_sha // empty' <<<"$card")"
  if [ -n "$OPERATION_KEY" ]; then
    [ "$n" = "$CARD_ONLY" ] && [ "$pr" = "$EXPECTED_PR" ] && [ "$head" = "$EXPECTED_HEAD" ] \
      || fb_die 3 "fresh merge plan no longer matches the journaled PR/head for #$CARD_ONLY"
    note_before="$(bash "$FLEET_SCRIPTS/note.sh" get "$n" </dev/null)" \
      || fb_die 3 "#$n: cannot read the merge operation marker"
    marker="$(jq -c '.merge_operation // .pending_merge // null' <<<"$note_before")"
    if [ "$marker" != null ]; then
      marker_key="$(jq -r '.operation_key // empty' <<<"$marker")"
      marker_pr="$(jq -r '.pr // empty' <<<"$marker")"
      marker_head="$(jq -r '.head_sha // empty' <<<"$marker")"
      if [ "$marker_key" = "$OPERATION_KEY" ] || { [ "$marker_pr" = "$pr" ] && [ "$marker_head" = "$head" ]; }; then
        [ "$marker_key" = "$OPERATION_KEY" ] && [ "$marker_pr" = "$pr" ] && [ "$marker_head" = "$head" ] \
          || fb_die 3 "#$n: a different operation owns the pending merge recovery marker"
      fi
    fi
    if [ "$marker" = null ] && [ "$(jq -r '.action' <<<"$card")" = verify_main ]; then
      fb_die 3 "#$n: merged PR verification has no matching journaled operation marker"
    fi
  fi
  # Remove before attempting so even an unchanged fake/remote response cannot spin.
  REST=""
  for candidate in $NUMS; do [ "$candidate" = "$n" ] || REST="$REST $candidate"; done
  NUMS="$REST"
  case "$(jq -r '.state' <<<"$card")" in in_review|review_*|merging) ;; *) continue ;; esac

  if [ "$(jq -r '.action' <<<"$card")" = merge ]; then
    case "$head" in ''|*[!0-9a-fA-F]*) fb_die 3 "missing or invalid planned head for #$n" ;; esac
    if [ -n "$OPERATION_KEY" ]; then
      merge_note "$n" "$(jq -cn --arg key "$OPERATION_KEY" --argjson pr "$pr" --arg head "$head" \
        '{pending_merge:{operation_key:$key,pr:$pr,head_sha:$head}}')" \
        || fb_die 3 "#$n: cannot persist merge recovery intent"
    fi
    ATTEMPTS=$((ATTEMPTS + 1))
    # Card numbers are not GitHub numbers: a closing keyword in the title, body or
    # a commit message would close an unrelated issue or PR. After the marker, so
    # the keyed form's refusal is observed on the open PR at the planned head.
    if ! bash "$FLEET_SCRIPTS/pr-closing-check.sh" "$pr" --repo "$FLEET_REPO" </dev/null 2>"$TMPD/closing.err"; then
      if grep -q 'closing keyword' "$TMPD/closing.err"; then
        fail "$n" "PR #$pr holds a GitHub closing keyword before an issue reference (title, body or a commit message); not merged"
      else
        fail "$n" "PR #$pr could not be checked for closing keywords; not merged"
      fi
      cat "$TMPD/closing.err" >&2
      continue
    fi
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
    if [ -n "$OPERATION_KEY" ]; then
      merge_note "$n" "$(jq -cn --arg key "$OPERATION_KEY" --argjson pr "$pr" --arg head "$head" \
        '{merged_pr:$pr,merge_operation:{operation_key:$key,pr:$pr,head_sha:$head}}')" \
        || fb_die 3 "#$n: cannot record merged PR operation; recovery required"
    else
      merge_note "$n" "$(jq -cn --argjson pr "$pr" '{merged_pr: $pr}')" || fb_die 3 "#$n: cannot record merged PR; recovery required"
    fi
  elif [ -n "$OPERATION_KEY" ]; then
    [ "$(jq -r '.action' <<<"$card")" = verify_main ] \
      || fb_die 3 "#$n: keyed operation is not a merge or verification recovery"
  fi

  if ! main_check="$(bash "$VERIFY" "$n" "$pr" </dev/null 2>"$TMPD/verify.err")"; then
    cat "$TMPD/verify.err" >&2
    fb_die 3 "#$n: verify-main.sh failed; stopping merge drain"
  fi
  jq -e 'type == "object" and (.commit | type == "string" and length > 0) and (.ok | type == "boolean") and (.results | type == "array")' <<<"$main_check" >/dev/null 2>&1 \
    || fb_die 3 "#$n: invalid main verification result; stopping merge drain"
  # Preserve red evidence too, but never finish the card or merge another PR.
  if [ -n "$OPERATION_KEY" ]; then
    merge_note "$n" "$(jq -cn --arg key "$OPERATION_KEY" --argjson pr "$pr" --arg head "$head" --argjson check "$main_check" \
      '{main_check:$check,merge_operation:{operation_key:$key,pr:$pr,head_sha:$head,main_check:$check}}')" \
      || fb_die 3 "#$n: cannot record operation-bound main verification"
  else
    merge_note "$n" "$(jq -c '{main_check: .}' <<<"$main_check")" || fb_die 3 "#$n: cannot record main verification"
  fi
  [ "$(jq -r '.ok' <<<"$main_check")" = true ] || fb_die 3 "#$n: main verification failed; stopping merge drain"
  [ "$NO_FINISH" = 0 ] || continue # --no-finish: the card stays where it is
  # A merging card is finished only by the supervisor, after the merger: every form is --no-finish for it
  [ "$(jq -r '.state' <<<"$card")" != merging ] || continue

  note="$(bash "$FLEET_SCRIPTS/note.sh" get "$n" </dev/null)" || { fail "$n" "cannot read pending follow-ups"; continue; }
  if jq -e '.pending_followups != null' <<<"$note" >/dev/null; then
    continue # verification recovery precedes filing; the manager still owes it
  fi
  body="$(bash "$FLEET_SCRIPTS/board-read.sh" "$n" </dev/null | jq -er '.body // ""')" || { fail "$n" "cannot read after-merge instructions"; continue; }
  if printf '%s\n' "$body" | grep -q '^## After merge'; then
    continue # the manager finishes the allowlisted commands
  fi
  final_card="$(bash "$FLEET_SCRIPTS/board-read.sh" "$n" </dev/null)" \
    || { fail "$n" "cannot re-read card before completing merge"; continue; }
  final_state="$(jq -er '.state // empty' <<<"$final_card" 2>/dev/null)" \
    || { fail "$n" "cannot determine card state before completing merge"; continue; }
  case "$final_state" in
    in_review|review_*) ;;
    *) warn "#$n: card moved to $final_state during verification; leaving its state unchanged"; continue ;;
  esac
  bash "$FLEET_SCRIPTS/board-move.sh" "$n" done </dev/null >/dev/null || { fail "$n" "board-move to done failed"; continue; }
  merge_note "$n" '{"state":"done","action_failures":0,"last_action_error":null}' || fail "$n" "the manager note write failed"
done
exit "$RC"
