#!/usr/bin/env bash
set -uo pipefail
. "$FLEET_SCRIPTS/board-lib.sh"
. "$FLEET_SCRIPTS/adapters/local/local-lib.sh"

N="$1"; TARGET="$2"
fb_valid_state "$TARGET" || fb_die 2 "invalid state: $TARGET"
fl_require_store
fb_lock "$N"
CARD="$(fl_read_card "$N")" || exit $?
if [ "${FLEET_BOARD_ENFORCE_QA:-}" = 1 ] && [ "$TARGET" != human_qa ] && [ "$(jq -r '.state // ""' <<<"$CARD")" = human_qa ]; then
  fb_die 1 "refusing to move #$N out of Human QA"
fi
if [ "$TARGET" = ready ] && ! fb_has_acceptance "$(jq -r '.body // ""' <<<"$CARD")"; then
  fb_die 1 "card #$N has no '## Acceptance' section; refusing to move it to ready"
fi
[ "$(jq -r '.state // ""' <<<"$CARD")" = "$TARGET" ] && exit 0
TMP="$(mktemp)" || fb_die 1 "cannot create a temporary file"
trap 'rm -f "$TMP"; rm -rf "$FB_LOCK"' EXIT
jq --arg s "$TARGET" --arg now "$(fl_now)" '.state = $s | .updated_at = $now' <<<"$CARD" > "$TMP" \
  || fb_die 1 "cannot update card #$N"
fl_write_card "$N" "$TMP" || exit 1
