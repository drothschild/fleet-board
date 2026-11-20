#!/usr/bin/env bash
#
# Plain-bash test that the README has a `## Premise check` section naming the config keys and settle commands.
# Usage: bash plugins/fleet-board/tests/test-premise-docs.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
README="$SCRIPT_DIR/../README.md"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

section="$(awk '/^## Premise check[[:space:]]*$/ {on=1; next} /^## / {on=0} on' "$README")"

if [ -n "$section" ]; then pass "README has a ## Premise check section"; else fail "README has a ## Premise check section"; fi
for term in 'premise_check.enabled' 'models.checker' 'followups.auto_ready' 'followups.auto_ready_cap' \
            'premise-settle.sh approve' 'premise-settle.sh confirm' 'fleet:closed-as-built'; do
  if printf '%s\n' "$section" | grep -qF -- "$term"; then pass "section names $term"; else fail "section names $term"; fi
done

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
