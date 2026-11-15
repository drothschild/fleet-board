#!/bin/bash
set -eu
unset CDPATH
plugin_dir=$(cd "$(dirname "$0")/.." && pwd)
cases="$plugin_dir/fixtures/supervisor/scheduler_cases.py"
fail=0

# len(_ACTION_CLASS) gives the result expected: no hardcoded literal count in the fixture
if grep -nE 'len\(_ACTION_CLASS\)[[:space:]]*==[[:space:]]*[0-9]+' "$cases"; then
  echo "FAIL: len(_ACTION_CLASS) is compared to a literal number" >&2
  fail=1
fi
# ...it is compared to a count derived from the expected classification
if ! grep -qE 'len\(_ACTION_CLASS\)[[:space:]]*==[[:space:]]*sum\(' "$cases"; then
  echo "FAIL: len(_ACTION_CLASS) is not compared to a derived count" >&2
  fail=1
fi
[ "$fail" -eq 0 ] && echo "scheduler action count is derived"
exit "$fail"
