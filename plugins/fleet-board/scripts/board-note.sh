#!/usr/bin/env bash
set -uo pipefail
unset CDPATH # a relative cd must not follow CDPATH (it would also echo the path)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"
[ $# -eq 2 ] || fb_die 2 "usage: board-note.sh <number> <file>"
fb_valid_number "$1" || fb_die 2 "card number must be numeric, got: $1"
[ -f "$2" ] || fb_die 2 "file not found: $2"
fb_load_config
exec bash "$FLEET_SCRIPTS/adapters/$(fb_cfg board.backend)/note.sh" "$@"
