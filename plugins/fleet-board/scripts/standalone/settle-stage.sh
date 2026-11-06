#!/usr/bin/env bash
# Fixture-only stage advance for settle; review runs in a later tick.
set -uo pipefail
unset CDPATH
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$SCRIPTS/board-lib.sh"
[ "$#" -eq 2 ] || exit 2
CARD="$1" SCRATCH="$2" CHILD=""
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
N="$(jq -r .number "$CARD")"; PR="$(jq -r .pr "$CARD")"; SOURCE="$(jq -r .state "$CARD")"; NAME="$(jq -r '.stage.name // empty' "$CARD")"; BRANCH="$(jq -r .branch "$CARD")"
fb_valid_number "$N" && fb_valid_number "$PR" && [[ "$NAME" =~ ^[a-z][a-z0-9_]*$ ]] || exit 1
case "$SOURCE" in in_review|review_*) ;; *) exit 1 ;; esac
case "$BRANCH" in "fleet/$N-"*) ;; *) exit 1 ;; esac
jq -e '.stage.provider == null and (.stage.agent | type == "string" and length > 0) and (.stage.model | type == "string" and length > 0)' "$CARD" >/dev/null || { echo 'provider stage execution is not supported' >&2; exit 1; }
TARGET="review_$NAME"
NOTE="$(bash "$SCRIPTS/note.sh" get "$N")" || exit 1
SHA="$(jq -r .last_review.sha <<<"$NOTE")"
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || exit 1
OWNER="${FLEET_REPO%/*}" REPO="${FLEET_REPO#*/}"
INFO="$(gh pr view "$PR" --repo "$FLEET_REPO" --json number,isDraft,state,headRefName,headRefOid,baseRefName,headRepositoryOwner,headRepository,body)" || exit 1
jq -e --argjson n "$PR" --arg branch "$BRANCH" --arg sha "$SHA" --arg owner "$OWNER" --arg repo "$REPO" --arg marker "<!-- fleet-board:card:$N -->" '.number == $n and .state == "OPEN" and .headRefName == $branch and .headRefOid == $sha and .baseRefName == "main" and .headRepositoryOwner.login == $owner and .headRepository.name == $repo and (.body | contains($marker))' <<<"$INFO" >/dev/null || exit 1
COMMON="$(fb_git_common_dir "$FLEET_ROOT")" || exit 1
JDIR="$COMMON/fleet-board-standalone"; mkdir -p "$JDIR" || exit 1
JOURNAL="$JDIR/settle-stage-$N-$NAME.json"
CURRENT="$(bash "$SCRIPTS/board-read.sh" "$N")" || exit 1
ACTUAL="$(jq -r .state <<<"$CURRENT")"
if [ -e "$JOURNAL" ]; then
  [ -f "$JOURNAL" ] && [ ! -L "$JOURNAL" ] || exit 1
  jq -e --argjson n "$N" --arg name "$NAME" --arg sha "$SHA" --arg source "$SOURCE" '.version == 1 and .card == $n and .name == $name and .sha == $sha and .source == $source' "$JOURNAL" >/dev/null || exit 1
else
  [ "$ACTUAL" = "$SOURCE" ] || exit 1
  PLAN="$(bash "${FLEET_BOARD_TICK_PLAN:-$SCRIPTS/tick-plan.sh}" --settle "$N")" || exit 1
  jq -e --arg name "$NAME" '.cards | length == 1 and .[0].action == "advance_stage" and .[0].stage.name == $name' <<<"$PLAN" >/dev/null || { echo 'stage routing changed' >&2; exit 1; }
  DONE="$(jq -c --arg source "$SOURCE" '(.reviewed_stages // []) + (if ($source | startswith("review_")) then [$source | sub("^review_"; "")] else [] end) | unique' <<<"$NOTE")" || exit 1
  jq -n --argjson card "$N" --arg name "$NAME" --arg sha "$SHA" --arg source "$SOURCE" --argjson done "$DONE" --slurpfile plan_card "$CARD" '{version:1,card:$card,name:$name,sha:$sha,source:$source,reviewed_stages:$done,plan_card:$plan_card[0],completed:false}' > "$JOURNAL.tmp.$$" || exit 1
  mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
fi
case "$ACTUAL" in
  "$TARGET") ;;
  "$SOURCE"|null)
    if [ "$ACTUAL" = null ]; then
      jq -e --arg source "$SOURCE" '.move_attempted == true and .move_source == $source' "$JOURNAL" >/dev/null || exit 1
      if [ "$(fb_cfg board.backend)" = github-projects ]; then
        ITEM="$(jq -r '.item_id // empty' <<<"$CURRENT")"; [ -n "$ITEM" ] && [ "$(jq -r '.move_item_id // empty' "$JOURNAL")" = "$ITEM" ] || exit 1
      else
        STATES="$(for state in $FB_STATES; do fb_state_name "$state"; done | jq -Rsc 'split("\n") | map(select(length > 0))')" || exit 1
        jq -e --argjson states "$STATES" '[.labels[] | select(. as $label | ($states | index($label)) != null)] == []' <<<"$CURRENT" >/dev/null || exit 1
      fi
    else
      ITEM="$(jq -r '.item_id // empty' <<<"$CURRENT")"
      jq --arg source "$SOURCE" --arg item "$ITEM" '.move_attempted = true | .move_source = $source | .move_item_id = $item' "$JOURNAL" > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
    fi
    FLEET_BOARD_ENFORCE_QA=1 bash "$SCRIPTS/board-move.sh" "$N" "$TARGET" || exit 1 ;;
  *) echo 'card state changed during stage advance' >&2; exit 1 ;;
esac
jq -n --arg stage "$NAME" --argjson done "$(jq -c .reviewed_stages "$JOURNAL")" '{stage:$stage,round:1,reviewed_stages:$done}' > "$SCRATCH/stage-note"
bash "$SCRIPTS/note.sh" merge "$N" "$SCRATCH/stage-note" || exit 1
jq '.completed = true' "$JOURNAL" > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
