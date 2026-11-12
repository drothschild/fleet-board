#!/usr/bin/env bash
# tick-plan.sh - decides one step for every card on the board (the tick plan).
#
# Usage: tick-plan.sh                 (run inside the repo)
#        tick-plan.sh --candidates    (read-only eligibility snapshot for supervisor admission)
#        tick-plan.sh --settle-merge <n>... (settle mode for merge-reviewed.sh, below)
#
# Lists the ready, in_progress, in_review, review_<name> (one per configured
# review stage, in config order) and blocked columns, reads each card
# once (board-read.sh; the manager note is parsed from that read with
# note.sh parse), makes the PR lookups the decision needs, and prints:
#
#   {"dispatchable": bool, "warnings": [..], "cards": [
#     {"number", "title", "state", "action", "reason", "branch", "worktree", "pr",
#      "head_sha", "round", "models": {"implementor","reviewer","fixer"}, "escalated",
#      "needs_human_qa": bool|null, "stage": object|null,
#      "comment_needed": bool|null}]}
#
# stage is the config's stage object whole (as config.sh prints it: name,
# agent, provider, model, paths, label, advisory, max_rounds, brief,
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
# next stage is set plans advance_stage, reason
# "review clean; next stage <name>", before the human-QA tail; with no next
# stage the tail is unchanged. The next stage is the first stage in config
# order, other than the column's own, that is not in note.reviewed_stages and
# is routed: its label is on the card, or its paths match the PR's current
# files (review-stages.sh match; read-only, the plan adds no label). So a
# stage whose paths a later push touches cannot be skipped, even one before
# the current column; a label-only stage (empty paths) is skipped by removing
# its label. A card whose state names a stage that is
# not configured reads with no canonical state and gets skip ("state <state>
# is not planned"). For a provider stage whose providers.<name>.api_key_env is
# unset or empty, review_stage is planned as wait with the reason "stage <name>:
# <ENV> is not set" (stage-review.sh would exit 3 every tick), and the plan warns
# "stage <name>: <ENV> is not set; provider reviews will fail", once per stage,
# when a card in the plan has a held review_stage or fix in that stage, or
# advance_stage into it (the move is kept; the next tick's review_stage waits).
# fix is not held: the fixer still runs usefully. The check runs in bash, and jq
# never reads the environment.
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
#   review-stages.sh match <pr>
#       review column, when the PR is open and the review is clean and current
#       (last_review.round >= note.round, last_review.stage is the column's
#       stage, null in in_review, and no Critical or Important finding unless
#       the stage is advisory), and only when review.stages is not empty (with
#       no stages, no match, no next stage and no call); read-only, adds no
#       label; a failure is "review-stages.sh match <pr>"
#   review-stages.sh next --labels <labels> --after in_review --done <done> <n>
#       under the same condition, after match: <labels> is the card's labels
#       plus the label of every matched stage, so a file pushed after routing
#       (by a fixer, say) still routes the card; <done> is
#       note.reviewed_stages plus the column's own stage, and --after is always
#       in_review, so a stage before the current column that now matches and
#       was never visited is the next stage too. A failure is
#       "review-stages.sh next <n>"
#   needs-human-qa.sh --labels <card labels> <n> <pr>
#       review column, under the same condition, only when review-stages.sh
#       next printed nothing; otherwise needs_human_qa is null, since the
#       decision does not use it
#   gh pr view <blocking_pr> --json state,mergedAt
#       blocked, when note.blocking_pr is set
#   deps.sh parse-card / deps.sh check <n> <refs>
#       ready, with acceptance and a non-empty blocked_by: deps.sh check reads
#       each blocker's state from the local store (see deps.sh)
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
# Dependency gate: a ready card with acceptance criteria and any unmet
# dependency (its blocked_by field) gets action wait, with reason
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
# A conflict is aborted and recorded in the note (note.conflicted_files, every
# file, test files included): such a card plans fix instead, whatever the PR's
# mergeable state, and the card's "findings" are one {severity: "Important",
# text: "merge conflict in <file>"} per file (null on any other card). The fixer
# re-runs the merge and commits the resolution; the merge resets last_review, so
# the next tick plans review. action_failures bounds the loop, as for any action.
#
# Card lint: a ready card whose body fails card-lint.sh (and has the Acceptance
# heading, or a "**Acceptance**" / "Acceptance:" line in place of it) gets action
# skip_card_lint with reason "card lint failed: <rules>", the lint lines in
# "lint" and a "lint_marker" HTML comment naming the result. comment_needed is
# true until a comment holding that marker exists, so each distinct result is
# commented once. A body with no Acceptance hint stays skip_no_acceptance.
#
# Scope overlap: a ready card that would start waits (reason "Scope overlaps
# #<n> on <path>") when an in_progress, in_review or stage-column card names a path that its
# "## Scope" also names. Active PR paths supplement declared scope, and
# selected starts reserve their scopes in card-number order within the plan.
# Directory scopes cover descendants; incomplete PR file lookups hold starts.
# Paths are backticked spans in that section with no
# whitespace and a "/" or an extension; a card naming none starts as usual.
# At most one merge is planned per tick: the lowest card number; the other
# cards that would merge wait ("one merge per tick: #<n> merges first").
#
# The decision table itself is the single jq program below.
#
# Settle mode (--settle-merge <n>..., merge-reviewed.sh's planner): the same plan JSON for only the named cards,
# keeping only the steps that start no agent. Each card is read with
# board-read.sh (its column comes from that read); no column is listed. The
# table's result is filtered: to_human_qa, advance_stage, block and mark_ready stay;
# start_review becomes move_to_review (move the card to in_review and record
# round 1 and pr; no dispatch; the next tick's review action starts the
# reviewer); a table skip stays a skip; any other action becomes skip, with
# reason "<action> waits for the next tick". A settle plan always has
# dispatchable false. A plan without --settle-merge never emits move_to_review.
# Settle mode also keeps merge and verify_main actions (merge-reviewed.sh carries them out and
# ignores every other action). The by-hand --settle flag went with the by-hand settle script in 0.27.0.
# A card whose lookup fails is skipped with a warning, as in a normal plan.
# Exit 2 when --settle-merge has no card or a non-numeric card.
#
# Pending follow-ups (note.pending_followups) hold a card in file_pending only
# when a PR is known to file them against: pending_followups.pr, else note.pr,
# else the PR this plan found. Without one, the card goes through the table as
# usual and the plan warns "pending follow-ups on #<n> wait for a PR".
# Action failures: note.action_failures is the number of the manager's
# actions on the card, in a row, that failed to make progress, as the
# manager records them: any action (start, continue_implementor,
# start_review, review, review_stage, advance_stage, fix, mark_ready, merge, verify_main, to_human_qa,
# file_pending, block, unblock, finish, after_merge, merge_refusal, skip_no_acceptance, skip_card_lint) whose intended
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
# Re-review, not fix: a current review with Critical or Important findings, an
# unmoved head and either note.last_fix = {"status":"not_reproducible","round":<n>}
# for the current round (the fixer re-ran the finding and committed nothing) or
# note.state "blocked" on a card now in In review (a person moved it back) plans
# review. The manager records last_fix when it reconciles a fixer report and
# bumps round for the re-review, which ends the rule; its note upkeep sets
# state in_review, which ends the other.
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
# Preflight: when commands.preflight is set, it runs once before planning (not
# in settle mode). When it exits non-zero the plan holds every card (action
# wait, reason "preflight failed; ..."; a skip stays a skip), dispatchable is
# false, and the one warning "preflight failed: <command> (exit <n>)" followed
# by the last 20 lines of its output. No card's state or
# action_failures changes. A zero exit leaves the plan as if the key were unset.
#
# Rate limit failures: a card lookup (gh pr ...) that failed while gh named a
# GitHub rate limit fails the whole plan (exit 1, no plan printed), since every
# card's lookups would fail alike. When the script fails and its stderr names a
# GitHub rate limit, it asks gh api rate_limit for the reset time and adds the line
# "resets at <ISO UTC>" (e.g. 2026-01-01T00:00:00Z) to stderr, which
# the supervisor waits out. If that query fails, nothing is added. A
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
CANDIDATES=false
if [ $# -gt 0 ]; then
  case "$1" in
    --settle-merge) KEEP_MERGE=true ;; # merge-reviewed.sh: settle mode that also keeps merge
    --candidates) CANDIDATES=true ;;
    *) fb_die 2 "usage: tick-plan.sh [--candidates|--settle-merge <n>...]" ;;
  esac
  shift
  if [ "$CANDIDATES" = true ]; then
    [ $# -eq 0 ] || fb_die 2 "usage: tick-plan.sh --candidates (cannot combine with other modes)"
  else
    [ $# -gt 0 ] || fb_die 2 "usage: tick-plan.sh --settle-merge <n>... (at least one card)"
    for a in "$@"; do
      fb_valid_number "$a" || fb_die 2 "card number must be numeric, got: $a"
      case " $SETTLE_NUMS " in *" $a "*) ;; *) SETTLE_NUMS="$SETTLE_NUMS $a" ;; esac
    done
    SETTLE=true
  fi
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
  rm -f "$ERR_FILE" "${CARDS_FILE:-}" "${NOTE_ERR:-}" "${DEPS_FILE:-}" "${LINT_FILE:-}" "${SCOPE_FILE:-}"
  exit "$rc"
}
trap finish EXIT

