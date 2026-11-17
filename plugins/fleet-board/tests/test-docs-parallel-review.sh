#!/usr/bin/env bash
#
# Plain-bash test that config.md, the README and the plugin CLAUDE.md describe
# parallel review in In Review, the built-in stages, and default / enabled /
# required_passes, and no longer describe stage columns.
#
# Usage: bash plugins/fleet-board/tests/test-docs-parallel-review.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CONFIG_MD="$SCRIPT_DIR/../docs/config.md"
README="$SCRIPT_DIR/../README.md"
CLAUDE_MD="$SCRIPT_DIR/../CLAUDE.md"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

count_is() { # name file pattern expected
  local n
  n=$(grep -c -- "$3" "$2")
  if [ "$n" = "$4" ]; then pass "$1"; else fail "$1 (got $n, want $4)"; fi
}

stages_section() { awk '/^## `review.stages`/{f=1;next} /^## /{f=0} f' "$CONFIG_MD"; }

section_has() { # name text
  if stages_section | grep -cF -- "$2" >/dev/null; then pass "$1"; else fail "$1 (missing: $2)"; fi
}

echo "config.md no longer says a stage adds a board column or is the state review_<name>"
count_is "config.md: no 'adds a board column'" "$CONFIG_MD" 'adds a board column' 0
count_is "config.md: no 'A stage is the state'" "$CONFIG_MD" 'A stage is the state' 0

echo "config.md no longer says stages are empty by default"
count_is "config.md: no 'Empty by default'" "$CONFIG_MD" 'Empty by default' 0

echo "the review.stages section names the built-in stages and shows enabled: false, default: true and required_passes"
section_has "stages: names documentation" 'documentation'
section_has "stages: names blast_radius" 'blast_radius'
section_has "stages: shows enabled: false" 'enabled: false'
section_has "stages: shows default: true" 'default: true'
section_has "stages: shows required_passes" 'required_passes'
section_has "stages: reviews in parallel" 'in parallel'

echo "the README no longer sends a clean card to Review: <name> or says to add the review stage"
count_is "README: no 'goes to Review: <name>'" "$README" 'goes to .Review: <name>' 0
count_is "README: no 'add the review stage'" "$README" 'add the review stage' 0

echo "CLAUDE.md's canonical-states line drops review_<name> and the text names move_to_review"
if grep -A3 'Canonical states' "$CLAUDE_MD" | grep -cF 'review_<name>' >/dev/null; then
  fail "CLAUDE.md: canonical states still list review_<name>"
else pass "CLAUDE.md: canonical states do not list review_<name>"; fi
if grep -qF 'move_to_review' "$CLAUDE_MD"; then pass "CLAUDE.md: names move_to_review"; else fail "CLAUDE.md: names move_to_review"; fi

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
