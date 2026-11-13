#!/usr/bin/env bash
# Card 276: the supervisor driver no longer labels the merger input "Merged head".
set -u
unset CDPATH
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
DRIVER="$ROOT/plugins/fleet-board/scripts/supervisor/driver.py"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

n=$(grep -c "Merged head" "$DRIVER")
if [ "$n" = 0 ]; then
  ok "grep -c \"Merged head\" driver.py gives 0 after the rename"
else
  bad "grep -c \"Merged head\" driver.py gives 0 after the rename (got $n)"
fi

exit "$fail"
