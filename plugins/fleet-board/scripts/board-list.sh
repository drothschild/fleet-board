#!/usr/bin/env bash
set -uo pipefail
unset CDPATH # a relative cd must not follow CDPATH (it would also echo the path)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"
# --allow-truncated: a reply at the list limit is printed with a warning
# instead of failing. Only for a caller that tolerates a partial column
# (cleanup-done.sh); every other caller must see the failure. The adapter reads
# FB_LIST_ALLOW_TRUNCATED, which is reset here so an inherited value cannot
# widen a plain listing.
FB_LIST_ALLOW_TRUNCATED=
if [ "${1:-}" = "--allow-truncated" ]; then
  FB_LIST_ALLOW_TRUNCATED=1
  shift
fi
export FB_LIST_ALLOW_TRUNCATED
[ $# -eq 1 ] || fb_die 2 "usage: board-list.sh [--allow-truncated] <state>"
fb_valid_state "$1" || fb_die 2 "invalid state: $1"
fb_load_config
exec bash "$FLEET_SCRIPTS/adapters/$(fb_cfg board.backend)/list.sh" "$@"
