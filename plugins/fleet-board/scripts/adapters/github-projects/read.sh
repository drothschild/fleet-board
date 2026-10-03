#!/usr/bin/env bash
set -uo pipefail
. "$FLEET_SCRIPTS/board-lib.sh"
. "$FLEET_SCRIPTS/adapters/github-projects/common.sh"

CACHE="$FLEET_ROOT/$(fb_cfg worktrees.dir)/.cache/projects.json"
fp_ensure_cache "$CACHE" || exit 1

# Get base from labels adapter (which handles the issue body, labels, comments, etc.)
BASE="$(bash "$FLEET_SCRIPTS/adapters/github-labels/read.sh" "$1")" || exit 1

ITEM_DATA="$(fp_item_for "$1")" || exit 1
ITEM_ID=""; STATE=""
if [ -n "$ITEM_DATA" ]; then
  ITEM_ID="${ITEM_DATA%%$'\t'*}"
  STATUS_NAME="${ITEM_DATA#*$'\t'}"
  [ -n "$STATUS_NAME" ] && STATE="$(fb_canonical_of "$STATUS_NAME")"
fi

# The labels read's .state means nothing here; the Status column is the state.
jq --arg state "$STATE" --arg item "$ITEM_ID" \
  '.state = (if $state == "" then null else $state end)
   | .item_id = (if $item == "" then null else $item end)' <<<"$BASE"
