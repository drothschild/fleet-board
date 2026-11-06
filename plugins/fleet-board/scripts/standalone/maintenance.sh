#!/usr/bin/env bash
# Fixture-only non-worker maintenance actions. Recheck board evidence before writes.
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
jq -e '(.number | type == "number" and . > 0 and floor == .) and (.action | IN("wait", "skip_card_lint"))' "$CARD" >/dev/null || exit 1
N="$(jq -r .number "$CARD")"; ACTION="$(jq -r .action "$CARD")"
fb_valid_number "$N" || exit 1
if [ "$ACTION" = wait ] && [ "$(jq -r .state "$CARD")" != ready ]; then exit 0; fi
jq -e '.state == "ready"' "$CARD" >/dev/null || exit 1
CURRENT="$(bash "$SCRIPTS/board-read.sh" "$N")" || exit 1
[ "$(jq -r .state <<<"$CURRENT")" = ready ] || { echo 'card no longer ready' >&2; exit 1; }
if [ "$ACTION" = wait ]; then
  jq -e '.waiting_on | type == "array" and all(.[]; type == "string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[1-9][0-9]*$"))' "$CARD" >/dev/null || exit 1
  # A ready wait without dependencies can be a preflight or scope hold.
  [ "$(jq '.waiting_on | length' "$CARD")" -gt 0 ] || exit 0
  NOTE="$(bash "$SCRIPTS/note.sh" get "$N")" || exit 1
  jq -e --slurpfile card "$CARD" '.deps_commented == $card[0].waiting_on' <<<"$NOTE" >/dev/null && exit 0
  BODY="$(jq -r '"Waiting for " + (.waiting_on | join(", "))' "$CARD")"
  # If the comment succeeded before the note write, reuse the most recent wait notice.
  if ! jq -e --arg body "$BODY" '[.comments[].body | select(startswith("Waiting for "))] | (last // "") == $body' <<<"$CURRENT" >/dev/null; then
    printf '%s' "$BODY" > "$SCRATCH/comment" || exit 1
    bash "$SCRIPTS/board-comment.sh" "$N" "$SCRATCH/comment" || exit 1
  fi
  jq '{deps_commented:.waiting_on}' "$CARD" > "$SCRATCH/patch" || exit 1
  bash "$SCRIPTS/note.sh" merge "$N" "$SCRATCH/patch" || exit 1
else
  jq -e '(.comment_needed | type == "boolean") and (.lint | type == "array" and length > 0 and all(.[]; type == "string")) and (.lint_marker | type == "string" and test("^<!-- fleet-board:card-lint:[0-9]+ -->$"))' "$CARD" >/dev/null || exit 1
  [ "$(jq -r .comment_needed "$CARD")" = true ] || exit 0
  MARKER="$(jq -r .lint_marker "$CARD")"
  if jq -e --arg marker "$MARKER" '[.comments[].body | select(contains("<!-- fleet-board:card-lint:"))] | (last // "") | contains($marker)' <<<"$CURRENT" >/dev/null; then exit 0; fi
  jq -r '.lint_marker, (.lint[] | "- " + .), "Please fix the card."' "$CARD" > "$SCRATCH/comment" || exit 1
  bash "$SCRIPTS/board-comment.sh" "$N" "$SCRATCH/comment" || exit 1
fi
