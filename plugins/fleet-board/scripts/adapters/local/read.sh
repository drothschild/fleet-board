#!/usr/bin/env bash
set -uo pipefail
. "$FLEET_SCRIPTS/board-lib.sh"
. "$FLEET_SCRIPTS/adapters/local/local-lib.sh"

ME="$(fb_login)" || exit 1
fl_require_store
# One jq both checks the card file is a JSON object (as fl_read_card does) and reads its state
CARD_FILE="$(fl_card_file "$1")"
[ -f "$CARD_FILE" ] || fb_die 1 "card #$1 not found in $(fl_cards_dir)"
CARD="$(cat "$CARD_FILE")"
STATE="$(jq -r 'if type == "object" then .state // "" else error("not a card") end' <<<"$CARD" 2>/dev/null)" \
  || fb_die 1 "card #$1 is not valid JSON: $CARD_FILE"
IN=0
for s in $FB_STATES; do [ "$s" = "$STATE" ] && IN=1; done
if [ "$IN" = 0 ]; then
  printf 'fleet-board: warning: card #%s has an unknown state: %s\n' "$1" "$STATE" >&2
  STATE=null
fi

jq -c --arg m "$FB_MARKER" --arg me "$ME" --arg s "$STATE" --arg url "$(fl_url "$1")" '
  def find_note:
    [(.comments // [])[] | select((.body | type) == "string" and (.body | startswith($m))) | select(.author == $me)] | last;
  (find_note) as $n |
  {
    number: .number,
    title: .title,
    url: $url,
    state: ($s | if . == "null" then null else . end),
    body: (.body // ""),
    acceptance: (.acceptance // []),
    blocked_by: (.blocked_by // []),
    pr_url: (.pr_url // null),
    labels: (.labels // []),
    manager_note: (if $n then ($n.body | sub("^[^\n]*\n"; "")) else null end),
    manager_note_id: (if $n then $n.id else null end),
    item_id: null,
    comments: [(.comments // [])[] | {id, author, body, created_at}]
  }' <<<"$CARD"
