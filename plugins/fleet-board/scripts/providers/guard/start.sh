#!/usr/bin/env bash
# start.sh <card> <root> <worktree> <branch> <tmpdir> -- <command> [args...]
#
# Runs a provider command behind the guard: builds the sandbox flags (sandbox-flags.sh), installs the
# shims into <tmpdir>/guard-shims, takes the post-run snapshot, runs the command with the guard
# directory first on its PATH only, then runs the post-run check.
#
# A word {flags} in the command is replaced by the sandbox flags; they are also in
# FLEET_GUARD_FLAGS. Fail closed: when the flags, the shims or the snapshot cannot be made, the command
# does not run, one comment on the card names the attention, stdout is {"attention": ..., "differences": []}
# and the exit is 2. After a session that changed what it must leave alone: the same JSON, the comment,
# exit 3. Otherwise the exit is the command's own.
#
# On INT or TERM the command's process group is stopped, then the same post-run check runs: a change, or
# a check that cannot run, ends as above (exit 3); a clean check exits 143.
set -uo pipefail
unset CDPATH
usage() { echo "usage: start.sh <card> <root> <worktree> <branch> <tmpdir> -- <command> [args...]" >&2; exit 2; }
[ $# -ge 7 ] && [ "$6" = -- ] || usage
CARD="$1"; ROOT="$2"; WT="$3"; BRANCH="$4"; TMPD="$5"
shift 6
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="${FLEET_SCRIPTS:-$(cd "$HERE/../.." && pwd)}"
export FLEET_SCRIPTS="$SCRIPTS"

attention() { # attention REASON RC: comment on the card, print the JSON, exit
  local reason="$1" rc="$2" f
  printf 'fleet-board guard: %s\n' "$reason" >&2
  f="$(mktemp)" && {
    printf 'Waiting for a person: the provider guard raised an attention: %s\n' "$reason" > "$f"
    (cd "$ROOT" 2>/dev/null && bash "$SCRIPTS/board-comment.sh" "$CARD" "$f" > /dev/null 2>&1) || true
    rm -f "$f"
  }
  jq -nc --arg r "$reason" '{attention: $r, differences: []}'
  exit "$rc"
}

FLAGS="$(bash "$HERE/sandbox-flags.sh" "$WT" "$TMPD" 2>&1)" || attention "the sandbox flags could not be built, so no provider session started: ${FLAGS#fleet-board guard: }" 2
SHIMS="$(bash "$HERE/install.sh" "$TMPD/guard-shims" "$WT" "$BRANCH" 2>&1)" || attention "the command shims could not be built, so no provider session started: ${SHIMS#fleet-board guard: }" 2
SNAP="$TMPD/guard-snapshot.json"
bash "$HERE/post-run.sh" snapshot "$SNAP" "$ROOT" "$WT" "$BRANCH" "$CARD" 2> /dev/null \
  || attention "the start state could not be recorded, so no provider session started" 2

CMD=()
for a in "$@"; do
  if [ "$a" = '{flags}' ]; then
    # shellcheck disable=SC2206
    CMD+=($FLAGS)
  else
    CMD+=("$a")
  fi
done

finish() { # finish RC: the post-run check, which a further INT or TERM does not interrupt; exit RC when clean
  trap '' INT TERM
  OUT="$(bash "$HERE/post-run.sh" check "$SNAP" "$ROOT" "$WT" "$BRANCH" "$CARD" 2> /dev/null)"
  CRC=$?
  case "$CRC" in
    0) exit "$1" ;;
    3) attention "$(jq -r '.attention' <<<"$OUT")" 3 ;;
    *) attention "the post-run check could not run" 3 ;;
  esac
}

stop() { # end the command's process group (TERM, then KILL after 5s), then check what it left behind
  local i=0
  trap '' INT TERM
  kill -TERM -- "-$CPID" 2>/dev/null
  while kill -0 -- "-$CPID" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  kill -KILL -- "-$CPID" 2>/dev/null
  wait "$CPID" 2>/dev/null
  finish 143
}

# The command gets its own process group, so all of it can be stopped while this script lives on to check.
# A signal that arrives before the group's id is known is only noted, and acted on right after.
STOPPED=0
trap 'STOPPED=1' INT TERM
set -m
( export FLEET_GUARD_FLAGS="$FLAGS" PATH="$SHIMS:$PATH"; exec "${CMD[@]}" ) <&0 &
CPID=$!
set +m
trap stop INT TERM
[ "$STOPPED" = 0 ] || stop
RC=0
wait "$CPID" || RC=$?
finish "$RC"
