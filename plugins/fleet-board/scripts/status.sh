#!/usr/bin/env bash
# status.sh - prints the board, one section per state.
#
# Usage: status.sh [--all]
#
# Sections, in order: ready, in_progress, in_review, human_qa, blocked; with
# --all also backlog, done and wont_do. Each section is the state name on
# its own line, then one line per card:
#   #<n> <title> · round <r> · PR #<pr> · <implementor>/<reviewer>
# with the values from the card's manager note and "—" for a missing one
# ("PR —" when there is no PR). An empty section prints "(none)". A card
# whose note cannot be read prints "#<n> <title> · note unreadable".
#
# Exit codes:
#   0 - board printed
#   1 - a column could not be listed, or a card's note could not be read
#   2 - usage error

set -uo pipefail
unset CDPATH # a relative cd must not follow CDPATH (it would also echo the path)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

STATES="ready in_progress in_review human_qa blocked"
case "$#:${1:-}" in
  0:) ;;
  1:--all) STATES="$STATES backlog done wont_do" ;;
  *) fb_die 2 "usage: status.sh [--all]" ;;
esac

fb_load_config

RC=0
for st in $STATES; do
  LIST="$(bash "$FLEET_SCRIPTS/board-list.sh" "$st")" || fb_die 1 "cannot list the $st column"
  ROWS="$(jq -c 'if type == "array" then .[] | {number, title} else error("not a list") end' <<<"$LIST" 2>/dev/null)" \
    || fb_die 1 "cannot parse the $st column"
  printf '%s\n' "$st"
  if [ -z "$ROWS" ]; then
    printf '  (none)\n'
    continue
  fi
  while IFS= read -r row; do
    n="$(jq -r .number <<<"$row")"
    title="$(jq -r '.title // "" | gsub("[[:cntrl:]]"; " ")' <<<"$row")"
    fb_valid_number "$n" || fb_die 1 "the $st column lists a non-numeric card: $n"
    if ! note="$(bash "$FLEET_SCRIPTS/note.sh" get "$n" </dev/null)"; then
      printf '  #%s %s · note unreadable\n' "$n" "$title"
      RC=1
      continue
    fi
    jq -r --arg n "$n" --arg t "$title" '
      def v: if . == null then "—" else tostring | gsub("[[:cntrl:]]"; " ") end;
      def m($k): if type == "object" then .[$k] | v else "—" end;
      "  #\($n) \($t) · round \(.round | v) · PR \(if .pr == null then "—" else "#\(.pr)" end) · \(.models | m("implementor"))/\(.models | m("reviewer"))"' \
      <<<"$note" || { printf '  #%s %s · note unreadable\n' "$n" "$title"; RC=1; }
  done <<<"$ROWS"
done
exit "$RC"
