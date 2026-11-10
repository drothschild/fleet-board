#!/usr/bin/env bash
set -uo pipefail
unset CDPATH # a relative cd must not follow CDPATH (it would also echo the path)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

fb_load_config

exec bash "$FLEET_SCRIPTS/adapters/local/cache-clear.sh" "$@"
