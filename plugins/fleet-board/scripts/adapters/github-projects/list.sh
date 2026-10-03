#!/usr/bin/env bash
set -uo pipefail
. "$FLEET_SCRIPTS/board-lib.sh"
. "$FLEET_SCRIPTS/adapters/github-projects/common.sh"

CACHE="$FLEET_ROOT/$(fb_cfg worktrees.dir)/.cache/projects.json"
fp_ensure_cache "$CACHE" || exit 1

NAME="$(fb_state_name "$1")"
PN="$(fb_cfg board.project_number)"
PO="$(fp_get_owner)"

LIMIT="$(fb_list_limit 1000)" || exit 1
ITEMS="$(gh project item-list "$PN" --owner "$PO" --format json --limit "$LIMIT")" || \
  fb_die 1 "cannot list items of project $PN (owner $PO)"
# item-list returns items of every status and repo, so the raw count is what
# the limit truncates. Truncation happens before the status filter below, so
# under --allow-truncated any column (done included) may come back partial;
# cleanup-done.sh accepts that, since a missed done card only leaves a
# worktree behind.
N="$(jq '.items | length' <<<"$ITEMS" 2>/dev/null)"
if fb_valid_number "$N"; then
  fb_list_truncated "$N" "$LIMIT" "gh project item-list (project $PN)" \
    "archive done items in project $PN (item-list counts every item, done ones and other repos' included)"
fi
OUT="$(jq -c --arg repo "$FLEET_REPO" --arg status "$NAME" \
  '[.items[] |
    select(.content.type == "Issue") |
    select(.content.repository == $repo) |
    select(.status == $status)] |
  sort_by(.content.number) |
  map({number: .content.number, title: .content.title, url: .content.url})' <<<"$ITEMS" 2>/dev/null)" || \
  fb_die 1 "cannot parse the items of project $PN (owner $PO)"
# jq exits 0 with no output on empty input, so an empty reply lands here
[ -n "$OUT" ] || fb_die 1 "cannot parse the items of project $PN (owner $PO): empty reply"
printf '%s\n' "$OUT"
