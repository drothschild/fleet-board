#!/usr/bin/env bash
#
# Test helper (not a suite), sourced: store_sync [repo-root]
#
# Rebuilds the local card store of <repo-root> (default $REPO) from the fake-gh
# routes file in $FAKE_GH_ROUTES (see routes-store.sh), and exports
# FLEET_BOARD_USER as the routes' "api user" login, so a manager note the
# fixtures write as that login is the trusted one. A suite calls it right
# before each script it runs, so the cards are what the issue fixtures say at
# that moment. It does nothing without a routes file or a config, and it
# leaves alone a store the suite seeded itself (cards present, but not built
# from routes: no .from-routes marker; the suites use the default board.dir).

STORE_SYNC_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

store_sync() {
  local root="${1:-${REPO:-}}" login
  [ -n "$root" ] && [ -f "$root/.fleet-board.yml" ] || return 0
  [ -n "${FAKE_GH_ROUTES:-}" ] && [ -f "$FAKE_GH_ROUTES" ] || return 0
  if [ -d "$root/.fleet-board/cards" ] && [ ! -e "$root/.fleet-board/.from-routes" ] \
     && [ -n "$(ls "$root/.fleet-board/cards" 2>/dev/null)" ]; then
    return 0
  fi
  login="$(bash "$STORE_SYNC_HERE/routes-store.sh" "$FAKE_GH_ROUTES" "$root")" || return 1
  FLEET_BOARD_USER="$login"
  export FLEET_BOARD_USER
}
