#!/usr/bin/env bash
# tick-plan.sh - decides one step for every card on the board (the tick plan).
#
# Usage: tick-plan.sh                 (run inside the repo)
#        tick-plan.sh --settle <n>... (settle mode, below)
#
# Lists the ready, in_progress, in_review, review_<name> (one per configured
# review stage, in config order) and blocked columns, reads each card
# once (board-read.sh; the manager note is parsed from that read with
# note.sh parse), makes the PR lookups the decision needs, and prints:
#
#   {"dispatchable": bool, "warnings": [..], "cards": [
#     {"number", "title", "state", "action", "reason", "branch", "worktree", "pr",
#      "round", "models": {"implementor","reviewer","fixer"}, "escalated",
#      "needs_human_qa": bool|null, "stage": object|null,
#      "comment_needed": bool|null}]}
#
# stage is the config's stage object whole (as config.sh prints it: name,
# agent, provider, model, paths, label, advisory, max_rounds, brief, price,
# timeout, max_output_tokens, max_diff_bytes; provider is null for an agent
# stage, agent null for a provider stage): for advance_stage the stage being
# entered, for any other card in a stage column that column's stage, else null.
#
# Review stages: a card in a stage column (review_<name>) goes through the
# in_review branch of the table with these changes. Its reviews are
# review_stage, not review; "not reviewed yet" also holds when
# last_review.stage is not the column's stage (an in_review record has stage
# null), with reason "round <r> of <stage> not reviewed yet". The stage's own
# max_rounds bounds fix, and block reads "<ci> Critical/Important findings
# survive round <r> of <max> in <stage>". An advisory stage's findings count as
# clean. In in_review and every stage column, a clean, current review whose
# next stage (review-stages.sh next) is set plans advance_stage, reason
# "review clean; next stage <name>", before the human-QA tail; with no next
# stage the tail is unchanged. A card whose state label names a stage that is
# not configured reads with no canonical state and gets skip ("state <state>
# is not planned"). For a provider stage whose providers.<name>.api_key_env is
# unset or empty, the plan warns "stage <name>: <ENV> is not set; provider
# reviews will fail", once per stage, only when a card in the plan has action
# review_stage or fix in that stage (the check runs in bash; jq never reads the
# environment). review_stage stays dispatchable either way.
#
# branch and worktree are always set: the note's when it has them, else the
# defaults fleet/<n>-<slug> and <base>/<n>-<slug> (slug from the title, "card"
# when empty). A note worktree outside the current base counts as none.
#
# Lookups per card (all through gh --repo <board.repo>):
#   (a review column below is in_review or a configured stage column)
#   gh pr list --head <branch> --state open --json number
#       in_progress/review column, when note.pr is null and note.branch is set
#   gh pr view <pr> --json isDraft,state,mergedAt,statusCheckRollup,headRefOid
#       in_progress/review column, when a PR is known
#   gh pr view <pr> --json mergeable
#       in_progress/review column, when the PR is open. Best effort: a failed or
#       unparsable answer reads as "unknown" and plans nothing (no skip).
#   review-stages.sh next --labels <card labels> --after <state> --done <note.reviewed_stages> <n>
#       review column, when the PR is open and the review is clean and current
#       (last_review.round >= note.round, last_review.stage is the column's
#       stage, null in in_review, and no Critical or Important finding unless
#       the stage is advisory); a failure is "review-stages.sh next <n>"
#   needs-human-qa.sh --labels <card labels> <n> <pr>
#       review column, under the same condition, only when review-stages.sh
#       next printed nothing; otherwise needs_human_qa is null, since the
#       decision does not use it
#   gh pr view <blocking_pr> --json state,mergedAt
#       blocked, when note.blocking_pr is set
#   deps.sh parse / deps.sh check <n> <refs>
#       ready, with an Acceptance section and a "## Depends on" section in the
#       body: deps.sh check runs gh issue view <N> --repo <owner/repo> --json
#       state,stateReason per dependency, and on the Projects backend the
#       project Status of a dependency in board.repo (see deps.sh)
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
# Dependency gate: a ready card with an Acceptance section and any unmet
# dependency (its "## Depends on" bullets) gets action wait, with reason
# "waits for <ref> (<state or column>)[, <ref> (...)]", and stays in ready.
# The card's waiting_on lists the unmet refs (null for any other card). Only
# ready cards are gated; the card is not dispatchable for itself, while the
# plan's dispatchable still reflects the other cards. A bullet that names no
# dependency warns "#<n>: unrecognized dependency line: <line>" and is
# ignored; a dependency closed as not planned (or at Status Won't Do) warns
# "#<n> depends on <ref>, which was closed as not planned".
#
# Conflicting PRs: an open PR whose mergeable state is CONFLICTING, on an
# in_progress or in_review card, plans update_branch (reason "PR #<pr> has
# merge conflicts with its base branch"), before start_review, review, fix and
# every other dispatch for the card. The manager runs update-branch.sh, which
# merges the base into the branch and pushes (never rebases, never forces).
#
# Card lint: a ready card whose body fails card-lint.sh (and has the Acceptance
# heading, or a "**Acceptance**" / "Acceptance:" line in place of it) gets action
# skip_card_lint with reason "card lint failed: <rules>", the lint lines in
# "lint" and a "lint_marker" HTML comment naming the result. comment_needed is
# true until a comment holding that marker exists, so each distinct result is
# commented once. A body with no Acceptance hint stays skip_no_acceptance.
#
# The decision table itself is the single jq program below.
#
# Settle mode (--settle <n>...): the same plan JSON for only the named cards,
# keeping only the steps that start no agent. Each card is read with
# board-read.sh (its column comes from that read); no column is listed. The
# table's result is filtered: to_human_qa, advance_stage, block and mark_ready stay;
# start_review becomes move_to_review (move the card to in_review and record
# round 1 and pr; no dispatch; the next tick's review action starts the
# reviewer); a table skip stays a skip; any other action becomes skip, with
# reason "<action> waits for the next tick". A settle plan always has
# dispatchable false. A plan without --settle never emits move_to_review.
# --settle-merge is --settle that also keeps a merge action (merge-reviewed.sh
# carries it out; settle.sh never asks for it).
# A card whose lookup fails is skipped with a warning, as in a normal plan.
# Exit 2 when --settle has no card or a non-numeric card.
#
# Pending follow-ups (note.pending_followups) hold a card in file_pending only
# when a PR is known to file them against: pending_followups.pr, else note.pr,
# else the PR this plan found. Without one, the card goes through the table as
# usual and the plan warns "pending follow-ups on #<n> wait for a PR".
# Action failures: note.action_failures is the number of the manager's
# actions on the card, in a row, that failed to make progress, as the
# manager records them: any action (start, continue_implementor,
# start_review, review, review_stage, advance_stage, fix, mark_ready, merge, verify_main, to_human_qa,
# file_pending, block, unblock, finish, skip_no_acceptance, skip_card_lint) whose intended
# board or note change did not happen, for any reason (a failed setup step,
# a report rejected twice, a failed gh, board or script call, a refused
# merge); an action that made progress resets it to 0. This script only
# reads the count. Below, k is note.action_failures, max is
# review.max_rounds and <error> is note.last_action_error, or
# "no error recorded" when it is null:
#   ready, in_progress, in_review, a stage column, max <= k < 2*max: block, with reason
#     "no progress after <k> attempts: <error>", whatever action the table
#     would give. A block that fails is counted too, so k keeps rising while
#     the card stays in its column.
#   ready, in_progress, in_review, a stage column, k >= 2*max: skip, with reason
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
# An in_review (or stage column) card with no known PR is skipped with the warning
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
# (prev_sha is last_review.sha, or base when there is no previous review).
# This comes before the max_rounds block.
# A note's accepted entry (accept.sh) moved last_review.sha to the accepted
# head, so commits before it are not flagged and later ones are. It counts only
# when accepted.login is the authenticated gh login; otherwise a current review
# with Critical or Important findings plans review ("accept by <login> is not
# honored ...") instead of fix.
# Review drift warnings, for an open in_review (or stage column) PR whose head moved past
# last_review.sha (gh api compare, then each own commit of the PR, i.e. the
# first-parent chain from the head): "#<n>: unreviewed_merge: ..." when that
# chain holds a merge of main, and "#<n>: test_edit_after_review: ..." when one
# of its non-merge commits touches a file matching test_paths. Best effort: a
# failed lookup adds no warning and never skips the card or changes its action.
# A note worktree outside the current base (note.sh reads it as null) adds
# note.sh's warning to the plan's warnings:
# "manager note on #<n> names a worktree outside <base>; treating it as null: <path>".
#
# Rate limit failures: when the script fails and its stderr names a GitHub rate
# limit, it asks gh api rate_limit for the reset time and adds the line
# "resets at <ISO UTC>" (e.g. 2026-01-01T00:00:00Z) to stderr, which
# fleet-board-run.sh waits out. If that query fails, nothing is added. A
# failure that is not a rate limit never gets the line.
#
# Exit codes:
#   0 - plan printed
#   1 - a column could not be listed, or the plan could not be built
#   2 - usage error

