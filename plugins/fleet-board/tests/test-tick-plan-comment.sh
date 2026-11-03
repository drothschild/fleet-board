#!/usr/bin/env bash
#
# Plain-bash test: the review-action comment in tick-plan.sh matches the
# manager's rule (prev_sha is last_review.sha, or base when no previous review).
#
# Usage: bash plugins/fleet-board/tests/test-tick-plan-comment.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SRC="$SCRIPT_DIR/../scripts/tick-plan.sh"
FAIL=0

n=$(grep -c 'prev_sha = last_review.sha' "$SRC")
if [ "$n" = "0" ]; then echo "  ok   comment no longer claims prev_sha is always last_review.sha"
else echo "  FAIL comment still says 'prev_sha = last_review.sha' ($n)"; FAIL=1; fi

if grep -q 'base when there is no previous review' "$SRC"; then echo "  ok   comment names the base fallback"
else echo "  FAIL comment lacks the base fallback"; FAIL=1; fi

exit "$FAIL"
