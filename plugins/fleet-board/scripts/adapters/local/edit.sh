#!/usr/bin/env bash
# edit.sh <n> <title-file> <body-file> <labels-json>: local-only, called by the web server.
# Rewrites title, body, labels and updated_at; never comments or state.
set -uo pipefail
unset CDPATH
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/board-lib.sh"
. "$FB_SCRIPTS/adapters/local/local-lib.sh"

[ $# -eq 4 ] || fb_die 2 "usage: edit.sh <number> <title-file> <body-file> <labels-json>"
N="$1"; TITLE_FILE="$2"; BODY_FILE="$3"; LABELS="$4"
fb_valid_number "$N" || fb_die 2 "card number must be numeric, got: $N"
[ -f "$TITLE_FILE" ] || fb_die 2 "file not found: $TITLE_FILE"
[ -f "$BODY_FILE" ] || fb_die 2 "file not found: $BODY_FILE"
jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null 2>&1 <<<"$LABELS" \
  || fb_die 2 "labels must be a JSON array of strings"
fb_load_config
fl_require_store
fb_lock "$N"
CARD="$(fl_read_card "$N")" || exit $?
TMP="$(mktemp)" || fb_die 1 "cannot create a temporary file"
trap 'rm -f "$TMP"; rm -rf "$FB_LOCK"' EXIT
jq --rawfile t "$TITLE_FILE" --rawfile b "$BODY_FILE" --argjson l "$LABELS" --arg now "$(fl_now)" '
  .title = ($t | sub("\n+$"; "")) | .body = $b | .labels = $l | .updated_at = $now' <<<"$CARD" > "$TMP" \
  || fb_die 1 "cannot update card #$N"
fl_write_card "$N" "$TMP" || exit 1
