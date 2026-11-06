#!/usr/bin/env bash
# Fixture-only publication: pin merge to reviewed head and verify main.
set -uo pipefail
unset CDPATH
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$SCRIPTS/board-lib.sh"
[ "$#" -eq 2 ] || exit 2
CARD="$1" SCRATCH="$2"
fb_load_config
[ "${FLEET_BOARD_STANDALONE_FIXTURE:-}" = 1 ] && [ -n "${FLEET_BOARD_FIXTURE_ROOT:-}" ] || { echo 'publication is available only in local fixtures' >&2; exit 1; }
FIXTURE_ROOT="$(cd "$FLEET_BOARD_FIXTURE_ROOT" && pwd -P)" || exit 1
case "$FLEET_ROOT/" in "$FIXTURE_ROOT"/*) ;; *) exit 1 ;; esac
GH_BIN="$(command -v gh)" || exit 1
[ -f "$GH_BIN" ] && [ ! -L "$GH_BIN" ] || exit 1
GH_DIR="$(cd "$(dirname "$GH_BIN")" && pwd -P)" || exit 1
case "$GH_DIR/" in "$FIXTURE_ROOT"/*) ;; *) exit 1 ;; esac
REMOTE="$(git -C "$FLEET_ROOT" remote get-url origin)" || exit 1
case "$REMOTE" in file://*) REMOTE_DIR="${REMOTE#file://}" ;; *) exit 1 ;; esac
REMOTE_DIR="$(cd "$REMOTE_DIR" && pwd -P)" || exit 1
case "$REMOTE_DIR/" in "$FIXTURE_ROOT"/*) ;; *) exit 1 ;; esac
N="$(jq -r .number "$CARD")"; PR="$(jq -r .pr "$CARD")"; BRANCH="$(jq -r .branch "$CARD")"; STATE="$(jq -r .state "$CARD")"; ACTION="$(jq -r .action "$CARD")"
fb_valid_number "$N" && fb_valid_number "$PR" || exit 1
case "$STATE" in in_review|review_*) ;; *) exit 1 ;; esac
case "$BRANCH" in "fleet/$N-"*) ;; *) exit 1 ;; esac
NOTE="$(bash "$SCRIPTS/note.sh" get "$N")" || exit 1
SHA="$(jq -r .last_review.sha <<<"$NOTE")"
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || exit 1
jq -e --slurpfile card "$CARD" '.last_review.round >= .round and ((.last_review.critical == 0 and .last_review.important == 0) or $card[0].stage.advisory == true) and (.last_review.stage // null) == ($card[0].stage.name // null)' <<<"$NOTE" >/dev/null || { echo 'no clean current review' >&2; exit 1; }
OWNER="${FLEET_REPO%/*}" REPO="${FLEET_REPO#*/}"
pr_info() { gh pr view "$PR" --repo "$FLEET_REPO" --json number,isDraft,state,headRefName,headRefOid,baseRefName,headRepositoryOwner,headRepository,body,statusCheckRollup,mergeable; }
check_identity() { jq -e --argjson n "$PR" --arg branch "$BRANCH" --arg sha "$SHA" --arg owner "$OWNER" --arg repo "$REPO" --arg marker "<!-- fleet-board:card:$N -->" '.number == $n and .headRefName == $branch and .headRefOid == $sha and .baseRefName == "main" and .headRepositoryOwner.login == $owner and .headRepository.name == $repo and (.body | contains($marker))' >/dev/null; }
read_card() {
  CURRENT="$(bash "$SCRIPTS/board-read.sh" "$N")" || return 1
  ACTUAL="$(jq -r .state <<<"$CURRENT")" || return 1
  if [ "$ACTUAL" != "$STATE" ] && [ "$ACTUAL" != done ]; then return 1; fi
  if [ "$(fb_cfg board.backend)" = github-projects ]; then
    jq -e --argjson n "$N" '.number == $n and (.item_id | type == "string" and length > 0)' <<<"$CURRENT" >/dev/null || return 1
  else
    local states state
    states="$(for state in $FB_STATES; do fb_state_name "$state"; done | jq -Rsc 'split("\n") | map(select(length > 0))')" || return 1
    jq -e --arg expected "$(fb_state_name "$ACTUAL")" --argjson states "$states" '[.labels[] | select(. as $label | ($states | index($label)) != null)] == [$expected]' <<<"$CURRENT" >/dev/null || return 1
  fi
}
read_card || { echo 'card state changed before publication' >&2; exit 1; }
LABELS="$(jq -c .labels <<<"$CURRENT")"
[ "$(bash "$SCRIPTS/needs-human-qa.sh" --labels "$LABELS" "$N" "$PR")" = false ] || { echo 'Human QA required' >&2; exit 1; }
INFO="$(pr_info)" || exit 1
check_identity <<<"$INFO" || { echo 'reviewed PR head or identity changed' >&2; exit 1; }
if [ "$ACTION" = mark_ready ]; then
  [ "$ACTUAL" = "$STATE" ] && jq -e '.state == "OPEN" and .isDraft == true' <<<"$INFO" >/dev/null || exit 1
  gh pr ready "$PR" --repo "$FLEET_REPO" >/dev/null || exit 1
  INFO="$(pr_info)" || exit 1
  check_identity <<<"$INFO" && jq -e '.state == "OPEN" and .isDraft == false' <<<"$INFO" >/dev/null || exit 1
  exit 0
