#!/bin/bash
# Card 350: supervisor.sh documents/has the stuck-card exit 4.
set -u
unset CDPATH
plugin_dir=$(cd "$(dirname "$0")/.." && pwd)
fail=0

count=$(grep -c "exit 4" "$plugin_dir/scripts/supervisor.sh")
if [ "${count:-0}" -ge 1 ]; then
  echo "ok - grep -c \"exit 4\" supervisor.sh prints a count of at least 1 ($count)"
else
  echo "not ok - grep -c \"exit 4\" supervisor.sh prints a count of at least 1 (got ${count:-0})"
  fail=1
fi
exit $fail
