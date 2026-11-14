#!/bin/bash
# Card 347: the driver resolves the persona through roles.resolve_persona.
set -u
unset CDPATH
plugin_dir=$(cd "$(dirname "$0")/.." && pwd)
driver="$plugin_dir/scripts/supervisor/driver.py"
failed=0

count=$(grep -c resolve_persona "$driver")
if [ "$count" -ge 1 ]; then
  echo "ok - grep -c resolve_persona driver.py gives 1 or more ($count)"
else
  echo "not ok - grep -c resolve_persona driver.py gives 1 or more (got $count)"
  failed=1
fi
exit $failed
