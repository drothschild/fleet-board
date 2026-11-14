#!/usr/bin/env bash
# Free check that behavioral-merger.sh does not run claude with --bare: on Claude Code 2.1.323 --bare does
# not load plugin agents, so `--agent fleet-board:merger` is "not found". The fresh empty CLAUDE_CONFIG_DIR
# is what keeps user plugins out. Usage: bash plugins/fleet-board/tests/test-behavioral-merger-no-bare.sh
set -uo pipefail
unset CDPATH
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TARGET="$SCRIPT_DIR/behavioral-merger.sh"
FAILS=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n  %s\n' "$1" "$2"; FAILS=$((FAILS + 1)); }

# claude argv lines: those that build the argv array for the merger agent
argv_lines="$(grep -n -- '--agent fleet-board:merger' "$TARGET" | grep -v '^[0-9]*:[[:space:]]*#')"
if [ -z "$argv_lines" ]; then
  fail "behavioral-merger.sh builds a claude argv with --agent fleet-board:merger" "no such line"
elif printf '%s\n' "$argv_lines" | grep -q -- '--bare'; then
  fail "the merger claude argv does not pass --bare" "$argv_lines"
else
  pass "the merger claude argv does not pass --bare"
fi

# the fresh empty CLAUDE_CONFIG_DIR must remain, since it is what isolates user plugins
if grep -q 'CLAUDE_CONFIG_DIR="\$cfg"' "$TARGET"; then
  pass "the session still runs with a fresh CLAUDE_CONFIG_DIR"
else
  fail "the session still runs with a fresh CLAUDE_CONFIG_DIR" "assignment missing"
fi

[ "$FAILS" -eq 0 ]