fb_load_config

# No configured stage: no stage column and no review-stages.sh next lookup
HAS_STAGES=false
[ -n "$(fb_stage_states)" ] && HAS_STAGES=true

WT_DIR="$FLEET_ROOT/$(fb_cfg worktrees.dir)"
BASE="$(mkdir -p "$WT_DIR" && cd "$WT_DIR" && pwd -P)" || fb_die 1 "cannot resolve the worktrees directory $WT_DIR"
[ -n "$BASE" ] || fb_die 1 "cannot resolve the worktrees directory $WT_DIR"

# Preflight: commands.preflight runs once before planning (never in settle mode,
# which starts no agent). A non-zero exit holds every card and adds the one
# warning below; the plan changes no card's state or action_failures.
PREFLIGHT_WARNING=""
PRE_CMD="$(fb_cfg commands.preflight)"
if [ "$SETTLE" != true ] && [ -n "$PRE_CMD" ]; then
  PRE_OUT="$(cd "$FLEET_ROOT" && bash -c "$PRE_CMD" 2>&1 </dev/null)"
  PRE_RC=$?
  if [ "$PRE_RC" -ne 0 ]; then
    PREFLIGHT_WARNING="preflight failed: $PRE_CMD (exit $PRE_RC)
$(printf '%s\n' "$PRE_OUT" | tail -n 20)"
  fi
