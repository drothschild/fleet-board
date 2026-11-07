#!/usr/bin/env bash
set -uo pipefail
. "$FLEET_SCRIPTS/board-lib.sh"

N="$1"; TARGET="$2"; TL="$(fb_state_name "$TARGET")"
fb_lock "$N"
ISSUE="$(gh api "repos/$FLEET_REPO/issues/$N")" || fb_die 1 "cannot read card #$N"
if [ "$TARGET" = ready ] && ! fb_has_acceptance "$(jq -r '.body // ""' <<<"$ISSUE")"; then
  fb_die 1 "card #$N has no '## Acceptance' section; refusing to move it to ready"
fi
CURRENT="$(jq -r '.labels[].name' <<<"$ISSUE")"
if [ "${FLEET_BOARD_ENFORCE_QA:-}" = 1 ] && [ "$TARGET" != human_qa ] && printf '%s\n' "$CURRENT" | grep -Fxq -- "$(fb_state_name human_qa)"; then
  fb_die 1 "refusing to move #$N out of Human QA"
fi
HAS_TARGET=0
for s in $FB_STATES; do
  name="$(fb_state_name "$s")"
  if printf '%s\n' "$CURRENT" | grep -Fxq -- "$name"; then
    if [ "$s" = "$TARGET" ]; then HAS_TARGET=1; continue; fi
    gh issue edit "$N" --repo "$FLEET_REPO" --remove-label "$name" >/dev/null \
      || fb_die 1 "failed to remove label '$name' from #$N"
  fi
done
[ "$HAS_TARGET" -eq 1 ] && exit 0
gh issue edit "$N" --repo "$FLEET_REPO" --add-label "$TL" >/dev/null \
  || fb_die 1 "failed to add label '$TL' to #$N"
