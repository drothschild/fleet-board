#!/usr/bin/env bash
# edit.sh <n> <title-file> <body-file> <labels-json>: local-only, called by the web server.
# Empty file arguments and null labels leave those fields unchanged.
set -uo pipefail
unset CDPATH
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/board-lib.sh"
. "$FB_SCRIPTS/adapters/local/local-lib.sh"

[ $# -eq 4 ] || fb_die 2 "usage: edit.sh <number> <title-file> <body-file> <labels-json>"
N="$1"; TITLE_FILE="$2"; BODY_FILE="$3"; LABELS="$4"
fb_valid_number "$N" || fb_die 2 "card number must be numeric, got: $N"
[ -z "$TITLE_FILE" ] || [ -f "$TITLE_FILE" ] || fb_die 2 "file not found: $TITLE_FILE"
[ -z "$BODY_FILE" ] || [ -f "$BODY_FILE" ] || fb_die 2 "file not found: $BODY_FILE"
jq -e '. == null or (type == "array" and all(.[]; type == "string"))' >/dev/null 2>&1 <<<"$LABELS" \
  || fb_die 2 "labels must be null or a JSON array of strings"
fb_load_config
fl_require_store
fb_lock "$N"
CARD="$(fl_read_card "$N")" || exit $?
TMP="$(mktemp)" || fb_die 1 "cannot create a temporary file"
trap 'rm -f "$TMP"; rm -rf "$FB_LOCK"' EXIT
jq --rawfile t "${TITLE_FILE:-/dev/null}" --rawfile b "${BODY_FILE:-/dev/null}" \
  --arg title_file "$TITLE_FILE" --arg body_file "$BODY_FILE" \
  --argjson l "$LABELS" --arg now "$(fl_now)" '
  (if $title_file != "" then .title = ($t | sub("\n+$"; "")) else . end)
  | (if $body_file != "" then .body = $b else . end)
  | (if $l != null then .labels = $l else . end)
  | .updated_at = $now' <<<"$CARD" > "$TMP" \
  || fb_die 1 "cannot update card #$N"
fl_write_card "$N" "$TMP" || exit 1