fi

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
  local blocking_merged=null nhq=null body branch bpr out cmd found labels card_labels='[]' state_revision=null
  local deps_unmet='[]' deps_warn='[]' refs checked has_deps accepted_mine=null me
  local drift=null scope='[]'
  local lint='[]' lint_gate=false lint_marker=null lint_commented=false lint_out lint_rc digest
  local stage=null next_stage=null nxt done_stages review_col=false matched next_labels routed_last=null

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
    if ! card_labels="$(jq -ce '(.labels // []) | if type == "array" and all(.[]; type == "string") then . else error("invalid labels") end' <<<"$read" 2>/dev/null)"; then
      card_labels='[]'
      failed="board-read.sh $n (malformed labels)"
    fi
    state_revision="$(jq -c '.revision // .updatedAt // null' <<<"$read" 2>/dev/null)" || state_revision=null
  fi
  if [ -z "$failed" ]; then
    fb_card_has_acceptance "$read" && has_acc=true
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
  if [ -z "$failed" ] && [ -z "$invalid" ] && { [ "$st" = in_progress ] || [ "$st" = merging ] || [ "$review_col" = true ] || { [ "$CANDIDATES" = true ] && [ "$st" = human_qa ]; }; }; then
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
      # With no stages configured there is no next stage, and no call. Else
      # the PR's current files are matched first (routing ran once, at the
      # move to in_review; a later push may touch a stage's paths), and every
      # stage before or after this column that is routed and not yet visited
      # counts.
      if [ "$HAS_STAGES" = false ]; then
        :
      elif ! matched="$(bash "$FLEET_SCRIPTS/review-stages.sh" match "$pr")"; then
        failed="review-stages.sh match $pr"
      elif ! next_labels="$(jq -c --argjson cfg "$FLEET_CFG" --argjson m "$matched" \
             '(. + [$cfg.review.stages[] | select(.name as $s | $m | index($s) != null) | .label]) | unique' <<<"$labels" 2>/dev/null)"; then
        failed="review-stages.sh match $pr (unexpected answer)"
      elif ! done_stages="$(jq -c --argjson stage "$stage" 'if $stage == null then . else . + [$stage.name] end' <<<"$done_stages")"; then
        failed="note.sh parse $n (unparsable)"
      elif nxt="$(bash "$FLEET_SCRIPTS/review-stages.sh" next --labels "$next_labels" --after in_review --done "$done_stages" "$n")"; then
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

  # A merging card (an open PR): stages are routed per card, so it merges only once no routed stage
  # remains (next_stage, computed as the review columns compute it, with --done = reviewed_stages plus
  # the last review's stage) and only on a review of its last routed or visited stage (routed_last; null
  # when it was routed to none). The human-QA question is asked for every such card, as the review row
  # asks it (a lookup failure: lookup_failed, so the card is skipped); the merge needs the answer false.
  if [ -z "$failed" ] && [ -z "$invalid" ] && [ "$st" = merging ] && [ "$info" != null ] \
     && [ "$(jq -r '.state' <<<"$info")" = OPEN ]; then
    labels="$(jq -c '[(.labels // [])[] | strings]' <<<"$read" 2>/dev/null)" || labels='[]'
    if [ "$HAS_STAGES" = true ] && [ "$(jq -r '.last_review != null' <<<"$note")" = true ]; then
      if ! done_stages="$(jq -c '[(.reviewed_stages // [])[] | strings] + [(.last_review.stage // empty) | strings] | unique' <<<"$note" 2>/dev/null)"; then
        failed="note.sh parse $n (unparsable)"
      elif ! matched="$(bash "$FLEET_SCRIPTS/review-stages.sh" match "$pr")"; then
        failed="review-stages.sh match $pr"
      elif ! next_labels="$(jq -c --argjson cfg "$FLEET_CFG" --argjson m "$matched" \
             '(. + [$cfg.review.stages[] | select(.name as $s | $m | index($s) != null) | .label]) | unique' <<<"$labels" 2>/dev/null)"; then
        failed="review-stages.sh match $pr (unexpected answer)"
      elif nxt="$(bash "$FLEET_SCRIPTS/review-stages.sh" next --labels "$next_labels" --after in_review --done "$done_stages" "$n")"; then
        if [ -n "$nxt" ]; then
          if [ "$(jq -r --arg s "$nxt" 'any((.review.stages // [])[]; .name == $s)' <<<"$FLEET_CFG")" = true ]; then
            next_stage="$(jq -cn --arg s "$nxt" '$s')"
          else
            failed="review-stages.sh next $n (unexpected answer)"
          fi
        fi
        [ -n "$failed" ] || routed_last="$(jq -cn --argjson cfg "$FLEET_CFG" --argjson l "$next_labels" --argjson d "$done_stages" \
          '[$cfg.review.stages[] | select(.label as $x | .name as $y | any($l[]; . == $x) or any($d[]; . == $y)) | .name] | last // null')" \
          || failed="review-stages.sh next $n (unexpected answer)"
      else
        failed="review-stages.sh next $n"
      fi
    fi
    if [ -z "$failed" ]; then
      nhq="$(bash "$FLEET_SCRIPTS/needs-human-qa.sh" --labels "$labels" "$n" "$pr")" || { nhq=null; failed="needs-human-qa.sh $n $pr"; }
      case "$nhq" in
        true|false|null) ;;
        *) nhq=null; failed="needs-human-qa.sh $n $pr (unexpected answer)" ;;
      esac
    fi
  fi

  # Review drift: commits on the PR since the last reviewed sha. Best effort: a
  # lookup that fails adds no warning and never skips the card.
  if [ -z "$failed" ] && [ -z "$invalid" ] && { [ "$review_col" = true ] || [ "$st" = merging ]; } && [ "$info" != null ]; then
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
    # the card read is linted on its acceptance field
    if printf '%s\n' "$read" > "$LINT_FILE"; then
      lint_out="$(bash "$FLEET_SCRIPTS/card-lint.sh" --read-file "$LINT_FILE")"; lint_rc=$?
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

  # Backticked file paths in the body's "## Scope" section: a span with no
  # whitespace that holds a "/" or ends in an extension
  if [ -z "$failed" ]; then
    scope="$(jq -cn --arg b "$body" '
      $b | split("\n") | reduce .[] as $l ({in: false, paths: []};
        if ($l | test("^##[ \t]+Scope[ \t]*$")) then .in = true
        elif ($l | test("^##[ \t]")) then .in = false
        elif .in then .paths += [$l | scan("`([^`]+)`") | .[0]
              | select(test("^[^ \t]+$") and (test("/") or test("[.][A-Za-z0-9]+$")))]
        else . end)
      | .paths | unique' 2>/dev/null)" || scope='[]'
  fi

  # A ready card's dependencies, its blocked_by field (only a card that could
  # start is looked up)
  has_deps=1; deps_cmd=parse-card
  if [ -z "$failed" ] && [ -z "$invalid" ] && [ "$st" = ready ] && [ "$has_acc" = true ] && [ "$lint_gate" = false ]; then
    if printf '%s\n' "$read" > "$DEPS_FILE"; then has_deps=0; else has_deps=2; fi
    [ "$has_deps" -le 1 ] || failed="deps.sh parse-card $n (cannot write the card)"
  fi
  if [ -z "$failed" ] && [ "$has_deps" -eq 0 ]; then
    if out="$(bash "$FLEET_SCRIPTS/deps.sh" "$deps_cmd" "$DEPS_FILE")" \
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
      failed="deps.sh parse-card $n"; deps_warn='[]'
    fi
  fi

  jq -cn --arg st "$st" --argjson n "$n" --argjson title "$title" --argjson card_labels "$card_labels" --argjson state_revision "$state_revision" --arg failed "$failed" --arg invalid "$invalid" \
    --arg outside "$outside" --argjson deps_unmet "$deps_unmet" --argjson deps_warn "$deps_warn" \
    --argjson has_acc "$has_acc" --argjson lint "$lint" --argjson lint_gate "$lint_gate" --argjson lint_commented "$lint_commented" --argjson lint_marker "$lint_marker" --argjson marker "$marker" --argjson note "$note" \
    --argjson pr "$pr" --argjson info "$info" --argjson mergeable "$mergeable" --argjson bm "$blocking_merged" --argjson amine "$accepted_mine" --argjson nhq "$nhq" --argjson drift "$drift" --argjson scope "$scope" \
    --argjson stage "$stage" --argjson next_stage "$next_stage" --argjson routed_last "$routed_last" \
    '{number: $n, title: $title, state: $st, labels: $card_labels, state_revision:$state_revision,
      lookup_failed: (if $failed == "" then null else $failed end),
      invalid_note: (if $invalid == "" then null else $invalid end),
      outside_warning: (if $outside == "" then null else $outside end),
      deps_unmet: $deps_unmet, deps_warnings: $deps_warn,
      has_acceptance: $has_acc, lint: $lint, lint_gate: $lint_gate, lint_marker: $lint_marker,
      lint_commented: $lint_commented,
      skip_marker: $marker, note: $note, pr: $pr,
      pr_info: $info, mergeable: $mergeable, accepted_mine: $amine, blocking_merged: $bm, needs_human_qa: $nhq, drift: $drift, scope_paths: $scope,
      stage: $stage, next_stage: $next_stage, routed_last_stage: $routed_last}'
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
for st in $([ "$SETTLE" = true ] || echo ready in_progress in_review $(fb_stage_states) merging blocked $([ "$CANDIDATES" = true ] && echo human_qa)); do
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

