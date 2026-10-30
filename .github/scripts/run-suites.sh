#!/usr/bin/env bash
# Run every suite matching the glob given as $1, print each suite's name and
# result, and exit non-zero if any suite failed (or none matched).
# Usage: bash .github/scripts/run-suites.sh 'plugins/fleet-board/tests/test-*.sh'
set -uo pipefail
pattern="${1:?usage: run-suites.sh GLOB}"
total=0; failed=0; failed_names=""
# shellcheck disable=SC2086
for suite in $pattern; do
  [ -f "$suite" ] || continue
  total=$((total + 1))
  if "$BASH" "$suite" > /dev/null 2>&1; then
    printf '%s ... PASS\n' "$suite"
  else
    rc=$?
    failed=$((failed + 1)); failed_names="$failed_names $suite"
    printf '%s ... FAIL (exit %s)\n' "$suite" "$rc"
    echo "::group::output of $suite"
    out="$("$BASH" "$suite" 2>&1)"
    # The failing assertions are usually far above the tail; show them first.
    printf '%s\n' "$out" | grep -A2 -E '^[[:space:]]*FAIL' | head -60
    echo "--- last 40 lines ---"
    printf '%s\n' "$out" | tail -40
    echo "::endgroup::"
  fi
done
echo "suites: $total, failed: $failed"
if [ "$total" -eq 0 ]; then echo "no suites matched $pattern"; exit 1; fi
[ "$failed" -eq 0 ]
