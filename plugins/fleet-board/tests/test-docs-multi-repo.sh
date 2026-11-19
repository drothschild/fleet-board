#!/usr/bin/env bash
#
# Plain-bash test: docs/config.md documents board.repos and the card repo field.
#
# Usage: bash plugins/fleet-board/tests/test-docs-multi-repo.sh
# CONFIG_DOC overrides the file checked.

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CONFIG_DOC="${CONFIG_DOC:-${SCRIPT_DIR}/../docs/config.md}"

PASS=0
FAIL=0

check() {
  if [ "$2" = "ok" ]; then
    PASS=$((PASS + 1)); echo "ok - $1"
  else
    FAIL=$((FAIL + 1)); echo "not ok - $1"
  fi
}

# The text of the `## `board.repos`` section (up to the next ## heading).
section() {
  awk '/^## /{on=($0 ~ /board\.repos/)} on' "$CONFIG_DOC"
}

sec="$(section | tr '\n' ' ' | tr -s ' ')"

has() {
  printf '%s' "$sec" | grep -cF -- "$1" >/dev/null && echo ok || echo bad
}

check "config.md has a board.repos section that names the card repo field" \
  "$([ -n "$sec" ] && has '`repo` field' || echo bad)"

check "the board.repos section states that path must be absolute" \
  "$([ -n "$sec" ] && has 'must be absolute' || echo bad)"

echo "passed: $PASS failed: $FAIL"
[ "$FAIL" -eq 0 ]
