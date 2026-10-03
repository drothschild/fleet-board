#!/usr/bin/env bash
set -uo pipefail
. "$FLEET_SCRIPTS/board-lib.sh"

gh issue comment "$1" --repo "$FLEET_REPO" --body-file "$2" >/dev/null
