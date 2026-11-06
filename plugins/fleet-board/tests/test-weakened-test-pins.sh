#!/usr/bin/env bash
# Pins the exact clauses test-weakened-test-scope.sh only checks loosely: what round 1 compares
# against, and where the "not already weakened" condition sits in the SHA choice order.
# Run: bash plugins/fleet-board/tests/test-weakened-test-pins.sh
set -u
unset CDPATH
HERE="$(cd "$(dirname "$0")" && pwd)"
AGENTS="$HERE/../agents"
SPECS="${SPECS_DIR:-$HERE/../../../docs/implementation-plans/2026-09-28-fleet-board/specs}"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }
has() { if grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1"; fi; }

pin() {
  local who="$1" f="$2"
  has "$who: round 1 reference SHA is the merge-base" "$f" 'In round 1 the reference SHA is the merge-base'
  has "$who: CHECKED order puts the not-already-weakened condition on the reference SHA option" "$f" 'the reference SHA when the test changed since it and the test at the reference SHA is not already weakened against the merge-base; otherwise the SHA from'
  has "$who: Weakened class orders reference SHA (not already weakened), then merge-base SHA" "$f" 'otherwise the reference SHA when the test at it is not already weakened against the merge-base, otherwise the merge-base SHA'
}

pin agent "$AGENTS/reviewer.md"
if [ -d "$SPECS" ]; then pin spec "$SPECS/reviewer.md"; else echo "skip - no specs at $SPECS"; fi
exit $fail
