#!/usr/bin/env bash
set -uo pipefail
. "$FLEET_SCRIPTS/board-lib.sh"
. "$FLEET_SCRIPTS/adapters/local/local-lib.sh"

[ "${1:-}" = "--allow-truncated" ] && shift
STATE="$1"
fl_require_store
CARDS="$(fl_cards_dir)"
PORT="$(fb_cfg board.port)"
set -- "$CARDS"/*.json
if [ ! -e "$1" ]; then echo '[]'; exit 0; fi
# One jq reads every card file. A file that is not a JSON object makes it fail;
# the slow loop then finds the file to name.
jq -nc --arg s "$STATE" --arg p "$PORT" '
  [inputs | if type == "object" then {number, title, state} else error("not a card") end]
  | [.[] | select(.state == $s)] | sort_by(.number)
  | map({number, title, url: ("http://127.0.0.1:" + $p + "/cards/" + (.number | tostring))})' "$@" 2>/dev/null && {
  # a card whose state is not a string sits in no column: say so on stderr
  jq -r 'select(type == "object" and (.state | type) != "string") | "fleet-board: warning: card #\(.number) has a state that is not a string; it is in no column"' "$@" >&2 2>/dev/null
  exit 0
}
for f in "$@"; do
  jq -ce 'select(type == "object") | {number, title, state}' "$f" >/dev/null 2>&1 \
    || fb_die 1 "card file is not valid JSON: $f"
done
fb_die 1 "cannot list the cards in $CARDS"
