#!/usr/bin/env bash
set -uo pipefail
. "$FLEET_SCRIPTS/board-lib.sh"
. "$FLEET_SCRIPTS/adapters/local/local-lib.sh"

ME="$(fb_login)" || exit 1
fl_require_store
# One jq both checks the card file is a JSON object (as fl_read_card does), validates the state and
# builds the read. Its first output line is the raw state, the second whether it is a known state,
# the third the read.
CARD_FILE="$(fl_card_file "$1")"
[ -f "$CARD_FILE" ] || fb_die 1 "card #$1 not found in $(fl_cards_dir)"
RES="$(jq -cr --arg m "$FB_MARKER" --arg me "$ME" --arg url "$(fl_url "$1")" --arg states "$FB_STATES" '
  def find_note:
    [(.comments // [])[] | select((.body | type) == "string" and (.body | startswith($m))) | select(.author == $me)] | last;
  if type != "object" then error("not a card") else . end
  | (.state // "") as $st
  | ($st != "" and any($states | split(" ")[]; . == ($st | tostring))) as $known
  | (find_note) as $n
  | ($st | tostring | gsub("\n"; " ")), $known,
    {
      number: .number,
      title: .title,
      url: $url,
      state: (if $known then $st else null end),
      body: (.body // ""),
      acceptance: (.acceptance // []),
      blocked_by: (.blocked_by // []),
      pr_url: (.pr_url // null),
      repo: (.repo // null),
      labels: (.labels // []),
      manager_note: (if $n then ($n.body | sub("^[^\n]*\n"; "")) else null end),
      manager_note_id: (if $n then $n.id else null end),
      item_id: null,
      comments: [(.comments // [])[] | {id, author, body, created_at}]
    }' "$CARD_FILE" 2>/dev/null)" \
  || fb_die 1 "card #$1 is not valid JSON: $CARD_FILE"
STATE="${RES%%$'\n'*}"; RES="${RES#*$'\n'}"
KNOWN="${RES%%$'\n'*}"; RES="${RES#*$'\n'}"
if [ "$KNOWN" != true ]; then
  printf 'fleet-board: warning: card #%s has an unknown state: %s\n' "$1" "$STATE" >&2
fi
printf '%s\n' "$RES"
