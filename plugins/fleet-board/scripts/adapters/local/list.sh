#!/usr/bin/env bash
set -uo pipefail
. "$FLEET_SCRIPTS/board-lib.sh"
. "$FLEET_SCRIPTS/adapters/local/local-lib.sh"

[ "${1:-}" = "--allow-truncated" ] && shift
STATE="$1"
fl_require_store
CARDS="$(fl_cards_dir)"
OUT="[]"
for f in "$CARDS"/*.json; do
  [ -e "$f" ] || continue
  ITEM="$(jq -ce 'select(type == "object") | {number, title, state}' "$f" 2>/dev/null)" \
    || fb_die 1 "card file is not valid JSON: $f"
  OUT="$(jq -c --argjson i "$ITEM" '. + [$i]' <<<"$OUT")"
done
PORT="$(fb_cfg board.port)"
jq -c --arg s "$STATE" --arg p "$PORT" \
  '[.[] | select(.state == $s)] | sort_by(.number) | map({number, title, url: ("http://127.0.0.1:" + $p + "/cards/" + (.number | tostring))})' <<<"$OUT"
