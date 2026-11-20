#!/usr/bin/env bash
#
# Plain-bash test: the docs describe Tailscale access to the board page.
#
# Usage: bash plugins/fleet-board/tests/test-docs-tailscale-access.sh
# CONFIG_DOC, README and SPEC override the files checked.

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CONFIG_DOC="${CONFIG_DOC:-${SCRIPT_DIR}/../docs/config.md}"
README="${README:-${SCRIPT_DIR}/../README.md}"
SPEC="${SPEC:-${SCRIPT_DIR}/../../../docs/specs/2026-11-06-local-board-design.md}"

PASS=0
FAIL=0

check() {
  if [ "$2" = "ok" ]; then
    PASS=$((PASS + 1)); echo "ok - $1"
  else
    FAIL=$((FAIL + 1)); echo "not ok - $1"
  fi
}

flat() { tr '\n' ' ' < "$1" | tr -s ' '; }
cfg="$(flat "$CONFIG_DOC")"
rd="$(flat "$README")"
spec_line="$(grep -i 'remote access' "$SPEC" | tr '\n' ' ')"

r=no; printf '%s' "$cfg" | grep -Eq 'board\.allowed_hosts`[^.]*default[^.]*`\[\]`' && r=ok
check "config.md lists board.allowed_hosts with its default []" "$r"

r=no; printf '%s' "$cfg" | grep -Eq 'board\.tailscale\.allowed_logins`[^.]*default[^.]*`\[\]`' && r=ok
check "config.md lists board.tailscale.allowed_logins with its default []" "$r"

r=no; printf '%s' "$rd" | grep -Fq 'tailscale serve --bg http://127.0.0.1:<port>' && r=ok
check "README gives the command tailscale serve --bg http://127.0.0.1:<port>" "$r"

r=no; printf '%s' "$rd" | grep -Eqi 'tailscale funnel[^.]*must not be used' && r=ok
check "README says tailscale funnel must not be used for the board" "$r"

r=no; printf '%s' "$rd" | grep -Eqi 'every login on `?allowed_logins`? can start the supervisor and run Claude sessions on this Mac' && r=ok
check "README says every login on allowed_logins can start the supervisor and run Claude sessions on this Mac" "$r"

r=no; printf '%s' "$rd" | grep -Eqi 'Open terminal is refused for tailnet requests' && r=ok
check "README says Open terminal is refused for tailnet requests" "$r"

r=no; printf '%s' "$rd" | grep -Eqi 'turn (access|it) off: stop the serve and empty both keys' && r=ok
check "README says how to turn access off: stop the serve and empty both keys" "$r"

r=no
if printf '%s' "$spec_line" | grep -Fq 'Tailscale `serve`' \
   && ! printf '%s' "$spec_line" | grep -Eq 'authentication, remote access,'; then r=ok; fi
check "spec no longer lists remote access as a non-goal without qualification; names Tailscale serve" "$r"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
