#!/usr/bin/env bash
#
# Checks the read-only pattern in test-status.sh catches gh writes beyond
# issue edit/comment/create/close. Offline, no gh needed.
#
# Usage: bash plugins/fleet-board/tests/test-status-readonly.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TARGET="$SCRIPT_DIR/test-status.sh"
FAILS=0

pat="$(sed -n "s/^READONLY_RE='\(.*\)'\$/\1/p" "$TARGET" | head -n 1)"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
printf '%s\n' \
  'gh label create x' \
  'gh project item-edit --id 1' \
  'gh api repos/o/r/issues/1 -f title=x' \
  'gh api -X POST repos/o/r/labels' \
  'gh api repos/o/r/issues --input body.json' \
  'gh api repos/o/r/issues --input=body.json' > "$tmp"
writes="$(wc -l < "$tmp" | tr -d ' ')"

if [ -z "$pat" ]; then
  echo "FAIL read-only pattern: no READONLY_RE line found in test-status.sh"
  FAILS=$((FAILS + 1))
else
  n="$(grep -Ec "$pat" "$tmp")"
  if [ "$n" = "$writes" ]; then echo "ok   read-only pattern matches every write call"
  else echo "FAIL read-only pattern matches every write call: got $n of $writes"; FAILS=$((FAILS + 1)); fi
fi

# Plain reads must not match.
printf '%s\n' 'api repos/acme/toy/contents/input.txt' 'api repos/acme/toy/issues/40''api --paginate repos/acme/toy/issues/40/comments' \
  'issue list --repo acme/toy' 'issue view 40 --repo acme/toy --json state' > "$tmp"
if [ -n "$pat" ] && [ "$(grep -Ec "$pat" "$tmp")" = 0 ]; then echo "ok   read-only pattern ignores plain reads"
else echo "FAIL read-only pattern ignores plain reads"; FAILS=$((FAILS + 1)); fi

[ "$FAILS" = 0 ]
