#!/usr/bin/env bash
# Run every suite matching the glob given as $1, print each suite's name and
# result, and exit non-zero if any suite failed (or none matched).
# Usage: bash .github/scripts/run-suites.sh 'plugins/fleet-board/tests/test-*.sh'
#
# Suites run in parallel, SUITE_JOBS at a time (default: the number of CPUs).
# Each suite's output is captured to its own file, so results are printed in
# glob order, one line per suite, as when they ran one after another; a failed
# suite's captured output is shown once (it is not run a second time).
# SUITE_JOBS=1 runs them one at a time.
set -uo pipefail
unset CDPATH
pattern="${1:?usage: run-suites.sh GLOB}"
jobs="${SUITE_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"
case "$jobs" in ''|*[!0-9]*|0) jobs=2 ;; esac

work="$(mktemp -d "${TMPDIR:-/tmp}/run-suites.XXXXXX")" || exit 1
trap 'rm -rf "$work"' EXIT

# The suites to run, in glob order, one per line in $work/list.
: > "$work/list"
# shellcheck disable=SC2086
for suite in $pattern; do
  [ -f "$suite" ] || continue
  # An aggregate runner (test-tick-plan.sh) only re-runs suites this glob already runs
  if sed -n 2p "$suite" | grep -q '^# fleet-board: aggregate runner'; then
    printf '%s ... SKIP (aggregate runner)\n' "$suite"
    continue
  fi
  printf '%s\n' "$suite" >> "$work/list"
done
total="$(grep -c . "$work/list")"
if [ "$total" -eq 0 ]; then echo "suites: 0, failed: 0"; echo "no suites matched $pattern"; exit 1; fi

# One worker per line number: run the suite, keep its output and exit code.
# A suite's own failure never stops the others (xargs gets exit 0 back).
run_one() {
  n="$1"; work="$2"
  suite="$(sed -n "${n}p" "$work/list")"
  start=$(date +%s)
  "$BASH" "$suite" > "$work/$n.out" 2>&1
  printf '%s %s\n' "$?" "$(( $(date +%s) - start ))" > "$work/$n.rc"
  return 0
}
export -f run_one
seq 1 "$total" | xargs -P "$jobs" -I{} "$BASH" -c 'run_one "$1" "$2"' _ {} "$work"

failed=0
n=0
while IFS= read -r suite; do
  n=$((n + 1))
  rc=1; secs=?
  [ -f "$work/$n.rc" ] && read -r rc secs < "$work/$n.rc"
  if [ "$rc" = 0 ]; then
    printf '%s ... PASS (%ss)\n' "$suite" "$secs"
  else
    failed=$((failed + 1))
    printf '%s ... FAIL (exit %s, %ss)\n' "$suite" "$rc" "$secs"
    echo "::group::output of $suite"
    # The failing assertions are usually far above the tail; show them first.
    grep -A2 -E '^[[:space:]]*FAIL' "$work/$n.out" 2>/dev/null | head -60
    echo "--- last 40 lines ---"
    tail -40 "$work/$n.out" 2>/dev/null
    echo "::endgroup::"
  fi
done < "$work/list"
echo "suites: $total, failed: $failed (run $jobs at a time)"
[ "$failed" -eq 0 ]