set -uo pipefail
unset CDPATH # a relative cd must not follow CDPATH (it would also echo the path)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

SETTLE=false
SETTLE_NUMS=""
KEEP_MERGE=false
if [ $# -gt 0 ]; then
  case "$1" in
    --settle) ;;
    --settle-merge) KEEP_MERGE=true ;; # merge-reviewed.sh: settle mode that also keeps merge
    *) fb_die 2 "usage: tick-plan.sh [--settle|--settle-merge <n>...]" ;;
  esac
  shift
  [ $# -gt 0 ] || fb_die 2 "usage: tick-plan.sh --settle <n>... (at least one card)"
  for a in "$@"; do
    fb_valid_number "$a" || fb_die 2 "card number must be numeric, got: $a"
    case " $SETTLE_NUMS " in *" $a "*) ;; *) SETTLE_NUMS="$SETTLE_NUMS $a" ;; esac
  done
  SETTLE=true
fi

# stderr goes to a file so a rate-limit failure can be recognised at exit
ERR_FILE="$(mktemp)" || fb_die 1 "cannot create a temp file"
exec 3>&2 2>"$ERR_FILE"
finish() {
  local rc=$? reset
  exec 2>&3
  cat "$ERR_FILE" >&2
  if [ "$rc" -ne 0 ] && grep -qi 'rate limit' "$ERR_FILE"; then
    reset="$(gh api rate_limit 2>/dev/null | jq -r '.resources.core.reset | if type == "number" then todate else empty end' 2>/dev/null)" || reset=""
    case "$reset" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) printf 'resets at %s\n' "$reset" >&2 ;;
    esac
  fi
  rm -f "$ERR_FILE" "${CARDS_FILE:-}" "${NOTE_ERR:-}" "${DEPS_FILE:-}" "${LINT_FILE:-}"
  exit "$rc"
}
trap finish EXIT

