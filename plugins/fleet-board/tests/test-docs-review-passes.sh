#!/usr/bin/env bash
#
# Plain-bash test: the docs state required passes, the shared fixer pass and
# per-reviewer round limits.
#
# Usage: bash plugins/fleet-board/tests/test-docs-review-passes.sh
# CONFIG_DOC and PLUGIN_CLAUDE override the files checked.

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CONFIG_DOC="${CONFIG_DOC:-${SCRIPT_DIR}/../docs/config.md}"
PLUGIN_CLAUDE="${PLUGIN_CLAUDE:-${SCRIPT_DIR}/../CLAUDE.md}"
README_DOC="${README_DOC:-${SCRIPT_DIR}/../README.md}"

PASS=0
FAIL=0

check() {
  if [ "$2" = "ok" ]; then
    PASS=$((PASS + 1)); echo "ok - $1"
  else
    FAIL=$((FAIL + 1)); echo "not ok - $1"
  fi
}

# has <file> <phrase>: phrase present, ignoring case and line wrapping.
has() {
  tr '\n' ' ' < "$1" | tr -s ' ' | grep -ciF -- "$2" >/dev/null && echo ok || echo bad
}

check "config.md states a stage with required_passes: 3 needs 3 clean reports at the current head" \
  "$(has "$CONFIG_DOC" 'required_passes: 3` needs 3 clean reports at the current head')"
check "config.md states the required passes run side by side" \
  "$(has "$CONFIG_DOC" 'run side by side')"
check "config.md states one pass with findings sends the card to the fixer" \
  "$(has "$CONFIG_DOC" 'one pass with findings sends the card to the fixer')"
check "config.md states one fixer pass gets every reviewer's findings once every routed reviewer has reported" \
  "$(has "$CONFIG_DOC" "one fixer pass gets every reviewer's findings once every routed reviewer has reported")"
check "config.md states every routed reviewer reviews the fixed head" \
  "$(has "$CONFIG_DOC" 'every routed reviewer reviews the fixed head')"
check "config.md states each reviewer's max_rounds counts that reviewer's own rounds with findings" \
  "$(has "$CONFIG_DOC" "each reviewer's \`max_rounds\` counts that reviewer's own rounds with findings")"
check "config.md states a clean reviewer never blocks a card" \
  "$(has "$CONFIG_DOC" 'a clean reviewer never blocks a card')"
check "plugin CLAUDE.md names review_passes in the manager-note contract" \
  "$(has "$PLUGIN_CLAUDE" '`review_passes`')"
check "plugin CLAUDE.md names finding_rounds in the manager-note contract" \
  "$(has "$PLUGIN_CLAUDE" '`finding_rounds`')"
check "README.md mentions repeated passes and the shared fixer pass" \
  "$(has "$README_DOC" 'shared fixer pass')"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
