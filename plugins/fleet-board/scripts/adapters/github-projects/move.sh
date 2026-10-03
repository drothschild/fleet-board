#!/usr/bin/env bash
set -uo pipefail
. "$FLEET_SCRIPTS/board-lib.sh"
. "$FLEET_SCRIPTS/adapters/github-projects/common.sh"

N="$1"
TARGET="$2"

CACHE="$FLEET_ROOT/$(fb_cfg worktrees.dir)/.cache/projects.json"
fp_ensure_cache "$CACHE" || exit 1

fb_lock "$N"

# Verify acceptance for ready state
if [ "$TARGET" = "ready" ]; then
  ISSUE="$(gh api "repos/$FLEET_REPO/issues/$N")" || fb_die 1 "cannot read card #$N"
  if ! fb_has_acceptance "$(jq -r '.body // ""' <<<"$ISSUE")"; then
    fb_die 1 "card #$N has no '## Acceptance' section; refusing to move it to ready"
  fi
fi

# Get target status name from mapping
TARGET_NAME="$(fb_state_name "$TARGET")"
# Resolve the option before touching the board, so an unknown column never
# adds the card to the project.
OPT_ID="$(fp_option_id "$TARGET_NAME" "$CACHE")" || exit 1

ITEM_DATA="$(fp_item_for "$N")" || exit 1
if [ -z "$ITEM_DATA" ]; then
  ITEM_ID="$(gh project item-add "$(fb_cfg board.project_number)" --owner "$(fp_get_owner)" \
    --url "https://github.com/$FLEET_REPO/issues/$N" --format json | jq -r '.id // empty')" || \
    fb_die 1 "failed to add #$N to the project"
  [ -n "$ITEM_ID" ] || fb_die 1 "failed to add #$N to the project (no item id)"
  CURRENT_STATUS=""
else
  ITEM_ID="${ITEM_DATA%%$'\t'*}"
  CURRENT_STATUS="${ITEM_DATA#*$'\t'}"
fi

[ "$CURRENT_STATUS" = "$TARGET_NAME" ] && exit 0

gh project item-edit --id "$ITEM_ID" --project-id "$(jq -r .project_id "$CACHE")" \
  --field-id "$(jq -r .field_id "$CACHE")" --single-select-option-id "$OPT_ID" >/dev/null || \
  fb_die 1 "failed to move #$N to $TARGET_NAME"
