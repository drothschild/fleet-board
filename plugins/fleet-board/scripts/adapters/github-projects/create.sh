#!/usr/bin/env bash
set -uo pipefail
. "$FLEET_SCRIPTS/board-lib.sh"
. "$FLEET_SCRIPTS/adapters/github-projects/common.sh"

CACHE="$FLEET_ROOT/$(fb_cfg worktrees.dir)/.cache/projects.json"
fp_ensure_cache "$CACHE" || exit 1

# Save title and body file
TITLE="$1"
BODY_FILE="$2"
shift 2

# board-create.sh has already validated the args: only "--label <non-empty>" pairs.
args=()
while [ $# -gt 0 ]; do
  args+=(--label "$2")
  shift 2
done

# Resolve the Backlog option before creating anything, so an unmapped column
# leaves no orphan issue behind (and a retry makes no duplicate).
BACKLOG_OPT="$(fp_option_id "$(fb_state_name "${FB_CREATE_STATE:-backlog}")" "$CACHE")" || exit 1

# The issue gets the extra labels only; on Projects the state is the Status column.
URL="$(gh issue create --repo "$FLEET_REPO" --title "$TITLE" --body-file "$BODY_FILE" ${args[@]+"${args[@]}"})" || \
  fb_die 1 "failed to create issue"

PN="$(fb_cfg board.project_number)"
PO="$(fp_get_owner)"
# "Content already exists in this project" means the issue is on the board
# already (an earlier add ran, or an automation added it): not a failure. Its
# item id is looked up so the column is still set; when that lookup fails the
# column stays as it is and the create still succeeds.
ADD_ERR="$(mktemp)" || fb_die 1 "cannot create a temp file"
ADD_OUT="$(gh project item-add "$PN" --owner "$PO" --url "$URL" --format json 2>"$ADD_ERR")"
ADD_RC=$?
ADD_MSG="$ADD_OUT
$(cat "$ADD_ERR")"
rm -f "$ADD_ERR"
if [ "$ADD_RC" -eq 0 ]; then
  ITEM_ID="$(printf '%s' "$ADD_OUT" | jq -r '.id // empty')" || fb_die 1 "failed to add $URL to project $PN"
  [ -n "$ITEM_ID" ] || fb_die 1 "failed to add $URL to project $PN (no item id)"
elif printf '%s' "$ADD_MSG" | grep -qF 'Content already exists in this project'; then
  ITEM_ID="$(gh project item-list "$PN" --owner "$PO" --format json --limit 1000 2>/dev/null \
    | jq -r --arg u "$URL" '.items[]? | select(.content.url == $u) | .id' 2>/dev/null | head -n 1)" || ITEM_ID=""
  if [ -z "$ITEM_ID" ]; then
    printf 'fleet-board: warning: %s is already on project %s; its column was not set\n' "$URL" "$PN" >&2
    jq -nc --arg u "$URL" '{number: ($u | split("/") | last | tonumber), url: $u}'
    exit 0
  fi
else
  fb_die 1 "failed to add $URL to project $PN"
fi

gh project item-edit --id "$ITEM_ID" --project-id "$(jq -r .project_id "$CACHE")" \
  --field-id "$(jq -r .field_id "$CACHE")" --single-select-option-id "$BACKLOG_OPT" >/dev/null || \
  fb_die 1 "failed to move $URL to $(fb_state_name "${FB_CREATE_STATE:-backlog}")"

jq -nc --arg u "$URL" '{number: ($u | split("/") | last | tonumber), url: $u}'
