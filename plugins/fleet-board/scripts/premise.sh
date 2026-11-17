#!/usr/bin/env bash
# premise.sh - the commit a card last agreed with.
#
# Usage:
#   premise.sh stamp <n> --by create|edit|move|check|approve [--sha <40-hex>]
#   premise.sh show <n>
#
# stamp writes the card's premise {sha, at, by}; the sha is --sha, else the local
# head of the default branch. show prints the stored premise, or null when it is
# absent or not shaped {sha: 40-hex, at, by: a known value}.
#
# Exit codes: 0 done, 2 usage, 3 the card (or the default head) cannot be read.
set -uo pipefail
unset CDPATH
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

USAGE="usage: premise.sh stamp <n> --by <by> [--sha <40-hex>] | premise.sh show <n>"
[ $# -ge 2 ] || fb_die 2 "$USAGE"
VERB="$1"; N="$2"; shift 2
fb_valid_number "$N" || fb_die 2 "card number must be numeric, got: $N"
BY=""; SHA=""

case "$VERB" in
  stamp)
    while [ $# -gt 0 ]; do
      [ $# -ge 2 ] || fb_die 2 "$USAGE"
      case "$1" in
        --by) BY="$2" ;;
        --sha) SHA="$2" ;;
        *) fb_die 2 "$USAGE" ;;
      esac
      shift 2
    done
    case "$BY" in
      create|edit|move|check|approve) ;;
      *) fb_die 2 "--by must be create, edit, move, check or approve, got: $BY" ;;
    esac
    if [ -n "$SHA" ]; then
      printf '%s' "$SHA" | grep -Eq '^[0-9a-f]{40}$' || fb_die 2 "--sha must be 40 lowercase hex characters, got: $SHA"
    fi
    ;;
  show) [ $# -eq 0 ] || fb_die 2 "$USAGE" ;;
  *) fb_die 2 "$USAGE" ;;
esac

fb_load_config
. "$FB_SCRIPTS/adapters/local/local-lib.sh"
[ -f "$(fl_card_file "$N")" ] || fb_die 3 "card #$N not found in $(fl_cards_dir)"

if [ "$VERB" = show ]; then
  jq -c '(.premise as $p
      | if ($p | type) == "object" and ($p.sha | type) == "string" and ($p.sha | test("^[0-9a-f]{40}$"))
           and ($p.at | type) == "string"
           and (["create","edit","move","check","approve"] | index($p.by)) != null
        then $p else null end)' "$(fl_card_file "$N")" 2>/dev/null \
    || fb_die 3 "card #$N is not valid JSON"
  exit 0
fi

if [ -z "$SHA" ]; then
  SHA="$(fl_default_head)" || fb_die 3 "cannot read the default branch head"
fi
fb_lock "$N"
TMP="$(mktemp)" || fb_die 1 "cannot create a temporary file"
trap 'rm -f "$TMP"; fb_lock_release "$FB_LOCK"' EXIT
CARD="$(fl_read_card "$N")" || exit 3
jq --argjson p "$(fl_premise_json "$BY" "$SHA")" '.premise = $p' <<<"$CARD" > "$TMP" || fb_die 1 "cannot update card #$N"
fl_write_card "$N" "$TMP" || exit 1