fb_load_config

WT_DIR="$FLEET_ROOT/$(fb_cfg worktrees.dir)"
BASE="$(mkdir -p "$WT_DIR" && cd "$WT_DIR" && pwd -P)" || fb_die 1 "cannot resolve the worktrees directory $WT_DIR"
[ -n "$BASE" ] || fb_die 1 "cannot resolve the worktrees directory $WT_DIR"

TEST_GLOBS="$(jq -r '.test_paths[]' <<<"$FLEET_CFG")" || fb_die 1 "cannot read test_paths"

SKIP_MARKER='<!-- fleet-board:skip-no-acceptance -->'

CARDS_FILE="$(mktemp)" || fb_die 1 "cannot create a temp file"
NOTE_ERR="$(mktemp)" || { rm -f "$CARDS_FILE"; fb_die 1 "cannot create a temp file"; }
DEPS_FILE="$(mktemp)" || { rm -f "$CARDS_FILE" "$NOTE_ERR"; fb_die 1 "cannot create a temp file"; }
LINT_FILE="$(mktemp)" || { rm -f "$CARDS_FILE" "$NOTE_ERR" "$DEPS_FILE"; fb_die 1 "cannot create a temp file"; }

# is_test_path <path>: true when the path matches a test_paths glob (same glob
# rule as needs-human-qa.sh: ** becomes *, and a leading **/ is optional)
is_test_path() {
  local path="$1" glob pat
  while IFS= read -r glob; do
    [ -n "$glob" ] || continue
    pat="${glob//\*\*/*}"
    # shellcheck disable=SC2254 # the glob is a pattern on purpose
    case "$path" in $pat) return 0 ;; esac
    case "$glob" in
      '**/'*)
        pat="${glob#\*\*/}"
        pat="${pat//\*\*/*}"
        # shellcheck disable=SC2254
        case "$path" in $pat) return 0 ;; esac
        ;;
    esac
  done <<<"$TEST_GLOBS"
  return 1
}

