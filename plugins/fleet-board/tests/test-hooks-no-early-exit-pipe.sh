#!/usr/bin/env bash
# test-hooks-no-early-exit-pipe.sh - the hooks never pipe printf or echo into a reader that
# can stop before reading everything (awk with exit, head, grep -q).
#
# Such a reader closes the pipe while printf is still writing; printf then prints
# "printf: Broken pipe" to stderr, which the gate's callers (and test-gate.sh's
# "no stderr" cases) see as hook output. On 2026-11-17 main's CI failed that way on
# gate.sh line 631. Feed the reader a here-string (<<<"$var") instead.
#
# Usage: bash plugins/fleet-board/tests/test-hooks-no-early-exit-pipe.sh

set -uo pipefail
unset CDPATH
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
HOOKS="$SCRIPT_DIR/../hooks"
PASS=0
FAIL=0

# Lines that pipe printf/echo into awk ... exit, head, or grep with a q flag
PATTERN='(printf|echo)[^|]*[^|]\|[[:space:]]*(awk[^|]*[^a-z_]exit([^a-z_]|$)|head([[:space:]]|$)|grep([[:space:]]+-[^[:space:]|]+)*[[:space:]]+(-[a-zA-Z]*q[a-zA-Z]*|--quiet)([[:space:]]|$))'

# The pattern itself must catch the shape it is for, and leave a here-string alone
if printf '%s\n' "x=\"\$(printf '%s\\n' \"\$info\" | awk '{ print; exit }')\"" | grep -cE "$PATTERN" >/dev/null; then
  PASS=$((PASS + 1)); echo "  ok   the pattern catches printf piped into awk with exit"
else
  FAIL=$((FAIL + 1)); echo "  FAIL the pattern catches printf piped into awk with exit"
fi
for shape in 'echo "$v" | grep -E -q foo' 'echo "$v" | grep --quiet foo' 'printf x | head -1'; do
  if printf '%s\n' "$shape" | grep -cE "$PATTERN" >/dev/null; then
    PASS=$((PASS + 1)); echo "  ok   the pattern catches: $shape"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL the pattern catches: $shape"
  fi
done
if printf '%s\n' "x=\"\$(awk '{ print; exit }' <<<\"\$info\")\"" | grep -cE "$PATTERN" >/dev/null; then
  FAIL=$((FAIL + 1)); echo "  FAIL the pattern leaves a here-string alone"
else
  PASS=$((PASS + 1)); echo "  ok   the pattern leaves a here-string alone"
fi

files=("$HOOKS"/*.sh)
if [ -f "${files[0]}" ]; then
  PASS=$((PASS + 1)); echo "  ok   the hooks directory has shell files to scan (${#files[@]})"
else
  FAIL=$((FAIL + 1)); echo "  FAIL the hooks directory has shell files to scan: none under $HOOKS"
fi
hits="$(grep -nE "$PATTERN" "${files[@]}" 2>/dev/null)"
if [ -z "$hits" ]; then
  PASS=$((PASS + 1)); echo "  ok   no hook pipes printf or echo into an early-exit reader"
else
  FAIL=$((FAIL + 1)); echo "  FAIL no hook pipes printf or echo into an early-exit reader:"
  printf '%s\n' "$hits" | sed 's/^/       /'
fi

echo ""
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
