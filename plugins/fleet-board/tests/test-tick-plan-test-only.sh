#!/usr/bin/env bash
#
# FLEET_TEST_ONLY=<exact check name> makes a tick-plan suite (the ones that source the shared tick-plan helper)
# run only the scenario that holds that check, so the reviewer's commands.test_case
# ("FLEET_TEST_ONLY={name} bash {file}") runs one check per mutant, not the whole suite.
#
# Usage: bash plugins/fleet-board/tests/test-tick-plan-test-only.sh

set -uo pipefail
unset CDPATH

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Test: FLEET_TEST_ONLY in the tick-plan suites"
echo ""

# run_only <tests dir> <suite> <name>: run one suite filtered to one check; sets RC, OUT, ERR, SECS
run_only() {
  local start
  start="$(date +%s)"
  FLEET_TEST_ONLY="$3" bash "$1/$2" > "$WORK/out" 2> "$WORK/err"
  RC=$?
  SECS=$(( $(date +%s) - start ))
  OUT="$(cat "$WORK/out")"
  ERR="$(cat "$WORK/err")"
}
count_lines() { printf '%s\n' "$1" | grep -c -- "$2" || true; }

# 1. the stages suite, one check from its first scenarios, runs alone and fast
NAME="stage-advance: in_review plans review_stage, not advance_stage"
run_only "$HERE" test-tick-plan-stages.sh "$NAME"
oks="$(count_lines "$OUT" '^  ok ')"
fails="$(count_lines "$OUT" '^  FAIL ')"
if [ "$RC" = 0 ]; then pass "stages: the selected check exits 0"; else fail "stages: the selected check exits 0" "exit $RC: $ERR"; fi
if [ "$oks" = 1 ]; then pass "stages: exactly one ok line"; else fail "stages: exactly one ok line" "ok lines: $oks"; fi
if [ "$fails" = 0 ]; then pass "stages: no FAIL line"; else fail "stages: no FAIL line" "FAIL lines: $fails"; fi
if printf '%s\n' "$OUT" | grep -cF "  ok   $NAME" >/dev/null; then pass "stages: the ok line is the selected check"; else fail "stages: the ok line is the selected check" "$OUT"; fi
case "$ERR" in *"FLEET_TEST_ONLY=$NAME: 1 test(s) selected"*) pass "stages: stderr says 1 test(s) selected" ;; *) fail "stages: stderr says 1 test(s) selected" "$ERR" ;; esac
if [ "$SECS" -lt 30 ]; then pass "stages: the filtered run finishes in under 30 seconds"; else fail "stages: the filtered run finishes in under 30 seconds" "took ${SECS}s"; fi

# 2. one check from the second half of each other suite
for pair in \
  "ready|premise-fresh: a card stamped at the head plans start" \
  "review|reviewed_stages vs reviews: the card is fixed for security's finding, not merged (fix)" \
  "merging|merging drift: head moved only by a clean merge of main plans merge" \
  "followups|action-failures: ready 6 of 3 -> skip" \
  "scope|preflight-unset: no preflight warning"; do
  suite="test-tick-plan-${pair%%|*}.sh"
  name="${pair#*|}"
  run_only "$HERE" "$suite" "$name"
  oks="$(count_lines "$OUT" '^  ok ')"
  fails="$(count_lines "$OUT" '^  FAIL ')"
  if [ "$RC" = 0 ] && [ "$oks" = 1 ] && [ "$fails" = 0 ] && printf '%s\n' "$OUT" | grep -cF "  ok   $name" >/dev/null; then
    pass "$suite: '$name' runs alone and passes"
  else
    fail "$suite: '$name' runs alone and passes" "exit $RC, ok lines $oks, FAIL lines $fails, stderr: $ERR"
  fi
done

# 3. a copy of the plugin whose review_stage row plans advance_stage: the filtered run fails that one check
MUT="$WORK/mutant"
mkdir -p "$MUT/plugins"
cp -R "$PLUGIN" "$MUT/plugins/fleet-board"
sed -i.bak 's/act("review_stage"/act("advance_stage"/' "$MUT/plugins/fleet-board/scripts/tick-plan.sh"
if cmp -s "$PLUGIN/scripts/tick-plan.sh" "$MUT/plugins/fleet-board/scripts/tick-plan.sh"; then
  fail "mutant: the copy's review_stage row was changed" "the sed changed nothing"
