#!/usr/bin/env bash
set -uo pipefail
unset CDPATH # a relative cd must not follow CDPATH (it would also echo the path)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

fb_load_config

# The local backend keeps no cache
[ "$(fb_cfg board.backend)" = "local" ] && exit 0

# Clear cache directory for Projects backend
CACHE_DIR="$FLEET_ROOT/$(fb_cfg worktrees.dir)/.cache"
rm -rf "$CACHE_DIR" || fb_die 1 "cannot clear $CACHE_DIR"

exit 0
