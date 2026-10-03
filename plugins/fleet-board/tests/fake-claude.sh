#!/usr/bin/env bash
#
# Fake 'claude' for offline tests of the headless wrapper (fleet-board-run.sh).
# Replays stream-json fixtures instead of running a session.
#
# Environment:
#   FAKE_CLAUDE_DIR        writable state directory (required)
#   FAKE_CLAUDE_MAX_CALLS  runaway guard, default 30: an invocation beyond it
#                          sends TERM to its parent (the wrapper) and exits 97,
#                          so a wrapper that never stops fails its case instead
#                          of hanging the suite (there is no timeout(1) here)
#
# Per invocation N (1, 2, ...), in this order:
#   1. increments $FAKE_CLAUDE_DIR/count to N
#   2. appends its arguments to $FAKE_CLAUDE_DIR/args.log, one line per
#      invocation, each argument shell-quoted (printf %q) so argument
#      boundaries survive; also appends its working directory to cwd.log,
#      its pid to pids.log, its LC_ALL (empty when unset) to locale.log, and
#      `open` or `closed` to fd3.log: whether it inherited file descriptor 3
#   3. prints $FAKE_CLAUDE_DIR/N.jsonl, or default.jsonl when that is absent
#      (nothing when both are absent)
#   4. sleeps the seconds in N.sleep, when present; when N.ignore-term also
#      exists it ignores TERM (from step 1 on) and sleeps in 1 s steps, so
#      after a KILL at most a 1 s sleep outlives it
#   5. touches every path listed in N.touch (one per line), when present
#   6. exits with the contents of N.exit, default 0

set -uo pipefail

D="${FAKE_CLAUDE_DIR:?fake-claude: FAKE_CLAUDE_DIR not set}"
[ -d "$D" ] || { printf 'fake-claude: not a directory: %s\n' "$D" >&2; exit 98; }

N=0
[ -f "$D/count" ] && N="$(cat "$D/count")"
N=$((N + 1))
printf '%d\n' "$N" > "$D/count"
[ -f "$D/$N.ignore-term" ] && trap '' TERM

if [ "$N" -gt "${FAKE_CLAUDE_MAX_CALLS:-30}" ]; then
  printf 'fake-claude: runaway: invocation %d exceeds %s; killing the caller\n' "$N" "${FAKE_CLAUDE_MAX_CALLS:-30}" >&2
  kill -TERM "$PPID" 2>/dev/null
  exit 97
fi

line=""
for a in "$@"; do
  line="${line:+$line }$(printf '%q' "$a")"
done
printf '%s\n' "$line" >> "$D/args.log"
pwd -P >> "$D/cwd.log"
printf '%d\n' "$$" >> "$D/pids.log"
printf '%s\n' "${LC_ALL-}" >> "$D/locale.log"
if { true >&3; } 2>/dev/null; then echo open; else echo closed; fi >> "$D/fd3.log"

if [ -f "$D/$N.jsonl" ]; then
  cat "$D/$N.jsonl"
elif [ -f "$D/default.jsonl" ]; then
  cat "$D/default.jsonl"
fi

if [ -f "$D/$N.sleep" ]; then
  if [ -f "$D/$N.ignore-term" ]; then
    i=0
    while [ "$i" -lt "$(cat "$D/$N.sleep")" ]; do sleep 1; i=$((i + 1)); done
  else
    sleep "$(cat "$D/$N.sleep")"
  fi
fi

if [ -f "$D/$N.touch" ]; then
  while IFS= read -r p; do
    [ -n "$p" ] && touch "$p"
  done < "$D/$N.touch"
fi

rc=0
[ -f "$D/$N.exit" ] && rc="$(cat "$D/$N.exit")"
exit "$rc"
