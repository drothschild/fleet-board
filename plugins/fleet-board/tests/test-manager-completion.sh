#!/usr/bin/env bash
# Offline contract checks, not a substitute for the paid behavioral scenario.
set -uo pipefail
unset CDPATH
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
PASS=0 FAIL=0
has() { if grep -Eiq "$2" "$1"; then PASS=$((PASS+1)); else echo "FAIL $3 ($1)"; FAIL=$((FAIL+1)); fi; }
absent() { if grep -Eiq "$2" "$1"; then echo "FAIL $3 ($1)"; FAIL=$((FAIL+1)); else PASS=$((PASS+1)); fi; }
for f in "$ROOT/docs/implementation-plans/2026-09-28-fleet-board/specs/manager.md" "$HERE/../agents/manager.md"; do
  has "$f" 'completion registry' 'tracks completion identity'
  has "$f" 'run_in_background: true' 'explicit background dispatch'
  absent "$f" 'run_in_background: false' 'foreground batch rule removed'
  absent "$f" 'waits? for (every|all).*before.*reconcil' 'no batch reconciliation barrier'
  has "$f" '16 actions' 'bounded per-card tick work'
  has "$f" 'one active.*per card' 'one active role per card'
  has "$f" 'duplicate completion' 'duplicate completion handling'
  has "$f" 'fresh.*plan|replan' 'fresh decisions'
  has "$f" 'headless.*merg|merg.*headless' 'headless merge boundary'
done
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