else
  run_only "$MUT/plugins/fleet-board/tests" test-tick-plan-stages.sh "$NAME"
  oks="$(count_lines "$OUT" '^  ok ')"
  fails="$(count_lines "$OUT" '^  FAIL ')"
  if [ "$fails" = 1 ] && [ "$oks" = 0 ] && printf '%s\n' "$OUT" | grep -cF "  FAIL $NAME" >/dev/null; then
    pass "mutant: exactly one FAIL line, for the selected check"
  else
    fail "mutant: exactly one FAIL line, for the selected check" "FAIL lines $fails, ok lines $oks"
  fi
  if [ "$RC" -ne 0 ]; then pass "mutant: the filtered run exits non-zero"; else fail "mutant: the filtered run exits non-zero" "exit $RC"; fi
fi

# 4. a name that matches nothing, or two checks, exits 5 before tick-plan.sh runs
STUB="$WORK/stub"
mkdir -p "$STUB/plugins"
cp -R "$PLUGIN" "$STUB/plugins/fleet-board"
printf '#!/usr/bin/env bash\necho ran >> "%s/ran"\nexit 1\n' "$WORK" > "$STUB/plugins/fleet-board/scripts/tick-plan.sh"
chmod +x "$STUB/plugins/fleet-board/scripts/tick-plan.sh"
run_only "$STUB/plugins/fleet-board/tests" test-tick-plan-ready.sh "no such check anywhere"
if [ "$RC" = 5 ]; then pass "no match: exits 5"; else fail "no match: exits 5" "exit $RC"; fi
case "$ERR" in *"FLEET_TEST_ONLY=no such check anywhere: 0 test(s) selected"*) pass "no match: stderr says 0 test(s) selected" ;; *) fail "no match: stderr says 0 test(s) selected" "$ERR" ;; esac
if [ ! -e "$WORK/ran" ]; then pass "no match: tick-plan.sh did not run"; else fail "no match: tick-plan.sh did not run" "the stub ran"; fi

LIBNAME="tick-plan-lib"
DUP="$STUB/plugins/fleet-board/tests/test-tick-plan-dup.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"\n'
  printf '. "$SCRIPT_DIR/%s.sh"\n' "$LIBNAME" # not spelled out: test-tick-plan-split.sh treats a file naming the helper as a suite
  printf 'plan ready-start\n'
  printf 'assert_exit "twice: exit" 0\n'
  printf 'plan ready-start\n'
  printf 'assert_exit "twice: exit" 0\n'
  printf 'tp_finish\n'
} > "$DUP"
run_only "$STUB/plugins/fleet-board/tests" test-tick-plan-dup.sh "twice: exit"
if [ "$RC" = 5 ]; then pass "two matches: exits 5"; else fail "two matches: exits 5" "exit $RC"; fi
case "$ERR" in *"FLEET_TEST_ONLY=twice: exit matches 2 checks"*) pass "two matches: stderr names the count" ;; *) fail "two matches: stderr names the count" "$ERR" ;; esac
if [ ! -e "$WORK/ran" ]; then pass "two matches: tick-plan.sh did not run"; else fail "two matches: tick-plan.sh did not run" "the stub ran"; fi

# 5. unset and empty change nothing: the same totals line, and it counts the ok lines
# two streams (unset, empty), each suite after the other: twelve suites at once starve the planner and flake
( for s in ready review merging followups scope stages; do
    env -u FLEET_TEST_ONLY bash "$HERE/test-tick-plan-$s.sh" > "$WORK/$s.unset" 2>&1
  done ) &
( for s in ready review merging followups scope stages; do
    FLEET_TEST_ONLY= bash "$HERE/test-tick-plan-$s.sh" > "$WORK/$s.empty" 2>&1
  done ) &
wait
for s in ready review merging followups scope stages; do
  u="$(grep '^passed: ' "$WORK/$s.unset" | tail -1)"
  e="$(grep '^passed: ' "$WORK/$s.empty" | tail -1)"
  n="$(grep -c '^  ok ' "$WORK/$s.unset" || true)"
  if [ -n "$u" ] && [ "$u" = "$e" ] && [ "$u" = "$(printf 'passed: %d   failed: 0' "$n")" ]; then
    pass "$s: unset and empty both print '$u'"
  else
    fail "$s: unset and empty print the same totals line" "unset: '$u' empty: '$e' ok lines: $n"
  fi
done

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
