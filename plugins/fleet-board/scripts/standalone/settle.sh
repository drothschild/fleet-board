#!/usr/bin/env bash
# Guarded standalone settle pass; never dispatches a worker or merges a PR.
set -uo pipefail
unset CDPATH
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$SCRIPTS/board-lib.sh"
if [ "$#" -ne 0 ]; then [ "$#" -eq 1 ] && [ "$1" = --locked ] && [ "${FLEET_BOARD_REPO_LOCK_OWNER:-}" = "$$" ] || exit 2; fi
fb_load_config
[ "${FLEET_BOARD_STANDALONE_FIXTURE:-}" = 1 ] && [ -n "${FLEET_BOARD_FIXTURE_ROOT:-}" ] || { echo 'standalone settle is available only in local fixtures' >&2; exit 1; }
FIXTURE_ROOT="$(cd "$FLEET_BOARD_FIXTURE_ROOT" && pwd -P)" || exit 1
case "$FLEET_ROOT/" in "$FIXTURE_ROOT"/*) ;; *) exit 1 ;; esac
GH_BIN="$(command -v gh)" || exit 1
[ -f "$GH_BIN" ] && [ ! -L "$GH_BIN" ] || exit 1
GH_DIR="$(cd "$(dirname "$GH_BIN")" && pwd -P)" || exit 1
case "$GH_DIR/" in "$FIXTURE_ROOT"/*) ;; *) exit 1 ;; esac
COMMON="$(fb_git_common_dir "$FLEET_ROOT")" || exit 1
LOCK_FILE="$COMMON/fleet-board-standalone.lockfile"
if [ -z "${FLEET_BOARD_REPO_LOCK_FD:-}" ] || [ "${FLEET_BOARD_REPO_LOCK_OWNER:-}" != "$$" ]; then
  exec python3 "$SCRIPTS/standalone/repo-lock.py" acquire "$LOCK_FILE" "${BASH_SOURCE[0]}" --locked
fi
python3 "$SCRIPTS/standalone/repo-lock.py" verify "$LOCK_FILE" || exit 1
TMP="$(mktemp -d)" || exit 1
cleanup() { rm -rf "$TMP"; }
CHILD=""
cancel() {
  local code="$1" target="$CHILD" watchdog=""
  trap '' INT TERM
  if [ -n "$target" ]; then
    kill -TERM -- "-$target" 2>/dev/null || true
    (sleep 5; kill -KILL -- "-$target" 2>/dev/null || true) </dev/null >/dev/null 2>&1 & watchdog=$!
    wait "$target" 2>/dev/null || true
    kill -KILL -- "-$target" 2>/dev/null || true
    kill "$watchdog" 2>/dev/null || true; wait "$watchdog" 2>/dev/null || true
  fi
  exit "$code"
}
run_group() {
  local rc
  set -m; "$@" & CHILD=$!; set +m
  wait "$CHILD"; rc=$?; CHILD=""; return "$rc"
}
trap cleanup EXIT
trap 'cancel 130' INT
trap 'cancel 143' TERM
# Resolve incomplete settle moves first. Never execute a new plan alongside one.
for journal in "$COMMON"/fleet-board-standalone/settle-move-*.json "$COMMON"/fleet-board-standalone/settle-stage-*.json; do
  [ -e "$journal" ] || continue
  [ -f "$journal" ] && [ ! -L "$journal" ] || exit 1
  jq -e '.version == 1 and (.plan_card | type == "object")' "$journal" >/dev/null || exit 1
  jq -e '.completed == true' "$journal" >/dev/null && continue
  jq '.plan_card' "$journal" > "$TMP/card" || exit 1
  case "$(basename "$journal")" in
    settle-move-*) run_group bash "$SCRIPTS/standalone/settle-move.sh" "$TMP/card" "$TMP" || exit 1 ;;
    settle-stage-*) run_group bash "$SCRIPTS/standalone/settle-stage.sh" "$TMP/card" "$TMP" || exit 1 ;;
    *) exit 1 ;;
  esac
  exit 0
done
NUMS=()
for state in in_progress in_review $(fb_stage_states); do
  run_group bash "$SCRIPTS/board-list.sh" "$state" </dev/null > "$TMP/list" || exit 1
  LIST="$(cat "$TMP/list")" || exit 1
  jq -e 'type == "array" and all(.[]; (.number | type == "number" and . > 0 and floor == .))' <<<"$LIST" >/dev/null || exit 1
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    found=false; for prior in "${NUMS[@]+${NUMS[@]}}"; do [ "$prior" != "$n" ] || found=true; done
    [ "$found" = true ] || NUMS+=("$n")
  done < <(jq -r '.[].number' <<<"$LIST")
done
[ "${#NUMS[@]}" -gt 0 ] || exit 0
run_group bash "${FLEET_BOARD_TICK_PLAN:-$SCRIPTS/tick-plan.sh}" --settle "${NUMS[@]}" > "$TMP/plan" || exit 1
jq -n '$ARGS.positional | map(tonumber)' --args "${NUMS[@]}" > "$TMP/nums" || exit 1
jq -e --slurpfile nums "$TMP/nums" 'type == "object" and .dispatchable == false and (.warnings | type == "array" and all(.[]; type == "string")) and (.cards | type == "array") and ([.cards[].number] | sort) == ($nums[0] | sort) and ([.cards[].number] | length == (unique | length)) and all(.cards[]; (.number as $n | $nums[0] | index($n)) != null and (.action | IN("skip","move_to_review","advance_stage","to_human_qa","mark_ready","block")))' "$TMP/plan" >/dev/null || { echo 'invalid settle plan' >&2; exit 1; }
jq -c '.cards[] | select(.action != "skip")' "$TMP/plan" > "$TMP/actions" || exit 1
RC=0
while IFS= read -r card; do
  [ -n "$card" ] || continue
  action="$(jq -r .action <<<"$card")"; n="$(jq -r .number <<<"$card")"
  [ "$action" != block ] || [[ "$(jq -r .reason <<<"$card")" != 'no progress after '* ]] || continue
  dir="$TMP/card-$n"; mkdir "$dir" || exit 1
  printf '%s\n' "$card" > "$dir/card"
  case "$action" in
    move_to_review) script=settle-move ;;
    advance_stage) script=settle-stage ;;
    to_human_qa) script=qa ;;
    mark_ready) script=publication ;;
    block) script=maintenance ;;
    *) exit 1 ;;
  esac
  run_group bash "$SCRIPTS/standalone/$script.sh" "$dir/card" "$dir" || RC=1
done < "$TMP/actions"
exit "$RC"
