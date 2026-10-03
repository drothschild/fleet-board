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
BACKLOG_OPT="$(fp_option_id "$(fb_state_name backlog)" "$CACHE")" || exit 1

# The issue gets the extra labels only; on Projects the state is the Status column.
URL="$(gh issue create --repo "$FLEET_REPO" --title "$TITLE" --body-file "$BODY_FILE" ${args[@]+"${args[@]}"})" || \
  fb_die 1 "failed to create issue"

PN="$(fb_cfg board.project_number)"
PO="$(fp_get_owner)"
ITEM_ID="$(gh project item-add "$PN" --owner "$PO" --url "$URL" --format json | jq -r '.id // empty')" || \
  fb_die 1 "failed to add $URL to project $PN"
[ -n "$ITEM_ID" ] || fb_die 1 "failed to add $URL to project $PN (no item id)"

gh project item-edit --id "$ITEM_ID" --project-id "$(jq -r .project_id "$CACHE")" \
  --field-id "$(jq -r .field_id "$CACHE")" --single-select-option-id "$BACKLOG_OPT" >/dev/null || \
  fb_die 1 "failed to move $URL to $(fb_state_name backlog)"

jq -nc --arg u "$URL" '{number: ($u | split("/") | last | tonumber), url: $u}'
