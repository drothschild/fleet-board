#!/usr/bin/env bash
# tick-plan.sh - decides one step for every card on the board (the tick plan).
#
# Usage: tick-plan.sh        (no arguments; run inside the repo)
#
# Lists the ready, in_progress, in_review and blocked columns, reads each card
# once (board-read.sh; the manager note is parsed from that read with
# note.sh parse), makes the PR lookups the decision needs, and prints:
#
#   {"dispatchable": bool, "warnings": [..], "cards": [
#     {"number", "title", "state", "action", "reason", "branch", "worktree", "pr",
#      "round", "models": {"implementor","reviewer","fixer"}, "escalated",
#      "needs_human_qa": bool|null, "comment_needed": bool|null}]}
#
# branch and worktree are always set: the note's when it has them, else the
# defaults fleet/<n>-<slug> and <base>/<n>-<slug> (slug from the title, "card"
# when empty). A note worktree outside the current base counts as none.
#
# Lookups per card (all through gh --repo <board.repo>):
#   gh pr list --head <branch> --state open --json number
#       in_progress/in_review, when note.pr is null and note.branch is set
#   gh pr view <pr> --json isDraft,state,mergedAt,statusCheckRollup,headRefOid
#       in_progress/in_review, when a PR is known
#   needs-human-qa.sh --labels <card labels> <n> <pr>
#       in_review, when the PR is open and the review is clean and current
#       (last_review.round >= note.round, as in the table, and no Critical or
#       Important finding); otherwise needs_human_qa is null, since the
#       decision does not use it
#   gh pr view <blocking_pr> --json state,mergedAt
#       blocked, when note.blocking_pr is set
# A failed lookup (or a failed card or note read) makes that card's action
# skip, with reason "lookup failed: <command>" and a warning. It never falls
# through to any other action.
#
# A card whose manager note note.sh rejects as invalid is skipped with reason
# "invalid manager note: <field>" and the warning
# "#<n>: invalid manager note: <field>; fix or replace it (note.sh put)":
# note.sh merge refuses to write over an invalid note, so no action could
# record its effect (an attempt count, a round), and the card would loop.
#
# The decision table itself is the single jq program below.
#
# Pending follow-ups (note.pending_followups) hold a card in file_pending only
# when a PR is known to file them against: pending_followups.pr, else note.pr,
# else the PR this plan found. Without one, the card goes through the table as
# usual and the plan warns "pending follow-ups on #<n> wait for a PR".
# Action failures: note.action_failures is the number of the manager's
# actions on the card, in a row, that failed to make progress, as the
# manager records them: any action (start, continue_implementor,
# start_review, review, fix, mark_ready, merge, verify_main, to_human_qa,
# file_pending, block, unblock, finish, skip_no_acceptance) whose intended
# board or note change did not happen, for any reason (a failed setup step,
# a report rejected twice, a failed gh, board or script call, a refused
# merge); an action that made progress resets it to 0. This script only
# reads the count. Below, k is note.action_failures, max is
# review.max_rounds and <error> is note.last_action_error, or
# "no error recorded" when it is null:
#   ready, in_progress, in_review, max <= k < 2*max: block, with reason
#     "no progress after <k> attempts: <error>", whatever action the table
#     would give. A block that fails is counted too, so k keeps rising while
#     the card stays in its column.
#   ready, in_progress, in_review, k >= 2*max: skip, with reason
#     "could not be blocked after <k> attempts: <error>" and the warning
#     "#<n>: could not be blocked after <k> attempts: <error>; fix the board, move the card by hand, then run: bash <scripts>/note.sh reset-failures <n>".
#   blocked, with note.blocking_pr set and merged (the table would give
#     unblock), k >= max: skip (unblock is not tried again), with reason
#     "unblock made no progress after <k> attempts: <error>" and the warning
#     "#<n>: unblock made no progress after <k> attempts: <error>; move the card by hand, then run: bash <scripts>/note.sh reset-failures <n>".
#     Any other blocked card has no unblock to fail: it gets the table's
#     skip "blocked", whatever k is.
#   <scripts> is this script's absolute directory, single-quoted when it
#   holds a character the shell would split or expand. A hand move does not
#   reset k (it lives in the note), so without the reset the card would stay
#   skipped (k >= 2*max) or be blocked again (a blocked card moved to ready).
# So, file_pending aside (it comes first, and is never dispatchable by
# itself), the plan gives no action to a card whose recorded count is
# 2*max or more, or max or more when it is blocked: at most 2*max actions
# in a row without progress on a card before it waits for a person. The count lives in the note, not in the column: only an
# action that made progress (the manager resets it) or a person editing the
# note (note.sh reset-failures) clears it. It bounds only what the manager records; a failure the
# manager does not record is not counted. Order: a failed lookup, then an
# invalid note (both skip), then file_pending (it only files, and pending
# items are never dropped), then these rules, then the table.
# An in_review card with no known PR is skipped with the warning
# "#<n>: in review, but no PR is known".
# A clean, current review whose human-QA answer is unknown is skipped with
# the warning "human-QA need unknown for #<n>".
# A current review with Critical or Important findings plans review, not fix,
# when the open PR's headRefOid is no longer last_review.sha (compared by
# prefix, so a short sha never reads as a move), with reason "PR head <h7>
# differs from the round <round> review at <s7>; review the new commits before
# fixing again". The commits came from a fixer whose report was never
# reconciled (no round bump) or from a person; fixing again would redo the
# work, while the manager's review action reviews exactly those commits
# (prev_sha = last_review.sha). This comes before the max_rounds block.
# A note worktree outside the current base (note.sh reads it as null) adds
# note.sh's warning to the plan's warnings:
# "manager note on #<n> names a worktree outside <base>; treating it as null: <path>".
#
# Exit codes:
#   0 - plan printed
#   1 - a column could not be listed, or the plan could not be built
#   2 - usage error

