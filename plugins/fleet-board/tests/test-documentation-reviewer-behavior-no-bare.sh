#!/usr/bin/env bash
# Free check that test-documentation-reviewer-behavior.sh does not run claude with --bare: on Claude Code
# 2.1.323 --bare does not load plugin agents. The fresh empty CLAUDE_CONFIG_DIR keeps user plugins out.
# Usage: bash plugins/fleet-board/tests/test-documentation-reviewer-behavior-no-bare.sh
set -uo pipefail
unset CDPATH
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TARGET="$SCRIPT_DIR/test-documentation-reviewer-behavior.sh"
FAILS=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n  %s\n' "$1" "$2"; FAILS=$((FAILS + 1)); }

code="$(grep -v '^[[:space:]]*#' "$TARGET")"

if printf '%s\n' "$code" | grep -q -- '--bare'; then
  fail "the documentation reviewer claude argv does not pass --bare" "$(printf '%s\n' "$code" | grep -n -- '--bare')"
else
  pass "the documentation reviewer claude argv does not pass --bare"
fi

if printf '%s\n' "$code" | grep -q 'CLAUDE_CONFIG_DIR="\$(mktemp -d)"'; then
  pass "the session still runs with a fresh CLAUDE_CONFIG_DIR"
else
  fail "the session still runs with a fresh CLAUDE_CONFIG_DIR" "assignment missing"
fi

if printf '%s\n' "$code" | grep -q -- '--settings "\$SETTINGS"'; then
  pass "the session still passes the isolated --settings"
else
  fail "the session still passes the isolated --settings" "--settings missing"
fi

[ "$FAILS" -eq 0 ]
