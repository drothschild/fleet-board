#!/usr/bin/env bash
set -uo pipefail
. "$FLEET_SCRIPTS/board-lib.sh"
. "$FLEET_SCRIPTS/adapters/local/local-lib.sh"

TITLE="$1"
BODY_FILE="$2"
shift 2
labels=()
while [ $# -gt 0 ]; do
  if [ "$1" = "--label" ]; then labels+=("$2"); shift 2; else shift; fi
done

fl_require_store
N="$(fl_next_number)" || exit 1
LABELS_JSON="$(printf '%s\n' ${labels[@]+"${labels[@]}"} | jq -R . | jq -sc 'map(select(. != ""))')"
TMP="$(mktemp)" || fb_die 1 "cannot create a temporary file"
trap 'rm -f "$TMP"' EXIT
jq -n --argjson n "$N" --arg t "$TITLE" --rawfile b "$BODY_FILE" \
  --arg s "${FB_CREATE_STATE:-backlog}" --argjson l "$LABELS_JSON" --arg now "$(fl_now)" \
  '{number: $n, title: $t, body: $b, state: $s, labels: $l, next_comment_id: 1, comments: [], created_at: $now}' > "$TMP" \
  || fb_die 1 "cannot build card #$N"
fl_write_card "$N" "$TMP" || exit 1
jq -nc --argjson n "$N" --arg u "$(fl_url "$N")" '{number: $n, url: $u}'
