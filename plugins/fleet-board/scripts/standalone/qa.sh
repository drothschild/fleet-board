#!/usr/bin/env bash
# Fixture-only Human QA transition; never releases an existing QA gate.
set -uo pipefail
unset CDPATH
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$SCRIPTS/board-lib.sh"
[ "$#" -eq 2 ] || exit 2
CARD="$1" SCRATCH="$2"
fb_load_config
[ "${FLEET_BOARD_STANDALONE_FIXTURE:-}" = 1 ] && [ -n "${FLEET_BOARD_FIXTURE_ROOT:-}" ] || exit 1
FIXTURE_ROOT="$(cd "$FLEET_BOARD_FIXTURE_ROOT" && pwd -P)" || exit 1
case "$FLEET_ROOT/" in "$FIXTURE_ROOT"/*) ;; *) exit 1 ;; esac
GH_BIN="$(command -v gh)" || exit 1
[ -f "$GH_BIN" ] && [ ! -L "$GH_BIN" ] || exit 1
GH_DIR="$(cd "$(dirname "$GH_BIN")" && pwd -P)" || exit 1
case "$GH_DIR/" in "$FIXTURE_ROOT"/*) ;; *) exit 1 ;; esac
[ -z "$(fb_cfg commands.qa_build)" ] || { echo 'configured QA builds are not yet supported' >&2; exit 1; }
N="$(jq -r .number "$CARD")"; PR="$(jq -r .pr "$CARD")"; BRANCH="$(jq -r .branch "$CARD")"; STATE="$(jq -r .state "$CARD")"
fb_valid_number "$N" && fb_valid_number "$PR" || exit 1
case "$STATE" in in_review|review_*) ;; *) exit 1 ;; esac
case "$BRANCH" in "fleet/$N-"*) ;; *) exit 1 ;; esac
NOTE="$(bash "$SCRIPTS/note.sh" get "$N")" || exit 1
SHA="$(jq -r .last_review.sha <<<"$NOTE")"
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || exit 1
jq -e --slurpfile card "$CARD" '.last_review.round >= .round and ((.last_review.critical == 0 and .last_review.important == 0) or $card[0].stage.advisory == true)' <<<"$NOTE" >/dev/null || exit 1
OWNER="${FLEET_REPO%/*}" REPO="${FLEET_REPO#*/}"
pr_info() { gh pr view "$PR" --repo "$FLEET_REPO" --json number,isDraft,state,headRefName,headRefOid,baseRefName,headRepositoryOwner,headRepository,body; }
check_pr() { jq -e --argjson n "$PR" --arg branch "$BRANCH" --arg sha "$SHA" --arg owner "$OWNER" --arg repo "$REPO" --arg marker "<!-- fleet-board:card:$N -->" '.number == $n and .state == "OPEN" and .headRefName == $branch and .headRefOid == $sha and .baseRefName == "main" and .headRepositoryOwner.login == $owner and .headRepository.name == $repo and (.body | contains($marker))' >/dev/null; }
INFO="$(pr_info)" || exit 1
check_pr <<<"$INFO" || { echo 'Human QA PR evidence changed' >&2; exit 1; }
CURRENT="$(bash "$SCRIPTS/board-read.sh" "$N")" || exit 1
ACTUAL="$(jq -r .state <<<"$CURRENT")"
COMMON="$(fb_git_common_dir "$FLEET_ROOT")" || exit 1
JDIR="$COMMON/fleet-board-standalone"; mkdir -p "$JDIR" || exit 1
JOURNAL="$JDIR/qa-$N-$SHA.json"
if [ -e "$JOURNAL" ]; then
  [ -f "$JOURNAL" ] && [ ! -L "$JOURNAL" ] || exit 1
  jq -e --argjson n "$N" --arg repo "$FLEET_REPO" --arg sha "$SHA" '.version == 1 and .card == $n and .repo == $repo and .sha == $sha' "$JOURNAL" >/dev/null || exit 1
else
  [ "$ACTUAL" = "$STATE" ] || { echo 'card state changed before Human QA' >&2; exit 1; }
  LABELS="$(jq -c .labels <<<"$CURRENT")"
  [ "$(bash "$SCRIPTS/needs-human-qa.sh" --labels "$LABELS" "$N" "$PR")" = true ] || { echo 'Human QA is not required' >&2; exit 1; }
  jq -n --argjson card "$N" --arg repo "$FLEET_REPO" --arg sha "$SHA" --slurpfile plan_card "$CARD" '{version:1,card:$card,repo:$repo,sha:$sha,plan_card:$plan_card[0],completed:false}' > "$JOURNAL.tmp.$$" || exit 1
  mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
fi
case "$ACTUAL" in
  human_qa) ;;
  "$STATE"|null)
    if [ "$ACTUAL" = null ]; then
      jq -e --arg source "$STATE" '.move_attempted == true and .move_source == $source' "$JOURNAL" >/dev/null || { echo 'unverified partial Human QA move' >&2; exit 1; }
      if [ "$(fb_cfg board.backend)" = github-projects ]; then
        ITEM="$(jq -r '.item_id // empty' <<<"$CURRENT")"
        [ -n "$ITEM" ] && [ "$(jq -r '.move_item_id // empty' "$JOURNAL")" = "$ITEM" ] || exit 1
      else
        STATES="$(for state in $FB_STATES; do fb_state_name "$state"; done | jq -Rsc 'split("\n") | map(select(length > 0))')" || exit 1
        jq -e --argjson states "$STATES" '[.labels[] | select(. as $label | ($states | index($label)) != null)] == []' <<<"$CURRENT" >/dev/null || exit 1
      fi
    else
      ITEM="$(jq -r '.item_id // empty' <<<"$CURRENT")"
      jq --arg source "$STATE" --arg item "$ITEM" '.move_attempted = true | .move_source = $source | .move_item_id = $item' "$JOURNAL" > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
    fi
    INFO="$(pr_info)" || exit 1
    check_pr <<<"$INFO" || exit 1
    FLEET_BOARD_ENFORCE_QA=1 bash "$SCRIPTS/board-move.sh" "$N" human_qa || exit 1 ;;
  *) echo 'card state changed before Human QA handoff' >&2; exit 1 ;;
esac
bash "$SCRIPTS/human-qa-handoff.sh" "$N" "$PR" || exit 1
jq '.completed = true' "$JOURNAL" > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
