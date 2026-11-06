#!/usr/bin/env bash
# Plain-bash test: the opening README has no clean-room section, still links
# docs/design.md, and the clean-room explanation lives elsewhere in the repo.
# Usage: bash tests/test-readme-no-clean-room.sh
set -uo pipefail
unset CDPATH
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
README="${README_FILE:-$ROOT/README.md}"
PASS=0; FAIL=0
check() { if [ "$2" = ok ]; then PASS=$((PASS+1)); echo "ok - $1"; else FAIL=$((FAIL+1)); echo "not ok - $1"; fi; }

[ "$(grep -ic "clean-room" "$README")" = 0 ] && r=ok || r=bad
check "README.md has no clean-room mention" "$r"
[ "$(grep -ic "clean room" "$README")" = 0 ] && r=ok || r=bad
check "README.md has no clean room mention" "$r"
grep -q "docs/design.md" "$README" && r=ok || r=bad
check "README.md still links docs/design.md" "$r"
[ -n "$(cd "$ROOT" && grep -rli "clean-room" docs plugins/fleet-board/README.md)" ] && r=ok || r=bad
check "clean-room explanation still exists in docs or the plugin README" "$r"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
