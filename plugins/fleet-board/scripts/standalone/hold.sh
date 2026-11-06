#!/usr/bin/env bash
# Fixture-only, idempotent explanation for a card lacking acceptance criteria.
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
N="$(jq -r .number "$CARD")"
fb_valid_number "$N" && [ "$(jq -r .action "$CARD")" = skip_no_acceptance ] || exit 1
[ "$(jq -r .comment_needed "$CARD")" = true ] || exit 0
CURRENT="$(bash "$SCRIPTS/board-read.sh" "$N")" || exit 1
[ "$(jq -r .state <<<"$CURRENT")" = ready ] || { echo 'card state changed before acceptance notice' >&2; exit 1; }
if fb_has_acceptance "$(jq -r '.body // ""' <<<"$CURRENT")"; then echo 'acceptance criteria changed before notice' >&2; exit 1; fi
MARKER='<!-- fleet-board:skip-no-acceptance -->'
if jq -e --arg marker "$MARKER" 'any(.comments[]; .body | contains($marker))' <<<"$CURRENT" >/dev/null; then exit 0; fi
printf '%s\n\nThis card needs a ## Acceptance section before work can start.\n' "$MARKER" > "$SCRATCH/comment"
bash "$SCRIPTS/board-comment.sh" "$N" "$SCRATCH/comment"