# A lookup that failed on a GitHub rate limit fails the plan, so the wrapper
# waits out the reset (finish adds "resets at") instead of skipping the cards
if grep -qi 'rate limit' "$ERR_FILE" && jq -se 'any(.[]; .lookup_failed != null)' "$CARDS_FILE" >/dev/null 2>&1; then
  fb_die 1 "a GitHub lookup hit a rate limit; no plan printed"
fi

# Actual PR paths supplement declared scope only when admitting new work.
# Reuse the normal card snapshot; settle-only calls never need these lookups.
SCOPE_FILE="$(mktemp)" || fb_die 1 "cannot create scope input"
if [ "$SETTLE" != true ] && { [ "$CANDIDATES" = true ] || jq -es 'any(.[]; .state == "ready")' "$CARDS_FILE" >/dev/null; }; then
  while IFS= read -r active; do
    [ -n "$active" ] || continue
    n="$(jq -r '.number' <<<"$active")"
    pr="$(jq -r '.pr // empty' <<<"$active")"
    paths='[]'
    unknown=false
    if jq -e '.lookup_failed != null or .invalid_note != null' <<<"$active" >/dev/null; then
      unknown=true
    elif [ -n "$pr" ] && [ "$(jq -r '.pr_info.state' <<<"$active")" = OPEN ]; then
      if files="$(gh pr view "$pr" --repo "$FLEET_REPO" --json files,changedFiles)" \
        && paths="$(jq -ce 'if (.files | type) == "array" and (.changedFiles | type) == "number"
            and .changedFiles == (.files | length)
            and all(.files[]; (.path | type) == "string" and (.path | length) > 0)
            then [.files[].path] else error("incomplete file list") end' <<<"$files" 2>/dev/null)"; then
        :
      else
        paths='[]'; unknown=true
      fi
    fi
    jq -cn --argjson n "$n" --argjson paths "$paths" --argjson unknown "$unknown" \
      '{number:$n, paths:$paths, unknown:$unknown}' >> "$SCOPE_FILE" || fb_die 1 "cannot record scope input"
  done <<<"$(jq -c 'select(.state == "in_progress" or .state == "in_review" or .state == "merging" or .state == "human_qa" or .stage != null)' "$CARDS_FILE")"
