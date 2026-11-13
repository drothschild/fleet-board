#!/usr/bin/env bash
# Card 278: the supervisor labels the merger's merged-head input "Post-merge head", not "Merged head".
set -u
unset CDPATH
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

n=$(grep -c "Merged head" "$ROOT/scripts/supervisor/driver.py")
[ "$n" = 0 ] && ok "driver.py no longer contains Merged head" || bad "driver.py still contains Merged head ($n lines)"

n=$(grep -c "Post-merge head" "$ROOT/scripts/supervisor/driver.py")
[ "$n" -ge 1 ] && ok "driver.py labels the input Post-merge head" || bad "driver.py lacks the Post-merge head label"

n=$(grep -c "## Post-merge head" "$ROOT/fixtures/supervisor/merging_cases.py")
[ "$n" -ge 1 ] && ok "merging_cases fixture expects ## Post-merge head" || bad "fixture does not expect ## Post-merge head"

n=$(grep -c "Merged head" "$ROOT/agents/merger.md")
[ "$n" = 0 ] && ok "merger.md uses the new label" || bad "merger.md still says Merged head"

exit "$fail"
