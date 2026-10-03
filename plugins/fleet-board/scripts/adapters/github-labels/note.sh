#!/usr/bin/env bash
set -uo pipefail
. "$FLEET_SCRIPTS/board-lib.sh"

# Build temp file with marker + content
ME="$(fb_login)" || exit 1

TMP="$(mktemp)"
trap "rm -f '$TMP'" EXIT
{
  printf '%s\n' "$FB_MARKER"
  cat "$2"
} > "$TMP"

# Fetch comments; fail closed if fetch fails
RAW="$(gh api --paginate "repos/$FLEET_REPO/issues/$1/comments")" || fb_die 1 "cannot read comments for #$1"
COMMENTS="$(printf '%s' "$RAW" | jq -s 'add // []')"

# Find the id of the last comment whose body starts with marker AND author is ME
ID="$(jq -r --arg m "$FB_MARKER" --arg me "$ME" '([.[] | select(.body | startswith($m)) | select(.user.login == $me)] | last | .id // empty)' <<<"$COMMENTS")"

if [ -n "$ID" ]; then
  # Replace existing note
  jq -n --rawfile b "$TMP" '{body:$b}' | gh api -X PATCH "repos/$FLEET_REPO/issues/comments/$ID" --input - >/dev/null \
    || fb_die 1 "failed to update note on #$1"
else
  # Create new note and pin it
  ID="$(jq -n --rawfile b "$TMP" '{body:$b}' | gh api -X POST "repos/$FLEET_REPO/issues/$1/comments" --input - | jq -r .id)" \
    || fb_die 1 "failed to create note on #$1"
  case "$ID" in
    ''|*[!0-9]*) fb_die 1 "failed to create note on #$1 (no comment id in response)" ;;
  esac
  gh api -X PUT "repos/$FLEET_REPO/issues/comments/$ID/pin" >/dev/null 2>&1 \
    || printf 'fleet-board: warning: could not pin note on #%d (marker still identifies it)\n' "$1" >&2
fi
