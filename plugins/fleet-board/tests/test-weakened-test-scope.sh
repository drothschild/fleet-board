#!/usr/bin/env bash
# Checks that the weakened-test step (reviewer step 6 in the spec, step 7 in the agent; fixer step 3)
# covers weakening outside a test body, runs in round 1 against the merge-base, never names a SHA at
# which the test is already weakened, and that the manager states one round 1 reference SHA.
# Run: bash plugins/fleet-board/tests/test-weakened-test-scope.sh
set -u
unset CDPATH
HERE="$(cd "$(dirname "$0")" && pwd)"
AGENTS="$HERE/../agents"
SPECS="${SPECS_DIR:-$HERE/../../../docs/implementation-plans/2026-09-28-fleet-board/specs}"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

# block_has LABEL TEXT NEEDLE: the extracted block holds NEEDLE.
block_has() {
  if printf '%s\n' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1"; fi
}
block_lacks() {
  if printf '%s\n' "$2" | grep -qF -- "$3"; then bad "$1"; else ok "$1"; fi
}

# reviewer_block FILE: from the weakened-test step heading to the next numbered step.
reviewer_block() {
  awk '/^[0-9]+\. \*\*/ { if (on) exit } /Pre-existing tests must not be weakened/ { on = 1 } on { print }' "$1"
}
# fixer_block FILE: the step that says existing tests are never edited, up to the escalation step.
fixer_block() {
  awk '/^[0-9]+\. \*\*Escalate/ { if (on) exit } /^3\. \*\*/ { on = 1 } on { print }' "$1"
}

check_reviewer() {
  local who="$1" f="$2" blk checked
  blk="$(reviewer_block "$f")"
  if [ -z "$blk" ]; then bad "$who: weakened-test step found"; return; fi
  block_lacks "$who: weakened-test step is not limited to round 2 and later" "$(printf '%s\n' "$blk" | head -1 | grep -o '\*\*Pre-existing[^*]*\*\*')" 'round 2 and later'
  block_lacks "$who: weakened-test step no longer does nothing in round 1" "$blk" 'this step does nothing'
  block_has "$who: step covers test helpers" "$blk" 'helper'
  block_has "$who: step covers fixtures" "$blk" 'fixture'
  block_has "$who: step covers top-level setup hooks" "$blk" 'beforeEach'
  block_has "$who: step covers a .skip marker on a describe" "$blk" 'describe.skip'
  block_has "$who: step covers a .only marker on a new block" "$blk" 'test.only'
  block_has "$who: step compares round 1 against the merge-base" "$blk" 'merge-base'
  block_has "$who: step covers every commit, so a fixer commit after unblock is checked" "$blk" 'every commit'
  block_has "$who: step never gives a SHA where the test is already weakened" "$blk" 'already weakened'
  checked="$(grep -F '`CHECKED`**' "$f" | head -1)"
  block_has "$who: CHECKED rule never gives a SHA where the test is already weakened" "$checked" 'already weakened'
  block_has "$who: CHECKED rule falls back to the merge-base" "$checked" 'merge-base'
}

check_fixer() {
  local who="$1" f="$2" blk
  blk="$(fixer_block "$f")"
  if [ -z "$blk" ]; then bad "$who: fixer step 3 found"; return; fi
  block_has "$who: step 3 covers helpers" "$blk" 'helper'
  block_has "$who: step 3 covers fixtures" "$blk" 'fixture'
  block_has "$who: step 3 covers top-level setup hooks" "$blk" 'beforeEach'
  block_has "$who: step 3 covers a .skip marker on a describe" "$blk" 'describe.skip'
  block_has "$who: step 3 covers a .only marker" "$blk" 'test.only'
}

check_manager() {
  local who="$1" f="$2" row
  row="$(grep -E '^\| `review` ' "$f" | head -1)"
  block_has "$who: review row says what round 1 uses" "$row" 'round 1'
  block_has "$who: review row names base for round 1" "$row" '`base`'
  block_lacks "$who: review row has no 'no previous review' reading" "$row" 'no previous review'
  if grep -qF 'no previous review' "$f"; then bad "$who: no line says round 1 depends on a previous review"; else ok "$who: no line says round 1 depends on a previous review"; fi
}

check_reviewer agent "$AGENTS/reviewer.md"
check_fixer agent "$AGENTS/fixer.md"
check_manager agent "$AGENTS/manager.md"
if [ -d "$SPECS" ]; then
  check_reviewer spec "$SPECS/reviewer.md"
  check_fixer spec "$SPECS/fixer.md"
  check_manager spec "$SPECS/manager.md"
else
  echo "skip - no specs at $SPECS (installed plugin)"
fi
exit $fail