fi

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

# merge.ignore_checks is judged against today (UTC; FLEET_BOARD_TODAY overrides it for tests)
TODAY="${FLEET_BOARD_TODAY:-$(date -u +%Y-%m-%d)}"
IGNORE_CHECKS_JQ="$(cat "$FLEET_SCRIPTS/ignore-checks.jq")" || fb_die 1 "cannot read ignore-checks.jq"

jq -s -c --slurpfile actual_scope "$SCOPE_FILE" --argjson settle "$SETTLE" --argjson candidates "$CANDIDATES" --argjson keepmerge "$KEEP_MERGE" --argjson cfg "$FLEET_CFG" --arg base "$BASE" --arg pre "$PREFLIGHT_WARNING" --arg note_sh "$FLEET_SCRIPTS/note.sh" --argjson unset "$UNSET" --arg today "$TODAY" "$IGNORE_CHECKS_JQ"'
  # One shared rule (ignore-checks.jq) for every merge decision: the review rows and the merging row
  def green: .statusCheckRollup | ic_green($cfg.merge.ignore_checks; $today);
  def scope_key: sub("^(\\./)+"; "") | sub("/+$"; "");
  def overlap($left; $right):
    first($left[] as $a | $right[] as $b
      | ($a | scope_key) as $x | ($b | scope_key) as $y
      | select($x == "" or $y == "" or $x == $y or ($x | startswith($y + "/")) or ($y | startswith($x + "/")))
      | $a) // null;
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
  # merging (merge.policy auto only): the card is past review, its PR is being merged
  def is_merging($c): $c.state == "merging";
  # The status the merger recorded for this PR head in mode $mode (after_merge or refusal), else null
  def merger_for($c; $n; $mode):
    ($n.merger // null) as $mg
    | if ($mg | type) == "object" and $mg.mode == $mode and ($mg.head | type) == "string"
         and (head_moved($c; {sha: $mg.head}) | not) then $mg.status else null end;
  # The conflicted files update-branch.sh recorded in the note (strings only)
  def conflict_files($n): [($n.conflicted_files // [])[]? | strings | select(. != "")];
  def reset_cmd($n): "bash \($note_sh | if test("\\A[A-Za-z0-9/._+:@-]+\\z") then . else @sh end) reset-failures \($n)";

  $cfg.review.max_rounds as $max
  | $cfg.models as $m
  | ($m.reviewer | if type == "object" then .model else . end) as $reviewer_model

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
        # Never let failure limits or follow-ups move an unverified merge out
        # of review, where the headless recovery pass can still find it.
        elif (is_review($c) or is_merging($c)) and $c.pr_info.state == "MERGED" and $n.main_check.ok != true
          then act("verify_main"; "PR #\($c.pr) merged; successful main verification required")
        elif $n.pending_followups != null and ($n.pending_followups.pr // $n.pr // $c.pr) != null
          then act("file_pending"; "pending follow-ups")
        elif ($c.state == "ready" or $c.state == "in_progress" or is_review($c) or is_merging($c))
             and $fails >= 2 * $max
          then act("skip"; "could not be blocked after \($fails) attempts: \($err)")
        elif ($c.state == "ready" or $c.state == "in_progress" or is_review($c) or is_merging($c))
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
            else act("start"; "ready, with acceptance criteria") end
          else act("skip_no_acceptance"; "no acceptance criteria") end
        # update-branch.sh recorded the files of an aborted conflicting merge: the
        # fixer resolves them (test files included), so update_branch is not
        # planned again while the PR still reads CONFLICTING
        elif ($c.state == "in_progress" or is_review($c)) and $c.pr != null
             and ($c.pr_info.state // null) == "OPEN" and conflict_files($n) != []
          then act("fix"; "merge conflicts in \(conflict_files($n) | length) file(s): \(conflict_files($n) | join(", "))")
        elif ($c.state == "in_progress" or is_review($c)) and $c.pr != null
             and ($c.pr_info.state // null) == "OPEN" and $c.mergeable == "CONFLICTING"
          then act("update_branch"; "PR #\($c.pr) has merge conflicts with its base branch")
        elif $c.state == "in_progress" then
          if $c.pr != null then act("start_review"; "PR #\($c.pr) exists")
          elif $tries >= $max then act("block"; "implementor produced no PR after \($tries) attempts")
          else act("continue_implementor"; "no PR yet (\($tries) of \($max) implementor attempts)") end
        # merging: the merge itself. A merge_operation marker (merge-reviewed.sh, keyed form)
        # means the merge is in flight or was refused: the supervisor decides, not the planner.
        # The merger gates the way out: a merged, verified card plans finish only once note.merger
        # is {mode: after_merge, status: done} for this head (none yet: after_merge, the supervisor
        # starts the after-merge merger); a pending merge_refusal at this head plans merge_refusal
        # (the refusal merger) unless the merger asked for attention. A merge after a merger retry
        # carries retry_after (note.merge_retry.after), the time before which the supervisor holds it.
        # Attention waits for a person, who clears it with `note.sh merge <n>` setting merger: null (and merge_refusal: null,
        # merge_retry: null to let the card merge again), or move the card by hand.
        elif is_merging($c) then
          if $c.pr == null or $c.pr_info == null then act("skip"; "in merging, but no PR is known")
          elif $c.pr_info.state == "MERGED" then
            if $n.main_check.ok != true then act("verify_main"; "PR #\($c.pr) merged; successful main verification required")
            # The merger gates finish: only its after-merge result for this merge lets the card leave
            elif merger_for($c; $n; "after_merge") == "done" then act("finish"; "PR #\($c.pr) merged, main verified, merger done")
            elif merger_for($c; $n; "after_merge") == "attention" then act("skip"; "merger needs attention; a person decides")
            else act("after_merge"; "PR #\($c.pr) merged and main verified; the merger runs the after-merge steps") end
          elif $c.pr_info.state == "CLOSED" then act("block"; "PR #\($c.pr) closed without a merge")
          elif $c.pr_info.state != "OPEN" then act("skip"; "PR #\($c.pr) is \($c.pr_info.state | ascii_downcase) without a merge")
          elif $n.merge_operation != null then act("skip"; "merge in flight or refused; supervisor decides")
          # A keyed refusal leaves pending_merge at the same head: the merger session decides
          # (and clears merge_refusal), the planner must not re-plan the same refused merge every cycle
          elif ($n.merge_refusal.head // null) != null and (head_moved($c; {sha: $n.merge_refusal.head}) | not) then
            if merger_for($c; $n; "refusal") == "attention" then act("skip"; "merger needs attention; a person decides")
            else act("merge_refusal"; "merge of PR #\($c.pr) refused; the merger decides retry, fix or attention") end
          elif ($n.pending_merge.head_sha // null) != null and head_moved($c; {sha: $n.pending_merge.head_sha})
            then act("skip"; "PR head \($c.pr_info.headRefOid[0:7]) differs from the journaled merge head \($n.pending_merge.head_sha[0:7]); supervisor decides")
          # Nothing merges here that the review rows would not merge: a clean review (an advisory
          # stage findings count as clean, as in its column) covering this head, or a head moved
          # only by clean merges of main (the drift allowance of the review row) whose PR needs no human
          # QA; the PR not a draft, its checks green, and merge.policy auto.
          elif $cfg.merge.policy != "auto" then act("skip"; "merge.policy is not auto; supervisor decides")
          elif $lr == null then act("skip"; "no review recorded for the merging card; supervisor decides")
          # Stages are routed per card: no routed stage may remain, and the review must be that of the
          # last stage the card was routed to or visited (null when it was routed to none, or no stages are configured)
          elif $c.next_stage != null
            then act("skip"; "routed stage \($c.next_stage) not reviewed yet; supervisor decides")
          elif ($lr.stage // null) != ($c.routed_last_stage // null)
            then act("skip"; "the last review is not from the last stage the card was routed to; supervisor decides")
          elif ((($lr.stage // null) as $ls | any(($cfg.review.stages // [])[]; .name == $ls and .advisory == true)) | not) and $ci > 0
            then act("skip"; "the last review has \($ci) Critical/Important findings; supervisor decides")
          elif head_moved($c; $lr) and ($c.drift == null or $c.drift.unreviewed)
            then act("skip"; "PR head \($c.pr_info.headRefOid[0:7]) differs from the reviewed head \($lr.sha[0:7]); supervisor decides")
          elif $c.needs_human_qa != false
            then act("skip"; "human-QA need is \(if $c.needs_human_qa == true then "true" else "unknown" end); supervisor decides")
          elif $c.pr_info.isDraft then act("skip"; "PR #\($c.pr) is a draft; supervisor decides")
          elif ($c.pr_info | green | not) then act("skip"; "PR #\($c.pr) checks are not green; supervisor decides")
          else act("merge"; "PR #\($c.pr) open at the reviewed head, green checks, merge.policy auto") end
        elif is_review($c) then
          if $c.pr == null or $c.pr_info == null then act("skip"; "in review, but no PR is known")
          elif $c.pr_info.state == "MERGED" then
            if $n.main_check.ok != true then act("verify_main"; "PR #\($c.pr) merged; successful main verification required")
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
          # Re-review instead of fixing again: a fixer that re-ran the finding and
          # could not reproduce it (note.last_fix, for this round), or a card a
          # person moved back to In review from Blocked (the note still says
          # blocked) with the head still the reviewed one. The finding may be
          # stale; fixing it again would only block again.
          elif $ci_eff > 0 and ($n.last_fix | type) == "object" and $n.last_fix.status == "not_reproducible"
               and ($n.last_fix.round // $round) == $round
            then act($ra; "the round \($round) fixer could not reproduce the finding; review PR head \($c.pr_info.headRefOid[0:7]) again before fixing")
          elif $ci_eff > 0 and $n.state == "blocked"
            then act($ra; "moved back from Blocked with PR head unchanged since the round \($round) review; review it again before fixing")
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

  map(. as $c | (first($actual_scope[] | select(.number == $c.number)) // {paths:[],unknown:false}) as $actual
    | .scope_paths = ((.scope_paths // []) + $actual.paths | unique)
    | .scope_unknown = $actual.unknown) as $all
  | $all
  # Open cards (in_progress, in_review and every review stage column) and the lowest card number whose table
  # action is merge: only that card merges this tick
  | [$all[] | select(.state == "in_progress" or is_review(.) or is_merging(.))] as $open
  | (first($open[] | select(.scope_unknown)) // null) as $unknown_scope
  | (any($all[]; .pr_info.state == "MERGED" and .note.main_check.ok != true)) as $verify_pending
  | ([$all[] | select(decide(.; (.note // {}); ((.note // {}).round // 0)).action == "merge") | .number] | min) as $merger
  | [ .[] | . as $c | ($c.note // {}) as $n
    | ($n.round // 0) as $round
    # Models (AC6.2): from escalate_after_rounds on, implementor and fixer use
    # models.escalation, or the reviewer model when that is null
    | ($round >= $m.escalate_after_rounds) as $esc
    | ($m.escalation // ($m.reviewer | strings)) as $emodel
    | {implementor: (if $esc then $emodel else $m.implementor end),
       reviewer: $m.reviewer,
       fixer: (if $esc then $emodel else $m.fixer end)} as $models
    | (($c.title // "") | slug) as $slug
    | decide($c; $n; $round) as $d00
    # A ready card that would start waits when an open card names one of its Scope paths
    | (if $d00.action == "start"
        then (first($open[] | select(.number != $c.number) | . as $o
                | overlap(($c.scope_paths // []); ($o.scope_paths // [])) as $p
                | select($p != null) | {num: $o.number, path: $p}) // null)
        else null end) as $ov
    | (if $d00.action == "start" and $unknown_scope != null then act("wait"; "Scope unknown for #\($unknown_scope.number): PR file lookup failed or incomplete")
       elif $ov != null then act("wait"; "Scope overlaps #\($ov.num) on \($ov.path)")
       elif $d00.action == "merge" and $verify_pending
         then act("wait"; "successful main verification required before another merge")
       elif $d00.action == "merge" and $merger != $c.number
         then act("wait"; "one merge per tick: #\($merger) merges first")
       else $d00 end) as $d0
    # Settle mode keeps only the steps that start no agent
    | (if $settle | not then $d0
       elif ($d0.action == "to_human_qa" or $d0.action == "advance_stage" or $d0.action == "block" or $d0.action == "mark_ready" or $d0.action == "skip" or ($keepmerge and ($d0.action == "merge" or $d0.action == "verify_main"))) then $d0
       elif $d0.action == "start_review" then act("move_to_review"; "\($d0.reason); move to in_review without dispatching")
       else act("skip"; "\($d0.action) waits for the next tick") end) as $d
    # A failed preflight holds every card: no role runs, nothing is recorded
    | (if $pre != "" and $d.action != "skip"
       then act("wait"; "preflight failed; nothing is planned until the environment works")
       else $d end) as $d
    # A provider stage whose key variable is unset holds review_stage: the call
    # would exit 3 every tick. fix and advance_stage are unaffected.
    | (if $d.action == "review_stage" and $c.stage != null and $c.stage.provider != null
          and ($c.stage.name as $sn | any($unset[]; . == $sn))
       then act("wait"; "stage \($c.stage.name): \($cfg.providers[$c.stage.provider].api_key_env) is not set")
       else $d end) as $d2
    | ($d2.action != $d.action) as $keyheld
    | $d2 as $d
    | {key_held: $keyheld, number: $c.number, title: $c.title, state: $c.state, action: $d.action, reason: $d.reason,
       branch: ($n.branch // "fleet/\($c.number)-\($slug)"),
       worktree: ($n.worktree // "\($base)/\($c.number)-\($slug)"),
       pr: $c.pr, head_sha: $c.pr_info.headRefOid, round: $n.round, models: $models, escalated: $esc,
       # merge after a merger retry: the time before which the supervisor holds it
       retry_after: (if $d.action == "merge" and ($n.merge_retry.after | type) == "string"
                        and (head_moved($c; {sha: $n.merge_retry.head}) | not)
                     then $n.merge_retry.after else null end),
       # merge: the red checks that merge goes past (the driver records them in the note)
       ignored_checks: (if $d.action == "merge" then ($c.pr_info.statusCheckRollup | ic_used($cfg.merge.ignore_checks; $today)) else null end),
       waiting_on: (if $c.state == "ready" and $d.action == "wait" then [$c.deps_unmet[].ref] else null end),
       needs_human_qa: (if is_review($c) or is_merging($c) then $c.needs_human_qa else null end),
       # fix on a conflicted card: its findings are the conflicted files
       findings: (if $d.action == "fix" and conflict_files($n) != []
                  then [conflict_files($n)[] | {severity: "Important", text: "merge conflict in \(.)"}]
                  else null end),
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
  ] as $planned
  # Reserve only starts that actually survived every gate. A waiting card
  # contributes no reservation, so it cannot unnecessarily serialize others.
  | (if $candidates then {cards:$planned} else reduce ($planned | sort_by(.number)[]) as $card ({cards:[], reserved:[]};
      (first($all[] | select(.number == $card.number)).scope_paths // []) as $paths
      | (if $card.action == "start" then
          first(.reserved[] | . as $r | overlap($paths; $r.paths) as $p
            | select($p != null) | {number:$r.number,path:$p}) // null
         else null end) as $overlap
      | if $overlap != null then
          .cards += [$card + {action:"wait", reason:"Scope overlaps #\($overlap.number) on \($overlap.path)", waiting_on:[]}]
        else .cards += [$card]
          | if $card.action == "start" then .reserved += [{number:$card.number,paths:$paths}] else . end
        end) end) as $selected
  | $selected.cards as $cards
  | (if $candidates then
       {schema_version:2,warnings:ic_expired($cfg.merge.ignore_checks; $today),candidates:[$cards[] as $card
         | (first($all[] | select(.number == $card.number)) // {}) as $source
         | (first($actual_scope[] | select(.number == $card.number)) // {paths:[],unknown:false}) as $actual
         | ([$source.labels[]? | (if type == "object" then .name else . end)
             | select(. == "fleet:priority:high" or . == "fleet:priority:normal" or . == "fleet:priority:low")] | unique) as $priority_labels
         | {number:$card.number,action:$card.action,reason:$card.reason,
            preconditions:{state:$source.state,head_sha:$card.head_sha,round:$card.round,stage:$card.stage,dependencies:$source.deps_unmet,state_revision:$source.state_revision},
            declared_paths:($source.scope_paths // []),actual_paths:($actual.paths // []),scope_complete:(($actual.unknown // false) | not),
            dependencies:($source.deps_unmet // []),stage:$card.stage,head_sha:$card.head_sha,round:$card.round,
            priority:(if ($priority_labels|length)>1 then "conflict" elif ($priority_labels|length)==1 then ($priority_labels[0]|sub("fleet:priority:";"")) else "normal" end),
            priority_conflict:(($priority_labels|length)>1),state_revision:$source.state_revision,
            title:$card.title,state:$card.state,branch:$card.branch,worktree:$card.worktree,pr:$card.pr,
            models:$card.models,escalated:$card.escalated,findings:$card.findings,waiting_on:$card.waiting_on,
            needs_human_qa:$card.needs_human_qa,comment_needed:$card.comment_needed,lint:$card.lint,
            lint_marker:$card.lint_marker,ignored_checks:$card.ignored_checks,retry_after:$card.retry_after} ]}
     else
  {dispatchable: (($settle | not) and ($pre == "") and any($cards[];
        (.action != "skip" and .action != "wait" and .action != "file_pending" and .action != "skip_no_acceptance" and .action != "skip_card_lint")
        or ((.action == "skip_no_acceptance" or .action == "skip_card_lint") and .comment_needed == true))),
     warnings: (
       (if $pre != "" then [$pre] else [] end)
       + ic_expired($cfg.merge.ignore_checks; $today)
       + (if $m.implementor == $reviewer_model
        then ["implementor and reviewer share model \($m.implementor); the reviewer shares the writer'"'"'s blind spots"]
        else [] end)
       + (if $m.escalation != null and $m.escalation == $reviewer_model
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
       # Once per provider stage acted on whose key is unset: a held review_stage,
       # fix in it, or advance_stage into it (the following review_stage waits)
       + ([$cards[] | select((.key_held or .action == "fix" or .action == "advance_stage")
                             and .stage != null and .stage.provider != null
                             and (.stage.name as $s | any($unset[]; . == $s)))
           | "stage \(.stage.name): \($cfg.providers[.stage.provider].api_key_env) is not set; provider reviews will fail"]
          | reduce .[] as $w ([]; if any(.[]; . == $w) then . else . + [$w] end))),
     cards: [$cards[] | del(.key_held, .pending_wait, .outside_warning, .deps_warnings, .drift, .retry_after)]}
     end)
' "$CARDS_FILE" || fb_die 1 "cannot build the tick plan"
