#!/usr/bin/env bash
# The behavioral-tick harness comment no longer says "Merges stay human".
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
FILE="$HERE/behavioral-tick.sh"

n=$(grep -c 'Merges stay human' "$FILE")
if [ "$n" = "0" ]; then
  echo "ok - behavioral-tick.sh has 0 occurrences of 'Merges stay human'"
else
  echo "not ok - behavioral-tick.sh has $n occurrences of 'Merges stay human', want 0"
  exit 1
fi