set -uo pipefail
unset CDPATH # a relative cd must not follow CDPATH (it would also echo the path)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

[ $# -eq 0 ] || fb_die 2 "usage: tick-plan.sh (no arguments)"

fb_load_config

WT_DIR="$FLEET_ROOT/$(fb_cfg worktrees.dir)"
BASE="$(mkdir -p "$WT_DIR" && cd "$WT_DIR" && pwd -P)" || fb_die 1 "cannot resolve the worktrees directory $WT_DIR"
[ -n "$BASE" ] || fb_die 1 "cannot resolve the worktrees directory $WT_DIR"

SKIP_MARKER='<!-- fleet-board:skip-no-acceptance -->'

CARDS_FILE="$(mktemp)" || fb_die 1 "cannot create a temp file"
NOTE_ERR="$(mktemp)" || { rm -f "$CARDS_FILE"; fb_die 1 "cannot create a temp file"; }
trap 'rm -f "$CARDS_FILE" "$NOTE_ERR"' EXIT

# card_input <state> <n> <title-json>: prints one JSON object holding every
# input the decision needs. The first failed lookup is recorded in
# lookup_failed and no further lookups are made for the card.
card_input() {
  local st="$1" n="$2" title="$3"
  local failed="" read="" note='{}' has_acc=false marker=false pr=null info=null invalid="" outside=""
  local blocking_merged=null nhq=null body branch bpr out cmd found labels

  read="$(bash "$FLEET_SCRIPTS/board-read.sh" "$n")" || failed="board-read.sh $n"
  if [ -z "$failed" ]; then
    body="$(jq -r '.body // ""' <<<"$read" 2>/dev/null)" || failed="board-read.sh $n (unparsable)"
  fi
  if [ -z "$failed" ]; then
    fb_has_acceptance "$body" && has_acc=true
    marker="$(jq --arg m "$SKIP_MARKER" '[(.comments // [])[] | (.body // "") | contains($m)] | any' <<<"$read" 2>/dev/null)" \
      || failed="board-read.sh $n (unparsable comments)"
  fi
  if [ -z "$failed" ]; then
    note="$(bash "$FLEET_SCRIPTS/note.sh" parse "$n" <<<"$read" 2>"$NOTE_ERR")" || { note='{}'; failed="note.sh parse $n"; }
    cat "$NOTE_ERR" >&2
    invalid="$(sed -n "s/^fleet-board: warning: ignoring invalid manager note on #$n: //p" "$NOTE_ERR" | head -1)"
    outside="$(sed -n "s/^fleet-board: warning: \(manager note on #$n names a worktree outside .*\)$/\1/p" "$NOTE_ERR" | head -1)"
  fi
  if [ -z "$failed" ]; then
    pr="$(jq -c '.pr' <<<"$note")" || failed="note.sh parse $n (unparsable)"
  fi

  # The card's own PR: known from the note, or discovered from its branch
  if [ -z "$failed" ] && [ -z "$invalid" ] && { [ "$st" = in_progress ] || [ "$st" = in_review ]; }; then
    branch="$(jq -r '.branch // empty' <<<"$note")"
    if [ "$pr" = null ] && [ -n "$branch" ]; then
      cmd="gh pr list --repo $FLEET_REPO --head $branch --state open --json number"
      if out="$(gh pr list --repo "$FLEET_REPO" --head "$branch" --state open --json number)"; then
        found="$(jq -r 'if type == "array" then (.[0].number // "none") else error("not a list") end' <<<"$out" 2>/dev/null)" \
          || failed="$cmd (unexpected response)"
        if [ -z "$failed" ] && [ "$found" != none ]; then
          if fb_valid_number "$found"; then pr="$found"; else failed="$cmd (unexpected response)"; fi
        fi
      else
        failed="$cmd"
      fi
    fi
    if [ -z "$failed" ] && [ "$pr" != null ]; then
      cmd="gh pr view $pr --repo $FLEET_REPO --json isDraft,state,mergedAt,statusCheckRollup,headRefOid"
      if out="$(gh pr view "$pr" --repo "$FLEET_REPO" --json isDraft,state,mergedAt,statusCheckRollup,headRefOid)"; then
        info="$(jq -c 'if (.state | type) == "string" and (.isDraft | type) == "boolean"
                       then {isDraft, state, mergedAt, statusCheckRollup, headRefOid}
                       else error("unexpected") end' <<<"$out" 2>/dev/null)" \
          || { info=null; failed="$cmd (unexpected response)"; }
      else
        failed="$cmd"
      fi
    fi
    # The human-QA question matters only for a clean review of the current round
    if [ -z "$failed" ] && [ "$st" = in_review ] && [ "$info" != null ] \
       && [ "$(jq -r '.state' <<<"$info")" = OPEN ] \
       && [ "$(jq -r '(.last_review // null) as $lr | $lr != null and (($lr.round // 0) >= (.round // 0))
                        and ((($lr.critical // 0) + ($lr.important // 0)) == 0)' <<<"$note")" = true ]; then
      labels="$(jq -c '[(.labels // [])[] | strings]' <<<"$read" 2>/dev/null)" || labels='[]'
      nhq="$(bash "$FLEET_SCRIPTS/needs-human-qa.sh" --labels "$labels" "$n" "$pr")" || { nhq=null; failed="needs-human-qa.sh $n $pr"; }
      case "$nhq" in
        true|false|null) ;;
        *) nhq=null; failed="needs-human-qa.sh $n $pr (unexpected answer)" ;;
      esac
    fi
  fi

  # A blocked card's blocking PR
  if [ -z "$failed" ] && [ -z "$invalid" ] && [ "$st" = blocked ]; then
    bpr="$(jq -r '.blocking_pr // empty' <<<"$note")"
    if [ -n "$bpr" ]; then
      cmd="gh pr view $bpr --repo $FLEET_REPO --json state,mergedAt"
      if out="$(gh pr view "$bpr" --repo "$FLEET_REPO" --json state,mergedAt)"; then
        blocking_merged="$(jq 'if (.state | type) == "string" then .state == "MERGED" else error("unexpected") end' <<<"$out" 2>/dev/null)" \
          || { blocking_merged=null; failed="$cmd (unexpected response)"; }
      else
        failed="$cmd"
      fi
    fi
  fi

  jq -cn --arg st "$st" --argjson n "$n" --argjson title "$title" --arg failed "$failed" --arg invalid "$invalid" \
    --arg outside "$outside" \
    --argjson has_acc "$has_acc" --argjson marker "$marker" --argjson note "$note" \
    --argjson pr "$pr" --argjson info "$info" --argjson bm "$blocking_merged" --argjson nhq "$nhq" \
    '{number: $n, title: $title, state: $st,
      lookup_failed: (if $failed == "" then null else $failed end),
      invalid_note: (if $invalid == "" then null else $invalid end),
      outside_warning: (if $outside == "" then null else $outside end),
      has_acceptance: $has_acc, skip_marker: $marker, note: $note, pr: $pr,
      pr_info: $info, blocking_merged: $bm, needs_human_qa: $nhq}'
}

SEEN=" "
for st in ready in_progress in_review blocked; do
  LIST="$(bash "$FLEET_SCRIPTS/board-list.sh" "$st")" || fb_die 1 "cannot list the $st column"
  NUMS="$(jq -r 'if type == "array" then .[].number else error("not a list") end' <<<"$LIST" 2>/dev/null)" \
    || fb_die 1 "cannot parse the $st column"
  for n in $NUMS; do
    fb_valid_number "$n" || fb_die 1 "the $st column lists a non-numeric card: $n"
    case "$SEEN" in *" $n "*) continue ;; esac
    SEEN="$SEEN$n "
    TITLE="$(jq -c --argjson n "$n" 'first(.[] | select(.number == $n) | .title) // ""' <<<"$LIST")" \
      || fb_die 1 "cannot read the title of card #$n"
    card_input "$st" "$n" "$TITLE" >> "$CARDS_FILE" || fb_die 1 "cannot build the plan input for card #$n"
  done
done

jq -s -c --argjson cfg "$FLEET_CFG" --arg base "$BASE" --arg note_sh "$FLEET_SCRIPTS/note.sh" '
  def green: (.statusCheckRollup | type) == "array"
    and all(.statusCheckRollup[]; (.conclusion // .state) as $s
      | $s == "SUCCESS" or $s == "NEUTRAL" or $s == "SKIPPED");
  def slug: ascii_downcase | gsub("[^a-z0-9]+"; "-") | sub("^-+"; "") | sub("-+$"; "")
    | .[0:40] | sub("-+$"; "") | if . == "" then "card" else . end;
  def act($a; $r): {action: $a, reason: $r};
  # True when the open PR head is known and is not the commit the last review
  # saw. Compared by prefix, so an abbreviated sha on either side never reads
  # as a move (a false "moved" would plan a review every tick).
  def head_moved($c; $lr):
    ($c.pr_info.headRefOid // null) as $h | ($lr.sha // null) as $s
    | ($h | type) == "string" and ($s | type) == "string" and $h != "" and $s != ""
      and (($h | startswith($s)) or ($s | startswith($h)) | not);
  # The command a person runs after moving a skipped card by hand: the path is
  # absolute, and single-quoted when the shell would split or expand it
  def reset_cmd($n): "bash \($note_sh | if test("\\A[A-Za-z0-9/._+:@-]+\\z") then . else @sh end) reset-failures \($n)";

  $cfg.review.max_rounds as $max
  | $cfg.models as $m

  # The action table (AC1). $c is the card input, $n its note.
  | def decide($c; $n; $round):
      ($n.last_review) as $lr
      | ((($lr.critical // 0) + ($lr.important // 0))) as $ci
      | ($n.implementor_attempts // 0) as $tries
      | ($n.action_failures // 0) as $fails
      | ($n.last_action_error // "no error recorded") as $err
      | if $c.lookup_failed != null then act("skip"; "lookup failed: \($c.lookup_failed)")
        elif $c.invalid_note != null then act("skip"; "invalid manager note: \($c.invalid_note)")
        elif $n.pending_followups != null and ($n.pending_followups.pr // $n.pr // $c.pr) != null
          then act("file_pending"; "pending follow-ups")
        elif ($c.state == "ready" or $c.state == "in_progress" or $c.state == "in_review")
             and $fails >= 2 * $max
          then act("skip"; "could not be blocked after \($fails) attempts: \($err)")
        elif ($c.state == "ready" or $c.state == "in_progress" or $c.state == "in_review")
             and $fails >= $max
          then act("block"; "no progress after \($fails) attempts: \($err)")
        elif $c.state == "blocked" and $n.blocking_pr != null and $c.blocking_merged == true and $fails >= $max
          then act("skip"; "unblock made no progress after \($fails) attempts: \($err)")
        elif $c.state == "ready" then
          if $c.has_acceptance then act("start"; "ready, with an Acceptance section")
          else act("skip_no_acceptance"; "no ## Acceptance section") end
        elif $c.state == "in_progress" then
          if $c.pr != null then act("start_review"; "PR #\($c.pr) exists")
          elif $tries >= $max then act("block"; "implementor produced no PR after \($tries) attempts")
          else act("continue_implementor"; "no PR yet (\($tries) of \($max) implementor attempts)") end
        elif $c.state == "in_review" then
          if $c.pr == null or $c.pr_info == null then act("skip"; "in review, but no PR is known")
          elif $c.pr_info.state == "MERGED" then
            if $n.main_check == null then act("verify_main"; "PR #\($c.pr) merged; main not yet verified")
            else act("finish"; "PR #\($c.pr) merged and main verified") end
          elif $c.pr_info.state != "OPEN" then act("skip"; "PR #\($c.pr) is \($c.pr_info.state | ascii_downcase) without a merge")
          elif $lr == null or ($lr.round // 0) < $round then act("review"; "round \($round) not reviewed yet")
          # Commits landed after a review with findings (a fixer whose report
          # was never reconciled, or a person): review them; never fix again.
          elif $ci > 0 and head_moved($c; $lr)
            then act("review"; "PR head \($c.pr_info.headRefOid[0:7]) differs from the round \($round) review at \($lr.sha[0:7]); review the new commits before fixing again")
          elif $ci > 0 and $round >= $max then act("block"; "\($ci) Critical/Important findings survive round \($round) of \($max)")
          elif $ci > 0 then act("fix"; "\($ci) Critical/Important findings in round \($round)")
          elif $c.needs_human_qa == true then act("to_human_qa"; "no Critical/Important findings; needs human QA")
          elif $c.needs_human_qa != false then act("skip"; "human-QA need unknown")
          elif $c.pr_info.isDraft then act("mark_ready"; "no Critical/Important findings; PR is a draft")
          elif $cfg.merge.policy == "auto" and ($c.pr_info | green) then act("merge"; "clean review, green checks, merge.policy auto")
          else act("wait"; "waiting for a human merge or green checks") end
        elif $c.state == "blocked" then
          if $n.blocking_pr != null and $c.blocking_merged == true then act("unblock"; "blocking PR #\($n.blocking_pr) merged")
          else act("skip"; "blocked") end
        else act("skip"; "state \($c.state) is not planned") end;

  [ .[] | . as $c | ($c.note // {}) as $n
    | ($n.round // 0) as $round
    # Models (AC6.2): from escalate_after_rounds on, implementor and fixer use
    # models.escalation, or the reviewer model when that is null
    | ($round >= $m.escalate_after_rounds) as $esc
    | ($m.escalation // $m.reviewer) as $emodel
    | {implementor: (if $esc then $emodel else $m.implementor end),
       reviewer: $m.reviewer,
       fixer: (if $esc then $emodel else $m.fixer end)} as $models
    | (($c.title // "") | slug) as $slug
    | decide($c; $n; $round) as $d
    | {number: $c.number, title: $c.title, state: $c.state, action: $d.action, reason: $d.reason,
       branch: ($n.branch // "fleet/\($c.number)-\($slug)"),
       worktree: ($n.worktree // "\($base)/\($c.number)-\($slug)"),
       pr: $c.pr, round: $n.round, models: $models, escalated: $esc,
       needs_human_qa: (if $c.state == "in_review" then $c.needs_human_qa else null end),
       comment_needed: (if $d.action == "skip_no_acceptance" then ($c.skip_marker | not) else null end),
       pending_wait: ($n.pending_followups != null and $d.action != "file_pending" and $c.lookup_failed == null),
       outside_warning: $c.outside_warning}
  ] as $cards
  | {dispatchable: any($cards[];
        (.action != "skip" and .action != "wait" and .action != "file_pending" and .action != "skip_no_acceptance")
        or (.action == "skip_no_acceptance" and .comment_needed == true)),
     warnings: (
       (if $m.implementor == $m.reviewer
        then ["implementor and reviewer share model \($m.implementor); the reviewer shares the writer'"'"'s blind spots"]
        else [] end)
       + (if $m.escalation != null and $m.escalation == $m.reviewer
          then ["escalation and reviewer share model \($m.escalation); the escalated writer shares the reviewer'"'"'s blind spots"]
          else [] end)
       + [$cards[] | select(.action == "skip" and (.reason | startswith("lookup failed")))
          | "#\(.number): \(.reason)"]
       + [$cards[] | select(.action == "skip" and (.reason | test("without a merge$")))
          | "#\(.number): \(.reason)"]
       + [$cards[] | select(.action == "skip" and (.reason | startswith("invalid manager note: ")))
          | "#\(.number): \(.reason); fix or replace it (note.sh put)"]
       + [$cards[] | select(.action == "skip" and .reason == "in review, but no PR is known")
          | "#\(.number): \(.reason)"]
       + [$cards[] | select(.action == "skip" and .reason == "human-QA need unknown")
          | "human-QA need unknown for #\(.number)"]
       + [$cards[] | select(.action == "skip" and (.reason | startswith("could not be blocked after ")))
          | "#\(.number): \(.reason); fix the board, move the card by hand, then run: \(reset_cmd(.number))"]
       + [$cards[] | select(.action == "skip" and (.reason | startswith("unblock made no progress after ")))
          | "#\(.number): \(.reason); move the card by hand, then run: \(reset_cmd(.number))"]
       + [$cards[] | select(.outside_warning != null) | .outside_warning]
       + [$cards[] | select(.pending_wait) | "pending follow-ups on #\(.number) wait for a PR"]),
     cards: [$cards[] | del(.pending_wait, .outside_warning)]}
' "$CARDS_FILE" || fb_die 1 "cannot build the tick plan"
