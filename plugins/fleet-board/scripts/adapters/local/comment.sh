#!/usr/bin/env bash
set -uo pipefail
. "$FLEET_SCRIPTS/board-lib.sh"
. "$FLEET_SCRIPTS/adapters/local/local-lib.sh"

N="$1"
ME="$(fb_login)" || exit 1
fl_require_store
fb_lock "$N"
CARD="$(fl_read_card "$N")" || exit $?
TMP="$(mktemp)" || fb_die 1 "cannot create a temporary file"
trap 'rm -f "$TMP"; rm -rf "$FB_LOCK"' EXIT
jq --arg me "$ME" --rawfile b "$2" --arg now "$(fl_now)" '
  (.next_comment_id // ((.comments // []) | map(.id) | max // 0) + 1) as $id
  | .comments = (.comments // []) + [{id: $id, author: $me, body: $b, created_at: $now}]
  | .next_comment_id = $id + 1
  | .updated_at = $now' <<<"$CARD" > "$TMP" \
  || fb_die 1 "cannot update card #$N"
fl_write_card "$N" "$TMP" || exit 1
