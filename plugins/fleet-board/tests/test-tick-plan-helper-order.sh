#!/usr/bin/env bash
# Card 376: test-tick-plan.sh must define candidate_empty_human_qa_route before its first call,
# so a run never prints "command not found" for it.
set -u
unset CDPATH
HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="$HERE/test-tick-plan.sh"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

name=candidate_empty_human_qa_route
def_line="$(grep -n "^${name}() {" "$TARGET" | head -1 | cut -d: -f1)"
call_line="$(grep -nE "^[[:space:]]*${name}[[:space:]]*$" "$TARGET" | head -1 | cut -d: -f1)"

if [ -n "$def_line" ] && [ -n "$call_line" ] && [ "$def_line" -lt "$call_line" ]; then
  ok "test-tick-plan.sh defines candidate_empty_human_qa_route before its first call (command not found count 0)"
else
  bad "test-tick-plan.sh calls candidate_empty_human_qa_route (line ${call_line:-none}) before defining it (line ${def_line:-none})"
fi

exit "$fail"
