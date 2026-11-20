#!/usr/bin/env bash
#
# Plain-bash offline test: behavioral-role.sh has a live docs-only implementor
# scenario (the persona rule: a docs-only Acceptance item gets a DOCS mapping,
# not a test that reads markdown), and this repository's persona is configured.
#
# Usage: bash plugins/fleet-board/tests/test-behavioral-docs-only.sh

set -uo pipefail
unset CDPATH

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROLE="$HERE/behavioral-role.sh"
FIX="$HERE/../fixtures/behavioral"
ROOT="$(cd "$HERE/../../.." && pwd)"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() { if "${@:2}"; then pass "$1"; else fail "$1"; fi; }

check "SCENARIOS lists implementor-docs-only" \
  grep -q '^SCENARIOS=.*implementor-docs-only' "$ROLE"
check "case dispatches implementor-docs-only" \
  grep -q '^  implementor-docs-only) ' "$ROLE"
check "scenario function scenario_implementor_docs_only exists" \
  grep -q '^scenario_implementor_docs_only()' "$ROLE"
check "the scenario reads the persona file docs/implementor-persona.md" \
  grep -q 'docs/implementor-persona.md' "$ROLE"
check "the scenario fails when the PR diff adds a test file that reads a .md file" \
  grep -q 'reads a \.md file' "$ROLE"

n=$(grep -c '^- ' "$FIX/card-docs-only.md" 2>/dev/null)
check "card-docs-only.md holds exactly two Acceptance items, got ${n:-none}" [ "${n:-0}" -eq 2 ]
check "repo .fleet-board.yml sets implementor.persona to docs/implementor-persona.md" \
  grep -Eq '^[[:space:]]+persona:[[:space:]]*"?docs/implementor-persona.md"?' "$ROOT/.fleet-board.yml"
check "docs/implementor-persona.md exists" [ -s "$ROOT/docs/implementor-persona.md" ]

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
