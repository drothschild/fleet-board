#!/usr/bin/env bash
# label.sh <n> add|remove <label>: local-only, not a contract verb. Under the
# card lock, re-reads the card and adds the label (when absent) or removes it,
# rewriting only labels and updated_at; no write when nothing changes. Used by
# review-stages.sh route.
set -uo pipefail
unset CDPATH
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/board-lib.sh"
. "$FB_SCRIPTS/adapters/local/local-lib.sh"

[ $# -eq 3 ] || fb_die 2 "usage: label.sh <number> add|remove <label>"
N="$1"; OP="$2"; LABEL="$3"
fb_valid_number "$N" || fb_die 2 "card number must be numeric, got: $N"
case "$OP" in add|remove) ;; *) fb_die 2 "usage: label.sh <number> add|remove <label>" ;; esac
[ -n "$LABEL" ] || fb_die 2 "label must not be empty"
[ -n "${FLEET_CFG:-}" ] || fb_load_config
fl_require_store
fb_lock "$N"
CARD="$(fl_read_card "$N")" || exit $?
HAS="$(jq -r --arg l "$LABEL" '(.labels // []) | index($l) != null' <<<"$CARD")" \
  || fb_die 1 "cannot read the labels of card #$N"
if [ "$OP" = add ] && [ "$HAS" = true ]; then exit 0; fi
if [ "$OP" = remove ] && [ "$HAS" != true ]; then exit 0; fi
TMP="$(mktemp)" || fb_die 1 "cannot create a temporary file"
trap 'rm -f "$TMP"; fb_unlock' EXIT
jq --arg l "$LABEL" --arg op "$OP" --arg now "$(fl_now)" '
  .labels = (if $op == "add" then (.labels // []) + [$l] else [(.labels // [])[] | select(. != $l)] end)
  | .updated_at = $now' <<<"$CARD" > "$TMP" \
  || fb_die 1 "cannot update card #$N"
fl_write_card "$N" "$TMP" || exit 1
