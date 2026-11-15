#!/usr/bin/env bash
#
# Plain-bash structure test for the split of test-tick-plan.sh (card 408).
# The planner scenarios live in several test-tick-plan-<area>.sh suites that
# share one sourced helper file; this checks that shape, not the planner.
#
# Usage: bash plugins/fleet-board/tests/test-tick-plan-split.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
HELPER="tick-plan-lib.sh"
CLAUDE_MD="$SCRIPT_DIR/../CLAUDE.md"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

echo "Test: tick-plan split suites"
echo ""

# The split suites: every test-tick-plan-*.sh that sources the shared helper.
SUITES=()
for f in "$SCRIPT_DIR"/test-tick-plan-*.sh; do
  [ -f "$f" ] || continue
  case "$(basename "$f")" in test-tick-plan-split.sh|test-tick-plan-helper-order.sh) continue ;; esac # these name the helper but hold no scenarios
  if grep -q "$HELPER" "$f"; then SUITES+=("$f"); fi
done

# The scenarios in test-tick-plan.sh are split across at least four suites
if [ "${#SUITES[@]}" -ge 4 ]; then
  pass "the scenarios are split across at least four test-tick-plan-*.sh suites"
else
  fail "the scenarios are split across at least four test-tick-plan-*.sh suites" "found ${#SUITES[@]} suites sourcing $HELPER"
fi

# One shared helper file exists beside the suites
if [ -f "$SCRIPT_DIR/$HELPER" ]; then
  pass "one shared helper file $HELPER sits beside the suites"
else
  fail "one shared helper file $HELPER sits beside the suites" "missing $SCRIPT_DIR/$HELPER"
fi

# The shared helper is not itself picked up by the CI glob tests/test-*.sh
case "$HELPER" in
  test-*) fail "the helper name stays out of the tests/test-*.sh glob" "$HELPER matches test-*.sh" ;;
  *) pass "the helper name stays out of the tests/test-*.sh glob" ;;
esac

# Each suite sources the helper and does not redefine the shared helpers
for f in ${SUITES[@]+"${SUITES[@]}"}; do
  name="$(basename "$f")"
  if grep -Eq '^\. +"?\$SCRIPT_DIR/'"$HELPER"'"?' "$f"; then
    pass "$name sources the shared helper"
  else
    fail "$name sources the shared helper" "no '. \"\$SCRIPT_DIR/$HELPER\"' line"
  fi
  dups="$(grep -E '^(setup_case|plan|splan|pass|fail|assert_[a-z_]+|run_check)\(\)' "$f" | head -1)"
  if [ -z "$dups" ]; then
    pass "$name does not redefine the shared helpers"
  else
    fail "$name does not redefine the shared helpers" "defines: $dups"
  fi
done

# Every scenario is kept in exactly one suite: test-tick-plan.sh holds no scenario of its
# own (it only runs the split suites, and CI's run-suites.sh skips it as an aggregate runner),
# and no assertion description appears in two suites
OLD="$SCRIPT_DIR/test-tick-plan.sh"
if [ ! -e "$OLD" ]; then
  pass "test-tick-plan.sh holds no scenario, so no scenario runs twice"
elif sed -n 2p "$OLD" | grep -q '^# fleet-board: aggregate runner' \
    && ! grep -qE '^[[:space:]]*(\.|source)[[:space:]].*tick-plan-lib\.sh' "$OLD" \
    && ! grep -qE '^[[:space:]]*(assert_[a-z_]+|plan|splan|setup_case)[[:space:]]' "$OLD"; then
  pass "test-tick-plan.sh holds no scenario, so no scenario runs twice"
else
  fail "test-tick-plan.sh holds no scenario, so no scenario runs twice" \
    "test-tick-plan.sh is not a marked aggregate runner, sources tick-plan-lib.sh (CI skips it, so a scenario there never runs), or holds an assert_, plan or setup_case line"
fi

if [ "${#SUITES[@]}" -ge 1 ]; then
  dupe_count="$(for f in "${SUITES[@]}"; do grep -ohE '^assert_[a-z_]+ "[^"]+"' "$f" | sort -u; done | sort | uniq -d | wc -l | tr -d ' ')"
else
  dupe_count="no suites"
fi
if [ "$dupe_count" = 0 ]; then
  pass "each assertion appears in exactly one suite"
else
  fail "each assertion appears in exactly one suite" "assertions repeated across suites: $dupe_count"
fi

# plugins/fleet-board/CLAUDE.md names the split suites in its Tests section
tests_section="$(awk '/^#+ .*Tests/ {on=1; next} /^#+ / {on=0} on' "$CLAUDE_MD" 2>/dev/null)"
for f in ${SUITES[@]+"${SUITES[@]}"}; do
  name="$(basename "$f")"
  case "$tests_section" in
    *"$name"*) pass "CLAUDE.md Tests section names $name" ;;
    *) fail "CLAUDE.md Tests section names $name" "not found in the Tests section" ;;
  esac
done
if [ "${#SUITES[@]}" -eq 0 ]; then
  fail "CLAUDE.md Tests section names the split suites" "there are no split suites to name"
fi

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
