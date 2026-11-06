#!/usr/bin/env bash
# Acceptance: the reviewer spec says how the weakened-test step handles helpers
# and fixtures outside test_paths.
unset CDPATH
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC="$ROOT/docs/implementation-plans/2026-09-28-fleet-board/specs/reviewer.md"
n=$(grep -c 'outside test_paths' "$SPEC")
if [ "$n" -ge 1 ]; then echo "PASS: spec mentions 'outside test_paths' ($n)"; exit 0; fi
echo "FAIL: reviewer.md never mentions 'outside test_paths'"; exit 1
