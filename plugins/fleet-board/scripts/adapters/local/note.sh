#!/usr/bin/env bash
set -uo pipefail
. "$FLEET_SCRIPTS/board-lib.sh"
. "$FLEET_SCRIPTS/adapters/local/local-lib.sh"

N="$1"
ME="$(fb_login)" || exit 1
fl_require_store
fb_lock "$N"
CARD="$(fl_read_card "$N")" || exit $?
BODY="$(mktemp)" || fb_die 1 "cannot create a temporary file"
TMP="$(mktemp)" || { rm -f "$BODY"; fb_die 1 "cannot create a temporary file"; }
trap 'rm -f "$BODY" "$TMP"; rm -rf "$FB_LOCK"' EXIT
{
  printf '%s\n' "$FB_MARKER"
  cat "$2"
} > "$BODY"
ID="$(fl_next_comment_id "$CARD")" || fb_die 1 "cannot read the comments of card #$N"
jq --argjson id "$ID" --arg m "$FB_MARKER" --arg me "$ME" --rawfile b "$BODY" --arg now "$(fl_now)" '
  (.comments // []) as $cs
  | ([range(0; $cs | length) | select(($cs[.].body | type) == "string" and ($cs[.].body | startswith($m))) | select($cs[.].author == $me)] | last) as $i
  | if $i != null then
      .comments[$i].body = $b | .comments[$i].updated_at = $now
    else
      .comments = $cs + [{id: $id, author: $me, body: $b, created_at: $now}]
      | .next_comment_id = $id + 1
    end
  | .updated_at = $now' <<<"$CARD" > "$TMP" \
  || fb_die 1 "cannot update card #$N"
fl_write_card "$N" "$TMP" || exit 1