# drift_lookup <note-json> <pr-info-json>: prints {merge, test_edit, from} for
# the PR's own commits (the first-parent chain from the head, so commits that
# arrived through a merge of main are not the PR's) made after last_review.sha.
# Prints null when there is no reviewed sha, the head has not moved, or a
# lookup fails.
drift_lookup() {
  local from head cmp chain sha files f merge=false tedit=false unrev=true verdict
  from="$(jq -r '.last_review.sha // empty | strings' <<<"$1" 2>/dev/null)" || return 1
  head="$(jq -r '.headRefOid // empty | strings' <<<"$2" 2>/dev/null)" || return 1
  [ -n "$from" ] && [ -n "$head" ] || { echo null; return 0; }
  case "$head" in "$from"*) echo null; return 0 ;; esac
  case "$from" in "$head"*) echo null; return 0 ;; esac
  [ "$(jq -r '.state' <<<"$2")" = OPEN ] || { echo null; return 0; }
  cmp="$(gh api "repos/$FLEET_REPO/compare/$from...$head")" || return 1
  chain="$(jq -r --arg head "$head" '
    (.commits | map({key: .sha, value: .}) | from_entries) as $by
    | def walk_chain($sha): if $by[$sha] == null then empty
        else $by[$sha] as $c | $c, ($c.parents[0].sha // empty | walk_chain(.)) end;
    [walk_chain($head)] | .[]
    | "\(.sha)\t\(.parents | length)\t\(.commit.message | split("\n")[0])"' <<<"$cmp" 2>/dev/null)" || return 1
  while IFS="$(printf '\t')" read -r sha parents subject; do
    [ -n "$sha" ] || continue
    if [ "$parents" -gt 1 ]; then
      case "$subject" in
        *[Mm]erge*main*) merge=true ;;
      esac
    else
      # A commit whose files cannot be read is left out of the test-edit check
      files="$(gh api "repos/$FLEET_REPO/commits/$sha" 2>/dev/null | jq -r '.files[].filename' 2>/dev/null)" || continue
      while IFS= read -r f; do
        [ -n "$f" ] && is_test_path "$f" && tedit=true
      done <<<"$files"
    fi
  done <<<"$chain"
  # Reviewed unless a commit since is something other than a clean merge of main
  # (review-drift.sh); a failed check reads as unreviewed
  verdict="$(bash "$FLEET_SCRIPTS/review-drift.sh" "$from" "$head" 2>/dev/null)" || verdict=unreviewed
  [ "$verdict" = reviewed ] && unrev=false
  jq -cn --argjson m "$merge" --argjson t "$tedit" --argjson u "$unrev" --arg from "$from" --arg head "$head" \
    '{merge: $m, test_edit: $t, unreviewed: $u, from: $from, head: $head}'
}

