#!/usr/bin/env bash
# Fixture-only continuation: record one durable attempt, then reuse start.
set -uo pipefail
unset CDPATH
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$SCRIPTS/board-lib.sh"
[ "$#" -eq 2 ] || [ "$#" -eq 3 ] || exit 2
CARD="$1" SCRATCH="$2" RECOVERY="${3:-}" CHILD=""
cancel() { local code="$1"; if [ -n "$CHILD" ]; then kill -TERM "$CHILD" 2>/dev/null || true; wait "$CHILD" 2>/dev/null || true; CHILD=""; fi; exit "$code"; }
trap 'cancel 130' INT
trap 'cancel 143' TERM
fb_load_config
[ "${FLEET_BOARD_STANDALONE_FIXTURE:-}" = 1 ] && [ -n "${FLEET_BOARD_FIXTURE_ROOT:-}" ] || exit 1
FIXTURE_ROOT="$(cd "$FLEET_BOARD_FIXTURE_ROOT" && pwd -P)" || exit 1
case "$FLEET_ROOT/" in "$FIXTURE_ROOT"/*) ;; *) exit 1 ;; esac
GH_BIN="$(command -v gh)" || exit 1
[ -f "$GH_BIN" ] && [ ! -L "$GH_BIN" ] || exit 1
GH_DIR="$(cd "$(dirname "$GH_BIN")" && pwd -P)" || exit 1
case "$GH_DIR/" in "$FIXTURE_ROOT"/*) ;; *) exit 1 ;; esac
N="$(jq -r .number "$CARD")"; BRANCH="$(jq -r .branch "$CARD")"; WT="$(jq -r .worktree "$CARD")"
fb_valid_number "$N" && [ "$(jq -r .action "$CARD")" = continue_implementor ] && [ "$(jq -r .state "$CARD")" = in_progress ] || exit 1
case "$BRANCH" in "fleet/$N-"*) ;; *) exit 1 ;; esac
COMMON="$(fb_git_common_dir "$FLEET_ROOT")" || exit 1
JDIR="$COMMON/fleet-board-standalone"; mkdir -p "$JDIR" || exit 1
NOTE="$(bash "$SCRIPTS/note.sh" get "$N")" || exit 1
if [ -n "$RECOVERY" ]; then
  JOURNAL="$RECOVERY"
  [ -f "$JOURNAL" ] && [ ! -L "$JOURNAL" ] || exit 1
  ATTEMPT="$(jq -r .attempt "$JOURNAL")"
else
  CURRENT="$(jq -r '.implementor_attempts // 0' <<<"$NOTE")"
  [[ "$CURRENT" =~ ^[0-9]+$ ]] || exit 1
  ATTEMPT=$((CURRENT + 1)); JOURNAL="$JDIR/continue-$N-$ATTEMPT.json"
fi
[[ "$ATTEMPT" =~ ^[1-9][0-9]*$ ]] && [ "$JOURNAL" = "$JDIR/continue-$N-$ATTEMPT.json" ] || exit 1
if [ -e "$JOURNAL" ]; then
  jq -e --argjson n "$N" --argjson attempt "$ATTEMPT" --arg repo "$FLEET_REPO" --arg branch "$BRANCH" --arg wt "$WT" '.version == 1 and .card == $n and .attempt == $attempt and .repo == $repo and .branch == $branch and .worktree == $wt' "$JOURNAL" >/dev/null || exit 1
else
  jq -n --argjson card "$N" --argjson attempt "$ATTEMPT" --arg repo "$FLEET_REPO" --arg branch "$BRANCH" --arg wt "$WT" --slurpfile plan_card "$CARD" '{version:1,card:$card,attempt:$attempt,repo:$repo,branch:$branch,worktree:$wt,plan_card:$plan_card[0],completed:false}' > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
fi
START_JOURNAL="$JDIR/start-$N.json"
PR="$(jq -r '.pr // empty' <<<"$NOTE")"
if [ -n "$PR" ]; then
  fb_valid_number "$PR" && [ -f "$START_JOURNAL" ] && [ ! -L "$START_JOURNAL" ] || exit 1
  jq -e --arg branch "$BRANCH" --argjson attempt "$ATTEMPT" '.completed == true and .branch == $branch and .plan_card.continuation_attempt == $attempt' "$START_JOURNAL" >/dev/null || exit 1
  HEAD_SHA="$(jq -r .head "$START_JOURNAL")"
  INFO="$(gh pr view "$PR" --repo "$FLEET_REPO" --json number,isDraft,state,headRefName,headRefOid,baseRefName,headRepositoryOwner,headRepository,body)" || exit 1
  OWNER="${FLEET_REPO%/*}" REPO="${FLEET_REPO#*/}"
  jq -e --argjson pr "$PR" --arg branch "$BRANCH" --arg sha "$HEAD_SHA" --arg owner "$OWNER" --arg repo "$REPO" --arg marker "<!-- fleet-board:card:$N -->" '.number == $pr and .isDraft == true and .state == "OPEN" and .headRefName == $branch and .headRefOid == $sha and .baseRefName == "main" and .headRepositoryOwner.login == $owner and .headRepository.name == $repo and (.body | contains($marker))' <<<"$INFO" >/dev/null || exit 1
  jq '.completed = true' "$JOURNAL" > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
  exit 0
fi
CURRENT="$(bash "$SCRIPTS/board-read.sh" "$N")" || exit 1
[ "$(jq -r .state <<<"$CURRENT")" = in_progress ] || { echo 'card is no longer in progress' >&2; exit 1; }
COUNT="$(jq -r '.implementor_attempts // 0' <<<"$NOTE")"
if [ "$COUNT" = "$((ATTEMPT - 1))" ]; then
  jq -n --arg branch "$BRANCH" --arg wt "$WT" --argjson attempt "$ATTEMPT" '{branch:$branch,worktree:$wt,implementor_attempts:$attempt}' > "$SCRATCH/continue-note"
  bash "$SCRIPTS/note.sh" merge "$N" "$SCRATCH/continue-note" || exit 1
elif [ "$COUNT" != "$ATTEMPT" ]; then
  echo 'implementor attempt changed before continuation' >&2; exit 1
fi
if [ -e "$START_JOURNAL" ]; then echo 'existing start evidence needs reconciliation' >&2; exit 1; fi
PRS="$(gh pr list --repo "$FLEET_REPO" --head "$BRANCH" --state open --json number)" || exit 1
jq -e 'type == "array" and length == 0' <<<"$PRS" >/dev/null || { echo 'existing PR needs reconciliation' >&2; exit 1; }
jq --argjson attempt "$ATTEMPT" '.action = "start" | .state = "ready" | .continuation_attempt = $attempt' "$CARD" > "$SCRATCH/start-card" || exit 1
mkdir "$SCRATCH/continuation-start" || exit 1
bash "$SCRIPTS/standalone/start.sh" "$SCRATCH/start-card" "$SCRATCH/continuation-start" & CHILD=$!
wait "$CHILD"; RC=$?; CHILD=""
if [ "$RC" -ne 0 ]; then
  if [ ! -e "$START_JOURNAL" ]; then jq '.completed = true' "$JOURNAL" > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || true; fi
  exit "$RC"
fi
jq '.completed = true' "$JOURNAL" > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
