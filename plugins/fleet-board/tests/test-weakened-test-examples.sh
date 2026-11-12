#!/usr/bin/env bash
# Pins the exact text of each weakening-outside-a-test-body example in the reviewer and fixer
# weakened-test steps.
# test-weakened-test-scope.sh greps single words ("fixture", "helper") across a whole step, so a
# deleted example bullet stays green there; this file checks each example on its own.
# Run: bash plugins/fleet-board/tests/test-weakened-test-examples.sh
set -u
unset CDPATH
HERE="$(cd "$(dirname "$0")" && pwd)"
AGENTS="$HERE/../agents"
SPECS="${SPECS_DIR:-$HERE/../../../docs/implementation-plans/2026-09-28-fleet-board/specs}"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }
# block_has LABEL TEXT NEEDLE: TEXT holds NEEDLE as a fixed string.
block_has() {
  if printf '%s\n' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1"; fi
}

# reviewer_block FILE: from the weakened-test step heading to the next numbered step.
reviewer_block() {
  awk '/^[0-9]+\. \*\*/ { if (on) exit } /Pre-existing tests must not be weakened/ { on = 1 } on { print }' "$1"
}
# fixer_block FILE: fixer step 3, up to the escalation step.
fixer_block() {
  awk '/^[0-9]+\. \*\*Escalate/ { if (on) exit } /^3\. \*\*/ { on = 1 } on { print }' "$1"
}

check_reviewer() {
  local who="$1" f="$2" blk
  blk="$(reviewer_block "$f")"
  if [ -z "$blk" ]; then bad "$who: weakened-test step found"; return; fi
  block_has "$who: helper example" "$blk" 'a test helper (a no-op `assertEqual` in `test/helpers.js`)'
  block_has "$who: fixture example" "$blk" 'a fixture or expected-output file (a changed `test/fixtures/expected.json`)'
  block_has "$who: setup hook example" "$blk" 'a top-level setup hook (a new top-level `beforeEach` that stubs the code under test)'
  block_has "$who: .skip marker example" "$blk" 'a `.skip` marker on a suite (`describe(` changed to `describe.skip(`)'
  block_has "$who: .only marker example" "$blk" 'an `.only` marker (a new `test.only(...)` block, which stops every other test in the file from running)'
}

check_fixer() {
  local who="$1" f="$2" blk
  blk="$(fixer_block "$f")"
  if [ -z "$blk" ]; then bad "$who: fixer step 3 found"; return; fi
  block_has "$who: helper example" "$blk" 'no changed or no-op test helper (such as `assertEqual` in `test/helpers.js`)'
  block_has "$who: fixture example" "$blk" 'no changed fixture or expected-output file (such as `test/fixtures/expected.json`)'
  block_has "$who: setup hook example" "$blk" 'no new top-level setup hook such as a `beforeEach` that stubs the code under test'
  block_has "$who: .skip marker example" "$blk" 'no `describe(` changed to `describe.skip(`'
  block_has "$who: .only marker example" "$blk" 'no new `test.only(...)` block or other `.only` marker'
}


check_reviewer agent "$AGENTS/reviewer.md"
check_fixer agent "$AGENTS/fixer.md"
# The manager checks went with the tick system: driver_cases.py
# test_reviewer_round_one_uses_the_base_even_after_an_earlier_review pins the round 1 reference SHA.
if [ -d "$SPECS" ]; then
  check_reviewer spec "$SPECS/reviewer.md"
  check_fixer spec "$SPECS/fixer.md"
else
  echo "skip - no specs at $SPECS (installed plugin)"
fi
exit $fail