# card_input <state> <n> <title-json>: prints one JSON object holding every
# input the decision needs. The first failed lookup is recorded in
# lookup_failed and no further lookups are made for the card.
card_input() {
  local st="$1" n="$2" title="$3"
  local failed="" read="" note='{}' has_acc=false marker=false pr=null info=null invalid="" outside="" mergeable=null
  local blocking_merged=null nhq=null body branch bpr out cmd found labels
  local deps_unmet='[]' deps_warn='[]' refs checked has_deps accepted_mine=null me
  local drift=null
  local lint='[]' lint_gate=false lint_marker=null lint_commented=false lint_out lint_rc digest
  local stage=null next_stage=null nxt done_stages review_col=false

  # A review column: in_review, or the column of a configured review stage
  # (a review_<name> state whose stage is not configured stays unplanned)
  if [ "$st" = in_review ]; then
    review_col=true
  else
    case "$st" in
      review_*)
        stage="$(fb_stage_of_state "$st")" || stage=""
        if [ -n "$stage" ]; then review_col=true; else stage=null; fi ;;
    esac
  fi

  if [ "${4:-}" = FAILED ]; then
    failed="board-read.sh $n"
  elif [ -n "${4:-}" ]; then
    read="$4"
  else
    read="$(bash "$FLEET_SCRIPTS/board-read.sh" "$n")" || failed="board-read.sh $n"
  fi
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
  if [ -z "$failed" ] && [ -z "$invalid" ] && { [ "$st" = in_progress ] || [ "$review_col" = true ]; }; then
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
    # Mergeable state of an open PR (best effort: unknown on any failure)
    if [ -z "$failed" ] && [ "$info" != null ] && [ "$(jq -r '.state' <<<"$info")" = OPEN ]; then
      mergeable="$(gh pr view "$pr" --repo "$FLEET_REPO" --json mergeable 2>/dev/null \
        | jq -c 'if (.mergeable | type) == "string" then .mergeable else null end' 2>/dev/null)" || mergeable=null
      [ -n "$mergeable" ] || mergeable=null
    fi
    # The next stage and the human-QA question matter only for a clean review
    # of the current round (and of this column's stage; an advisory stage's
    # findings count as clean). The next stage comes first: needs-human-qa.sh
    # runs only when there is none.
    if [ -z "$failed" ] && [ "$review_col" = true ] && [ "$info" != null ] \
       && [ "$(jq -r '.state' <<<"$info")" = OPEN ] \
       && [ "$(jq -r --argjson stage "$stage" '(.last_review // null) as $lr | $lr != null and (($lr.round // 0) >= (.round // 0))
                        and (($lr.stage // null) == ($stage.name // null))
                        and ($stage.advisory == true or ((($lr.critical // 0) + ($lr.important // 0)) == 0))' <<<"$note")" = true ]; then
      labels="$(jq -c '[(.labels // [])[] | strings]' <<<"$read" 2>/dev/null)" || labels='[]'
      done_stages="$(jq -c '[(.reviewed_stages // [])[] | strings]' <<<"$note" 2>/dev/null)" || done_stages='[]'
      if nxt="$(bash "$FLEET_SCRIPTS/review-stages.sh" next --labels "$labels" --after "$st" --done "$done_stages" "$n")"; then
        if [ -n "$nxt" ]; then
          if [ "$(jq -r --arg s "$nxt" 'any((.review.stages // [])[]; .name == $s)' <<<"$FLEET_CFG")" = true ]; then
            next_stage="$(jq -cn --arg s "$nxt" '$s')"
          else
            failed="review-stages.sh next $n (unexpected answer)"
          fi
        fi
      else
        failed="review-stages.sh next $n"
      fi
      if [ -z "$failed" ] && [ "$next_stage" = null ]; then
        nhq="$(bash "$FLEET_SCRIPTS/needs-human-qa.sh" --labels "$labels" "$n" "$pr")" || { nhq=null; failed="needs-human-qa.sh $n $pr"; }
        case "$nhq" in
          true|false|null) ;;
          *) nhq=null; failed="needs-human-qa.sh $n $pr (unexpected answer)" ;;
        esac
      fi
    fi
  fi

  # Review drift: commits on the PR since the last reviewed sha. Best effort: a
  # lookup that fails adds no warning and never skips the card.
  if [ -z "$failed" ] && [ -z "$invalid" ] && [ "$review_col" = true ] && [ "$info" != null ]; then
    drift="$(drift_lookup "$note" "$info")" || drift=null
  fi

  # An accepted entry (accept.sh) counts only when its login is the authenticated one
  if [ -z "$failed" ] && [ -z "$invalid" ] && [ "$(jq -r '.accepted != null' <<<"$note")" = true ]; then
    if me="$(fb_login 2>/dev/null)"; then
      accepted_mine="$(jq --arg me "$me" '.accepted.login == $me' <<<"$note")"
    else
      failed="gh api user"
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

  # A ready card's lint (card-lint.sh on the body already read). A failing lint
  # gates the card when it has the Acceptance heading, or when the body shows
  # "**Acceptance**" / "Acceptance:" without it; a body with no hint at all
  # stays skip_no_acceptance. The marker names the lint result, so the manager
  # comments once per distinct result (compared with the latest posted lint comment only).
  if [ -z "$failed" ] && [ -z "$invalid" ] && [ "$st" = ready ]; then
    if printf '%s\n' "$body" > "$LINT_FILE"; then
      lint_out="$(bash "$FLEET_SCRIPTS/card-lint.sh" --body-file "$LINT_FILE")"; lint_rc=$?
      case "$lint_rc" in
        0) ;;
        1)
          lint="$(jq -Rn '[inputs]' <<<"$lint_out")" || { lint='[]'; failed="card-lint.sh $n (unparsable)"; }
          if [ "$has_acc" = true ] || [ "$(jq -r 'any(.[]; startswith("no-heading: found "))' <<<"$lint")" = true ]; then
            lint_gate=true
            digest="$(printf '%s\n' "$lint_out" | cksum | cut -d' ' -f1)"
            lint_marker="\"<!-- fleet-board:card-lint:$digest -->\""
            lint_commented="$(jq --argjson m "$lint_marker" '[(.comments // [])[] | (.body // "") | select(contains("<!-- fleet-board:card-lint:"))] | (last // "") | contains($m)' <<<"$read" 2>/dev/null)" \
              || failed="board-read.sh $n (unparsable comments)"
          else
            lint='[]'
          fi ;;
        *) failed="card-lint.sh $n" ;;
      esac
    else
      failed="card-lint.sh $n (cannot write the card body)"
    fi
  fi

  # A ready card's dependencies (only a card that could start is looked up)
  # (grep reads the file, not a pipe: grep -q quits at its first match, and a
  # body bigger than the pipe buffer would kill the writer and skip the gate)
  has_deps=1
  if [ -z "$failed" ] && [ -z "$invalid" ] && [ "$st" = ready ] && [ "$has_acc" = true ] && [ "$lint_gate" = false ]; then
    # grep exits 1 on no match and 2 on an error: only 1 means "no Depends on"
    if printf '%s\n' "$body" > "$DEPS_FILE"; then
      grep -Eiq '^##[[:space:]]+depends[[:space:]]+on[[:space:]]*$' "$DEPS_FILE"; has_deps=$?
    else
      has_deps=2
    fi
    [ "$has_deps" -le 1 ] || failed="deps.sh parse $n (cannot read the card body)"
  fi
  if [ -z "$failed" ] && [ "$has_deps" -eq 0 ]; then
    if out="$(bash "$FLEET_SCRIPTS/deps.sh" parse "$DEPS_FILE")" \
       && refs="$(jq -c '.refs' <<<"$out" 2>/dev/null)" \
       && deps_warn="$(jq -c --argjson n "$n" '[.warnings[] | "#\($n): \(.)"]' <<<"$out" 2>/dev/null)"; then
      if [ "$refs" != '[]' ]; then
        if checked="$(bash "$FLEET_SCRIPTS/deps.sh" check "$n" "$refs" 2>"$NOTE_ERR")" \
           && deps_unmet="$(jq -c '.unmet' <<<"$checked" 2>/dev/null)" \
           && out="$(jq -c '.warnings' <<<"$checked" 2>/dev/null)" \
           && deps_warn="$(jq -c --argjson w "$out" '. + $w' <<<"$deps_warn" 2>/dev/null)"; then
          :
        else
          failed="$(sed -n 's/^deps-lookup-failed: //p' "$NOTE_ERR" | head -1)"
          [ -n "$failed" ] || failed="deps.sh check $n"
          deps_unmet='[]'; deps_warn='[]'
        fi
      fi
    else
      failed="deps.sh parse $n"; deps_warn='[]'
    fi
  fi

  jq -cn --arg st "$st" --argjson n "$n" --argjson title "$title" --arg failed "$failed" --arg invalid "$invalid" \
    --arg outside "$outside" --argjson deps_unmet "$deps_unmet" --argjson deps_warn "$deps_warn" \
    --argjson has_acc "$has_acc" --argjson lint "$lint" --argjson lint_gate "$lint_gate" --argjson lint_commented "$lint_commented" --argjson lint_marker "$lint_marker" --argjson marker "$marker" --argjson note "$note" \
    --argjson pr "$pr" --argjson info "$info" --argjson mergeable "$mergeable" --argjson bm "$blocking_merged" --argjson amine "$accepted_mine" --argjson nhq "$nhq" --argjson drift "$drift" \
    --argjson stage "$stage" --argjson next_stage "$next_stage" \
    '{number: $n, title: $title, state: $st,
      lookup_failed: (if $failed == "" then null else $failed end),
      invalid_note: (if $invalid == "" then null else $invalid end),
      outside_warning: (if $outside == "" then null else $outside end),
      deps_unmet: $deps_unmet, deps_warnings: $deps_warn,
      has_acceptance: $has_acc, lint: $lint, lint_gate: $lint_gate, lint_marker: $lint_marker,
      lint_commented: $lint_commented,
      skip_marker: $marker, note: $note, pr: $pr,
      pr_info: $info, mergeable: $mergeable, accepted_mine: $amine, blocking_merged: $bm, needs_human_qa: $nhq, drift: $drift,
      stage: $stage, next_stage: $next_stage}'
}

