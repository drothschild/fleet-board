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
[ "$(jq -r '.state // ""' <<<"$CARD")" = "$TARGET" ] && exit 0
TMP="$(mktemp)" || fb_die 1 "cannot create a temporary file"
trap 'rm -f "$TMP"; fb_unlock' EXIT
jq --arg s "$TARGET" --arg now "$(fl_now)" '.state = $s | .updated_at = $now' <<<"$CARD" > "$TMP" \
  || fb_die 1 "cannot update card #$N"
fl_write_card "$N" "$TMP" || exit 1
