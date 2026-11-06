#!/usr/bin/env bash
set -uo pipefail
. "$FLEET_SCRIPTS/board-lib.sh"
. "$FLEET_SCRIPTS/adapters/local/local-lib.sh"

[ "${1:-}" = "--allow-truncated" ] && shift
STATE="$1"
fl_require_store
CARDS="$(fl_cards_dir)"
shopt -s nullglob
FILES=("$CARDS"/*.json)
OUT="$(jq -c -s 'map(select(type == "object") | {number, title, state})' ${FILES[@]+"${FILES[@]}"} 2>/dev/null)" || {
  for f in ${FILES[@]+"${FILES[@]}"}; do
    jq -e 'type == "object"' "$f" >/dev/null 2>&1 || fb_die 1 "card file is not valid JSON: $f"
  done
  fb_die 1 "cannot read the card files in $CARDS"
}
PORT="$(fb_cfg board.port)"
jq -c --arg s "$STATE" --arg p "$PORT" \
  '[.[] | select(.state == $s)] | sort_by(.number) | map({number, title, url: ("http://127.0.0.1:" + $p + "/cards/" + (.number | tostring))})' <<<"$OUT"
