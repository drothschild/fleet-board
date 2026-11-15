#!/usr/bin/env bash
# Card 376 (kept after the card 408 split): candidate_empty_human_qa_route must be defined, in the
# shared tick-plan-lib.sh, before the first call in any tick-plan suite, so a run never prints
# "command not found" for it. A suite that calls it must source the lib on an earlier line.
set -u
unset CDPATH
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/tick-plan-lib.sh"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

name=candidate_empty_human_qa_route
if grep -q "^${name}() {" "$LIB"; then
  ok "tick-plan-lib.sh defines candidate_empty_human_qa_route (command not found count 0)"
else
  bad "tick-plan-lib.sh does not define candidate_empty_human_qa_route"
fi

callers=0
for suite in "$HERE"/test-tick-plan-*.sh; do
  base="$(basename "$suite")"
  [ "$base" = "test-tick-plan-helper-order.sh" ] && continue
  call_line="$(grep -nE "^[[:space:]]*${name}[[:space:]]*$" "$suite" | head -1 | cut -d: -f1)"
  [ -n "$call_line" ] || continue
  callers=$((callers + 1))
  src_line="$(grep -nE '^\. .*tick-plan-lib\.sh' "$suite" | head -1 | cut -d: -f1)"
  if [ -n "$src_line" ] && [ "$src_line" -lt "$call_line" ]; then
    ok "$base sources the lib (line $src_line) before its first call of $name (line $call_line)"
  else
    bad "$base calls $name (line $call_line) before sourcing tick-plan-lib.sh (line ${src_line:-none})"
  fi
done
if [ "$callers" -ge 1 ]; then ok "at least one suite calls $name ($callers)"; else bad "no suite calls $name"; fi

exit "$fail"
