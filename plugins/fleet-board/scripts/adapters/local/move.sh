#!/usr/bin/env bash
set -uo pipefail
. "$FLEET_SCRIPTS/board-lib.sh"
. "$FLEET_SCRIPTS/adapters/local/local-lib.sh"

N="$1"; TARGET="$2"
fb_valid_state "$TARGET" || fb_die 2 "invalid state: $TARGET"
fl_require_store
fb_lock "$N"
CARD="$(fl_read_card "$N")" || exit $?
if [ "$TARGET" = ready ] && ! fb_card_has_acceptance "$CARD"; then
  fb_die 1 "card #$N has no acceptance criteria (its acceptance field is empty); refusing to move it to ready"
fi
# Scope paths are checked only on the way in from Backlog (or an unreadable state). A card returned to
# Ready from a later column (a cancel, a stuck release, an unblock) is not refused: the planner holds a
# Ready card with no Scope paths, and refusing would leave it in a column that holds other cards' starts.
FROM="$(jq -r '.state // ""' <<<"$CARD")"
if [ "$TARGET" = ready ] && { [ "$FROM" = backlog ] || ! fb_valid_state "$FROM"; } \
    && ! fb_card_has_scope_paths "$(jq -r '.body // ""' <<<"$CARD")"; then
  fb_die 1 "card #$N has no Scope paths; refusing to move it to ready"
fi
[ "$(jq -r '.state // ""' <<<"$CARD")" = "$TARGET" ] && exit 0
TMP="$(mktemp)" || fb_die 1 "cannot create a temporary file"
trap 'rm -f "$TMP"; fb_lock_release "$FB_LOCK"' EXIT
# Into Ready from another state re-stamps the card, unless the supervisor moves it
PREM=null
if [ "$TARGET" = ready ] && [ "${FLEET_BOARD_ACTOR:-}" != supervisor ]; then PREM="$(fl_premise_json move)"; fi
# Out of Blocked by a person: an open premise proposal is rejected (the supervisor's own move keeps it)
CLEAR=false
if [ "$FROM" = blocked ] && [ "${FLEET_BOARD_ACTOR:-}" != supervisor ] \
    && jq -e '(.proposal | type) == "object"' <<<"$CARD" >/dev/null 2>&1; then CLEAR=true; fi
jq --arg s "$TARGET" --arg now "$(fl_now)" --argjson prem "$PREM" --argjson clear "$CLEAR" \
  '.state = $s | .updated_at = $now | (if $prem != null then .premise = $prem else . end)
   | (if $clear then .proposal = null else . end)' <<<"$CARD" > "$TMP" \
  || fb_die 1 "cannot update card #$N"
fl_write_card "$N" "$TMP" || exit 1
[ "$CLEAR" = true ] && fl_premise_decision "$N" rejected
# Out of Blocked: a merger attention's leftovers go, so a person never edits the note
if [ "$(jq -r '.state // ""' <<<"$CARD")" = blocked ]; then
  PATCH="$(mktemp)" || fb_die 1 "cannot create a temporary file"
  printf '%s' '{"merger":null,"merge_refusal":null,"merge_retry":null}' > "$PATCH"
  fb_lock_release "$FB_LOCK"   # note.sh takes the card's lock itself
  bash "$FLEET_SCRIPTS/note.sh" merge "$N" "$PATCH" >/dev/null 2>&1 \
    || echo "fleet-board: warning: could not clear the merger fields in the note of card #$N" >&2
  rm -f "$PATCH"
fi