if [ "$SETTLE" = true ]; then
  for n in $SETTLE_NUMS; do
    if READ="$(bash "$FLEET_SCRIPTS/board-read.sh" "$n")" \
       && ST="$(jq -r '.state // "none"' <<<"$READ" 2>/dev/null)" \
       && TITLE="$(jq -c '.title // ""' <<<"$READ" 2>/dev/null)"; then
      card_input "$ST" "$n" "$TITLE" "$READ" >> "$CARDS_FILE" || fb_die 1 "cannot build the plan input for card #$n"
    else
      card_input none "$n" '""' FAILED >> "$CARDS_FILE" || fb_die 1 "cannot build the plan input for card #$n"
    fi
  done
fi

SEEN=" "
for st in $([ "$SETTLE" = true ] || echo ready in_progress in_review $(fb_stage_states) blocked); do
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

# Provider stages whose API key variable is unset or empty (checked here, so
# jq never reads the environment); a provider with a null api_key_env is skipped
UNSET='[]'
while IFS="$(printf '\t')" read -r sname kenv; do
  [ -n "$sname" ] || continue
  case "$kenv" in ''|*[!A-Z0-9_]*|[0-9]*) continue ;; esac
  [ -n "${!kenv:-}" ] && continue
  UNSET="$(jq -c --arg s "$sname" '. + [$s]' <<<"$UNSET")" || fb_die 1 "cannot build the tick plan"
