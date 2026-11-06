#!/usr/bin/env bash
set -uo pipefail
. "$FLEET_SCRIPTS/board-lib.sh"
. "$FLEET_SCRIPTS/adapters/local/local-lib.sh"

ME="$(fb_login)" || exit 1
fl_require_store
CARD="$(fl_read_card "$1")" || exit $?
STATE="$(jq -r '.state // ""' <<<"$CARD")"
IN=0
for s in $FB_STATES; do [ "$s" = "$STATE" ] && IN=1; done
if [ "$IN" = 0 ]; then
  printf 'fleet-board: warning: card #%s has an unknown state: %s\n' "$1" "$STATE" >&2
  STATE=null
fi

jq -c --arg m "$FB_MARKER" --arg me "$ME" --arg s "$STATE" --arg url "$(fl_url "$1")" '
  def find_note:
    [(.comments // [])[] | select(.body | startswith($m)) | select(.author == $me)] | last;
  (find_note) as $n |
  {
    number: .number,
    title: .title,
    url: $url,
    state: ($s | if . == "null" then null else . end),
    body: .body,
    labels: (.labels // []),
    manager_note: (if $n then ($n.body | sub("^[^\n]*\n"; "")) else null end),
    manager_note_id: (if $n then $n.id else null end),
    item_id: null,
    comments: [(.comments // [])[] | {id, author, body, created_at}]
  }' <<<"$CARD"
