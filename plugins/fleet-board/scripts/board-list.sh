#!/usr/bin/env bash
set -uo pipefail
unset CDPATH # a relative cd must not follow CDPATH (it would also echo the path)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"
# --allow-truncated is accepted and ignored: the local store lists every card
# (no listing limit). cleanup-done.sh still passes it.
[ "${1:-}" = "--allow-truncated" ] && shift
# --all: list every configured state in this one process, one JSON array per line
if [ "${1:-}" = "--all" ]; then
  [ $# -eq 1 ] || fb_die 2 "usage: board-list.sh [--allow-truncated] <state> | --all"
  fb_load_config
  for s in $FB_STATES; do
    bash "$FLEET_SCRIPTS/adapters/local/list.sh" "$s" || exit $?
  done
  exit 0
fi
[ $# -eq 1 ] || fb_die 2 "usage: board-list.sh [--allow-truncated] <state>"
fb_load_config # before the state check: the valid states include the config's review stages
fb_valid_state "$1" || fb_die 2 "invalid state: $1"
exec bash "$FLEET_SCRIPTS/adapters/local/list.sh" "$@"