done <<<"$(jq -r '. as $c | (.review.stages // [])[] | select(.provider != null)
  | ($c.providers[.provider].api_key_env // empty) as $k | "\(.name)\t\($k)"' <<<"$FLEET_CFG")"

jq -s -c --argjson settle "$SETTLE" --argjson keepmerge "$KEEP_MERGE" --argjson cfg "$FLEET_CFG" --arg base "$BASE" --arg note_sh "$FLEET_SCRIPTS/note.sh" --argjson unset "$UNSET" '
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
  # A review column: in_review, or the column of a configured stage ($c.stage set)
  def is_review($c): $c.state == "in_review" or $c.stage != null;
  def reset_cmd($n): "bash \($note_sh | if test("\\A[A-Za-z0-9/._+:@-]+\\z") then . else @sh end) reset-failures \($n)";

  $cfg.review.max_rounds as $max
  | $cfg.models as $m

  # The action table (AC1). $c is the card input, $n its note.
  | def decide($c; $n; $round):
      ($n.last_review) as $lr
      | ((($lr.critical // 0) + ($lr.important // 0))) as $ci
      # A stage column: its own max_rounds; an advisory stage findings count
      # as clean; its reviews are review_stage
      | ($c.stage.max_rounds // $max) as $smax
      | (if $c.stage.advisory == true then 0 else $ci end) as $ci_eff
      | (if $c.stage != null then "review_stage" else "review" end) as $ra
      | ($n.implementor_attempts // 0) as $tries
      | ($n.action_failures // 0) as $fails
      | ($n.last_action_error // "no error recorded") as $err
      | if $c.lookup_failed != null then act("skip"; "lookup failed: \($c.lookup_failed)")
        elif $c.invalid_note != null then act("skip"; "invalid manager note: \($c.invalid_note)")
        elif $n.pending_followups != null and ($n.pending_followups.pr // $n.pr // $c.pr) != null
          then act("file_pending"; "pending follow-ups")
        elif ($c.state == "ready" or $c.state == "in_progress" or is_review($c))
             and $fails >= 2 * $max
          then act("skip"; "could not be blocked after \($fails) attempts: \($err)")
        elif ($c.state == "ready" or $c.state == "in_progress" or is_review($c))
             and $fails >= $max
          then act("block"; "no progress after \($fails) attempts: \($err)")
        elif $c.state == "blocked" and $n.blocking_pr != null and $c.blocking_merged == true and $fails >= $max
          then act("skip"; "unblock made no progress after \($fails) attempts: \($err)")
        elif $c.state == "ready" and $c.lint_gate
          then act("skip_card_lint"; "card lint failed: \([$c.lint[] | split(":")[0]] | unique | join(", "))")
        elif $c.state == "ready" then
          if $c.has_acceptance then
            if ($c.deps_unmet | length) > 0
            then act("wait"; "waits for \([$c.deps_unmet[] | "\(.ref) (\(.status))"] | join(", "))")
            else act("start"; "ready, with an Acceptance section") end
          else act("skip_no_acceptance"; "no ## Acceptance section") end
        elif ($c.state == "in_progress" or is_review($c)) and $c.pr != null
             and ($c.pr_info.state // null) == "OPEN" and $c.mergeable == "CONFLICTING"
          then act("update_branch"; "PR #\($c.pr) has merge conflicts with its base branch")
        elif $c.state == "in_progress" then
          if $c.pr != null then act("start_review"; "PR #\($c.pr) exists")
          elif $tries >= $max then act("block"; "implementor produced no PR after \($tries) attempts")
          else act("continue_implementor"; "no PR yet (\($tries) of \($max) implementor attempts)") end
        elif is_review($c) then
          if $c.pr == null or $c.pr_info == null then act("skip"; "in review, but no PR is known")
          elif $c.pr_info.state == "MERGED" then
            if $n.main_check == null then act("verify_main"; "PR #\($c.pr) merged; main not yet verified")
            else act("finish"; "PR #\($c.pr) merged and main verified") end
          elif $c.pr_info.state != "OPEN" then act("skip"; "PR #\($c.pr) is \($c.pr_info.state | ascii_downcase) without a merge")
          # A record from another stage (or from in_review) never counts
          elif $lr == null or ($lr.round // 0) < $round or ($lr.stage // null) != ($c.stage.name // null)
            then act($ra; if $c.stage != null then "round \($round) of \($c.stage.name) not reviewed yet" else "round \($round) not reviewed yet" end)
          # Commits landed after a review with findings (a fixer whose report
          # was never reconciled, or a person): review them; never fix again.
          # An accept by another login is not honored: its baseline is not trusted
          elif $ci_eff > 0 and $n.accepted != null and $c.accepted_mine == false
            then act($ra; "accept by \($n.accepted.login) is not honored (not the authenticated login); review PR head \($c.pr_info.headRefOid[0:7]) before fixing again")
          elif $ci_eff > 0 and head_moved($c; $lr)
            then act($ra; "PR head \($c.pr_info.headRefOid[0:7]) differs from the round \($round) review at \($lr.sha[0:7]); review the new commits before fixing again")
          # A clean review covers a later head only when every commit since is a
          # clean merge of main (review-drift.sh); a lookup that failed reads as not covered
          elif $ci_eff == 0 and head_moved($c; $lr) and ($c.drift == null or $c.drift.unreviewed)
            then act($ra; "PR head \($c.pr_info.headRefOid[0:7]) has commits after the round \($round) review at \($lr.sha[0:7]) that are not clean merges of the base; review them before merging")
          elif $ci_eff > 0 and $round >= $smax
            then act("block"; "\($ci) Critical/Important findings survive round \($round) of \($smax)\(if $c.stage != null then " in \($c.stage.name)" else "" end)")
          elif $ci_eff > 0 then act("fix"; "\($ci) Critical/Important findings in round \($round)")
          # Clean (or advisory) and current: a next stage comes before the tail
          elif $c.next_stage != null then act("advance_stage"; "review clean; next stage \($c.next_stage)")
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
    | decide($c; $n; $round) as $d0
    # Settle mode keeps only the steps that start no agent
    | (if $settle | not then $d0
       elif ($d0.action == "to_human_qa" or $d0.action == "advance_stage" or $d0.action == "block" or $d0.action == "mark_ready" or $d0.action == "skip" or ($keepmerge and $d0.action == "merge")) then $d0
       elif $d0.action == "start_review" then act("move_to_review"; "\($d0.reason); move to in_review without dispatching")
       else act("skip"; "\($d0.action) waits for the next tick") end) as $d
    | {number: $c.number, title: $c.title, state: $c.state, action: $d.action, reason: $d.reason,
       branch: ($n.branch // "fleet/\($c.number)-\($slug)"),
       worktree: ($n.worktree // "\($base)/\($c.number)-\($slug)"),
       pr: $c.pr, round: $n.round, models: $models, escalated: $esc,
       waiting_on: (if $c.state == "ready" and $d.action == "wait" then [$c.deps_unmet[].ref] else null end),
       needs_human_qa: (if is_review($c) then $c.needs_human_qa else null end),
       drift: ($c.drift // null),
       # advance_stage: the stage being entered; a stage column: its stage
       stage: (if $d.action == "advance_stage"
               then first($cfg.review.stages[] | select(.name == $c.next_stage))
               else ($c.stage // null) end),
       comment_needed: (if $d.action == "skip_no_acceptance" then ($c.skip_marker | not)
                        elif $d.action == "skip_card_lint" then ($c.lint_commented | not)
                        else null end),
       lint: (if $d.action == "skip_card_lint" then $c.lint else null end),
       lint_marker: (if $d.action == "skip_card_lint" then $c.lint_marker else null end),
       pending_wait: ($n.pending_followups != null and $d.action != "file_pending" and $c.lookup_failed == null),
       outside_warning: $c.outside_warning, deps_warnings: ($c.deps_warnings // [])}
  ] as $cards
  | {dispatchable: (($settle | not) and any($cards[];
        (.action != "skip" and .action != "wait" and .action != "file_pending" and .action != "skip_no_acceptance" and .action != "skip_card_lint")
        or ((.action == "skip_no_acceptance" or .action == "skip_card_lint") and .comment_needed == true))),
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
       + [$cards[] | select(.drift != null and .drift.merge) | "#\(.number): unreviewed_merge: PR head \(.drift.head[0:7]) contains a merge of main made after the last review at \(.drift.from[0:7])"]
       + [$cards[] | select(.drift != null and .drift.test_edit) | "#\(.number): test_edit_after_review: commits after the last review at \(.drift.from[0:7]) touch a test file"]
       + [$cards[] | select(.outside_warning != null) | .outside_warning]
       + [$cards[] | .deps_warnings[]]
       + [$cards[] | select(.pending_wait) | "pending follow-ups on #\(.number) wait for a PR"]
       # Once per provider stage acted on (review_stage or fix) whose key is unset
       + ([$cards[] | select((.action == "review_stage" or .action == "fix") and .stage != null
                             and (.stage.name as $s | any($unset[]; . == $s)))
           | "stage \(.stage.name): \($cfg.providers[.stage.provider].api_key_env) is not set; provider reviews will fail"]
          | reduce .[] as $w ([]; if any(.[]; . == $w) then . else . + [$w] end))),
     cards: [$cards[] | del(.pending_wait, .outside_warning, .deps_warnings, .drift)]}
' "$CARDS_FILE" || fb_die 1 "cannot build the tick plan"
