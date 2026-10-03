#!/usr/bin/env bash
set -uo pipefail
. "$FLEET_SCRIPTS/board-lib.sh"

L="$(fb_state_name "$1")"
ST=open
if [ "$1" = "done" ] || [ "$1" = "wont_do" ]; then
  ST=all
fi

LIMIT="$(fb_list_limit 500)" || exit 1
RAW="$(gh issue list --repo "$FLEET_REPO" --label "$L" --state "$ST" --json number,title,url,labels --limit "$LIMIT")" || \
  fb_die 1 "cannot list issues labelled $L in $FLEET_REPO"
N="$(jq 'length' <<<"$RAW" 2>/dev/null)" || fb_die 1 "cannot parse the issues labelled $L in $FLEET_REPO"
fb_valid_number "$N" || fb_die 1 "cannot parse the issues labelled $L in $FLEET_REPO"
if [ "$ST" = all ]; then
  REMEDY="remove the $L label from old closed issues (the done and wont_do columns list closed issues too, so they grow without bound)"
else
  REMEDY="reduce the open issues labelled $L"
fi
fb_list_truncated "$N" "$LIMIT" "gh issue list (label $L, state $ST)" "$REMEDY"
jq -c --arg l "$L" '[.[] | select(.labels | map(.name) | index($l))] | sort_by(.number) | map({number,title,url})' <<<"$RAW"
