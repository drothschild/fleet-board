#!/usr/bin/env bash
set -uo pipefail
unset CDPATH # a relative cd must not follow CDPATH (it would also echo the path)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"
[ $# -eq 1 ] || fb_die 2 "usage: board-read.sh <number>"
fb_valid_number "$1" || fb_die 2 "card number must be numeric, got: $1"
fb_load_config
exec bash "$FLEET_SCRIPTS/adapters/$(fb_cfg board.backend)/read.sh" "$@"
