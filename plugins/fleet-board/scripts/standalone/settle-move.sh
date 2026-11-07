#!/usr/bin/env bash
# Fixture-only move to review, without starting a reviewer.
set -uo pipefail
unset CDPATH
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$SCRIPTS/board-lib.sh"
[ "$#" -eq 2 ] && [ -f "$1" ] && [ -d "$2" ] || exit 2
CARD="$1" SCRATCH="$2"
fb_load_config
[ "${FLEET_BOARD_STANDALONE_FIXTURE:-}" = 1 ] && [ -n "${FLEET_BOARD_FIXTURE_ROOT:-}" ] || exit 1
FIXTURE_ROOT="$(cd "$FLEET_BOARD_FIXTURE_ROOT" && pwd -P)" || exit 1
case "$FLEET_ROOT/" in "$FIXTURE_ROOT"/*) ;; *) exit 1 ;; esac
GH_BIN="$(command -v gh)" || exit 1
[ -f "$GH_BIN" ] && [ ! -L "$GH_BIN" ] || exit 1
GH_DIR="$(cd "$(dirname "$GH_BIN")" && pwd -P)" || exit 1
case "$GH_DIR/" in "$FIXTURE_ROOT"/*) ;; *) exit 1 ;; esac
N="$(jq -r .number "$CARD")"; PR="$(jq -r .pr "$CARD")"; BRANCH="$(jq -r .branch "$CARD")"
fb_valid_number "$N" && fb_valid_number "$PR" || exit 1
case "$BRANCH" in "fleet/$N-"*) ;; *) exit 1 ;; esac
jq -e '.action == "move_to_review" and .state == "in_progress"' "$CARD" >/dev/null || exit 1
OWNER="${FLEET_REPO%/*}" REPO="${FLEET_REPO#*/}"
pr_info() { gh pr view "$PR" --repo "$FLEET_REPO" --json number,state,headRefName,headRefOid,baseRefName,headRepositoryOwner,headRepository,body; }
identity() { jq -e --argjson n "$PR" --arg branch "$BRANCH" --arg owner "$OWNER" --arg repo "$REPO" --arg marker "<!-- fleet-board:card:$N -->" '.number == $n and .state == "OPEN" and .headRefName == $branch and .baseRefName == "main" and .headRepositoryOwner.login == $owner and .headRepository.name == $repo and (.body | contains($marker)) and (.headRefOid | type == "string" and test("^[0-9a-f]{40}$"))' >/dev/null; }
INFO="$(pr_info)" || exit 1
identity <<<"$INFO" || exit 1
SHA="$(jq -r .headRefOid <<<"$INFO")"
COMMON="$(fb_git_common_dir "$FLEET_ROOT")" || exit 1
JDIR="$COMMON/fleet-board-standalone"; mkdir -p "$JDIR" || exit 1
JOURNAL="$JDIR/settle-move-$N.json"
CURRENT="$(bash "$SCRIPTS/board-read.sh" "$N")" || exit 1
ACTUAL="$(jq -r .state <<<"$CURRENT")"
if [ -e "$JOURNAL" ]; then
  [ -f "$JOURNAL" ] && [ ! -L "$JOURNAL" ] || exit 1
  jq -e --argjson n "$N" --argjson pr "$PR" --arg repo "$FLEET_REPO" --arg sha "$SHA" '.version == 1 and .card == $n and .pr == $pr and .repo == $repo and .sha == $sha' "$JOURNAL" >/dev/null || exit 1
else
  [ "$ACTUAL" = in_progress ] || exit 1
  jq -n --argjson card "$N" --argjson pr "$PR" --arg repo "$FLEET_REPO" --arg sha "$SHA" --slurpfile plan_card "$CARD" '{version:1,card:$card,pr:$pr,repo:$repo,sha:$sha,plan_card:$plan_card[0],completed:false}' > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
fi
if [ "$ACTUAL" = in_progress ]; then
  bash "$SCRIPTS/review-stages.sh" route "$N" "$PR" >/dev/null || exit 1
  INFO="$(pr_info)" || exit 1
  identity <<<"$INFO" && [ "$(jq -r .headRefOid <<<"$INFO")" = "$SHA" ] || exit 1
  CURRENT="$(bash "$SCRIPTS/board-read.sh" "$N")" || exit 1
  [ "$(jq -r .state <<<"$CURRENT")" = in_progress ] || exit 1
  ITEM="$(jq -r '.item_id // empty' <<<"$CURRENT")"
  jq --arg item "$ITEM" '.move_attempted = true | .move_item_id = $item' "$JOURNAL" > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
elif [ "$ACTUAL" = null ]; then
  jq -e '.move_attempted == true' "$JOURNAL" >/dev/null || exit 1
  if [ "$(fb_cfg board.backend)" = github-projects ]; then
    ITEM="$(jq -r '.item_id // empty' <<<"$CURRENT")"; [ -n "$ITEM" ] && [ "$ITEM" = "$(jq -r '.move_item_id // empty' "$JOURNAL")" ] || exit 1
  else
    STATES="$(for state in $FB_STATES; do fb_state_name "$state"; done | jq -Rsc 'split("\n") | map(select(length > 0))')" || exit 1
    jq -e --argjson states "$STATES" '[.labels[] | select(. as $label | ($states | index($label)) != null)] == []' <<<"$CURRENT" >/dev/null || exit 1
  fi
elif [ "$ACTUAL" = in_review ]; then
  jq -e '.move_attempted == true' "$JOURNAL" >/dev/null || exit 1
else echo 'card state changed during settle' >&2; exit 1
fi
if [ "$ACTUAL" != in_review ]; then FLEET_BOARD_ENFORCE_QA=1 bash "$SCRIPTS/board-move.sh" "$N" in_review || exit 1; fi
jq -n --argjson pr "$PR" '{state:"in_review",round:1,pr:$pr}' > "$SCRATCH/patch" || exit 1
bash "$SCRIPTS/note.sh" merge "$N" "$SCRATCH/patch" || exit 1
jq '.completed = true' "$JOURNAL" > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
