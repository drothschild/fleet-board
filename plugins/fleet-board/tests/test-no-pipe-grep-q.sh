#!/usr/bin/env bash
#
# Guard: a suite that sets pipefail must not pipe into `grep -q`. grep -q exits
# at the first match; a producer still writing gets SIGPIPE (141), and pipefail
# fails a check that holds. Use `grep -c... >/dev/null` instead.
#
# Usage: bash plugins/fleet-board/tests/test-no-pipe-grep-q.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SELF="$(basename "${BASH_SOURCE[0]:-$0}")"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

# A pipe into grep with a flag cluster holding q (other flag words may come first).
PIPE_Q='\| *grep +(-[A-Za-z-]+ +)*-[A-Za-z]*q'

# scan DIR: print "file:line:text" for each pipe into grep -q in a pipefail suite
# under DIR. The guard's own file is skipped (it holds the pattern strings).
scan() {
  local dir="$1" f
  for f in "$dir"/*.sh; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "$SELF" ] && continue
    grep -c 'pipefail' "$f" >/dev/null || continue
    grep -nE "$PIPE_Q" "$f" | sed "s|^|$(basename "$f"):|"
  done
}

hits="$(scan "$SCRIPT_DIR")"
if [ -z "$hits" ]; then
  pass "no pipefail suite pipes into grep -q"
else
  fail "pipefail suites pipe into grep -q: $hits"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A copy of a pipefail suite with a pipe into grep -q added is caught by file and line.
src="test-up-docs.sh"
cp "$SCRIPT_DIR/$src" "$TMP/$src"
printf "awk '1' f | grep -qF x && r=ok\n" >> "$TMP/$src"
want_line="$(wc -l < "$TMP/$src" | tr -d ' ')"
out="$(scan "$TMP")"
if printf '%s\n' "$out" | grep -cF "$src:$want_line:" >/dev/null; then
  pass "guard fails naming the file and line when a copy of a pipefail suite gains a grep -q pipe"
else
  fail "guard missed the added grep -q pipe (got: $out)"
fi

# A copy without pipefail is not flagged.
printf 'set -u\nawk 1 f | grep -qF x\n' > "$TMP/plain.sh"
rm -f "$TMP/$src"
if [ -z "$(scan "$TMP")" ]; then
  pass "a suite without pipefail is not flagged"
else
  fail "a suite without pipefail was flagged"
fi

# Producer keeps writing after the match: grep -c ... >/dev/null passes, grep -q fails.
( set -o pipefail; { echo match; head -c 200000 /dev/zero | tr '\0' x; } | grep -cF match >/dev/null )
rc_c=$?
if [ "$rc_c" -eq 0 ]; then
  pass "grep -cF >/dev/null passes under pipefail when the producer keeps writing"
else
  fail "grep -cF >/dev/null exited $rc_c under pipefail"
fi
( set -o pipefail; { echo match; head -c 200000 /dev/zero | tr '\0' x; } | grep -qF match )
rc_q=$?
if [ "$rc_q" -ne 0 ]; then
  pass "the same pipeline with grep -qF exits non-zero under pipefail"
else
  fail "grep -qF pipeline exited 0; the SIGPIPE hazard did not show"
fi

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
