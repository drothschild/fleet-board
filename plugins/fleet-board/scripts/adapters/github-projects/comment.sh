#!/usr/bin/env bash
set -uo pipefail
. "$FLEET_SCRIPTS/board-lib.sh"

# Delegate to labels adapter
exec bash "$FLEET_SCRIPTS/adapters/github-labels/comment.sh" "$@"