fi
COMMON="$(fb_git_common_dir "$FLEET_ROOT")" || exit 1
JDIR="$COMMON/fleet-board-standalone"; mkdir -p "$JDIR" || exit 1
JOURNAL="$JDIR/merge-$N-$SHA.json"
if [ -e "$JOURNAL" ]; then
  [ -f "$JOURNAL" ] && [ ! -L "$JOURNAL" ] || exit 1
  jq -e --argjson n "$N" --arg repo "$FLEET_REPO" --arg sha "$SHA" '.version == 1 and .card == $n and .repo == $repo and .sha == $sha' "$JOURNAL" >/dev/null || exit 1
else
  [ "$ACTUAL" = "$STATE" ] || exit 1
  jq -n --argjson card "$N" --arg repo "$FLEET_REPO" --arg sha "$SHA" --slurpfile plan_card "$CARD" '{version:1,card:$card,repo:$repo,sha:$sha,plan_card:$plan_card[0],completed:false}' > "$JOURNAL.tmp.$$" || exit 1
  mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
fi
PR_STATE="$(jq -r .state <<<"$INFO")"
if [ "$PR_STATE" = OPEN ]; then
  [ "$ACTION" = merge ] && [ "$(fb_cfg merge.policy)" = auto ] && [ "$ACTUAL" = "$STATE" ] || exit 1
  jq -e '.isDraft == false and .mergeable == "MERGEABLE" and (.statusCheckRollup | type == "array" and length > 0 and all(.[]; (.conclusion // .state) as $s | $s == "SUCCESS" or $s == "NEUTRAL" or $s == "SKIPPED"))' <<<"$INFO" >/dev/null || { echo 'PR is not ready and green' >&2; exit 1; }
  # GitHub atomically rejects a head that moved after the evidence check.
  gh pr merge "$PR" --repo "$FLEET_REPO" --squash --match-head-commit "$SHA" >/dev/null || exit 1
  INFO="$(pr_info)" || exit 1
  check_identity <<<"$INFO" && [ "$(jq -r .state <<<"$INFO")" = MERGED ] || { echo 'merge state was not verified' >&2; exit 1; }
elif [ "$PR_STATE" != MERGED ]; then
  exit 1
fi
jq -n --argjson pr "$PR" '{merged_pr:$pr}' > "$SCRATCH/merge-note"
bash "$SCRIPTS/note.sh" merge "$N" "$SCRATCH/merge-note" || exit 1
VERIFY="${FLEET_BOARD_VERIFY_MAIN:-$SCRIPTS/verify-main.sh}"
if [ "$VERIFY" != "$SCRIPTS/verify-main.sh" ]; then
  [ -f "$VERIFY" ] && [ ! -L "$VERIFY" ] || exit 1
  VERIFY_DIR="$(cd "$(dirname "$VERIFY")" && pwd -P)" || exit 1
  case "$VERIFY_DIR/" in "$FIXTURE_ROOT"/*) ;; *) exit 1 ;; esac
fi
CHECK="$(bash "$VERIFY" "$N" "$PR")" || { echo 'main verification failed to run' >&2; exit 1; }
jq -e 'type == "object" and (.commit | type == "string" and test("^[0-9a-f]{40}$")) and (.ok | type == "boolean") and (.results | type == "array")' <<<"$CHECK" >/dev/null || { echo 'invalid main verification result' >&2; exit 1; }
MAIN_SHA="$(git -C "$FLEET_ROOT" ls-remote origin refs/heads/main)" || exit 1
[ "${MAIN_SHA%%[[:space:]]*}" = "$(jq -r .commit <<<"$CHECK")" ] || { echo 'main changed after verification' >&2; exit 1; }
jq -n --argjson check "$CHECK" '{main_check:$check}' > "$SCRATCH/check-note"
bash "$SCRIPTS/note.sh" merge "$N" "$SCRATCH/check-note" || exit 1
[ "$(jq -r .ok <<<"$CHECK")" = true ] || { echo 'main verification was not successful' >&2; exit 1; }
read_card || { echo 'card state changed before Done' >&2; exit 1; }
if printf '%s\n' "$(jq -r '.body // ""' <<<"$CURRENT")" | grep -q '^## After merge'; then echo 'after-merge commands require reconciliation' >&2; exit 1; fi
if [ "$ACTUAL" = "$STATE" ]; then
  jq --arg source "$STATE" '.move_attempted = true | .move_source = $source' "$JOURNAL" > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
  FLEET_BOARD_ENFORCE_QA=1 bash "$SCRIPTS/board-move.sh" "$N" done || exit 1
fi
printf '%s\n' '{"state":"done","action_failures":0,"last_action_error":null}' > "$SCRATCH/done-note"
bash "$SCRIPTS/note.sh" merge "$N" "$SCRATCH/done-note" || exit 1
jq '.completed = true' "$JOURNAL" > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
