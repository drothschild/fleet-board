#!/usr/bin/env bash
# Card 162: behavioral-tick.sh must not claim merges stay human.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
F="$HERE/behavioral-tick.sh"
fail=0

n=$(grep -c 'stay human' "$F")
if [ "$n" = "0" ]; then
  echo "PASS: grep -c 'stay human' behavioral-tick.sh gives 0"
else
  echo "FAIL: grep -c 'stay human' behavioral-tick.sh gave $n, expected 0"
  fail=1
fi
exit $fail
