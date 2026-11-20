#!/usr/bin/env bash
# install.sh <guard-dir> <worktree> <branch> - build a directory of command shims for a provider session.
#
# The shims (gh, git, curl, board-move, board-move.sh, premise-settle.sh) are put first on the
# provider session's PATH by start.sh, and only there: nothing here changes any PATH, and no Claude
# role session is started through this directory. Each shim runs shim.sh, which builds a PreToolUse
# payload and runs hooks/gate.sh on it, then applies the implementor's own rules.
#
# Exit 0 prints the guard directory. Exit 2 (fail closed, nothing built) when the worktree is not a
# directory, is not on <branch>, or the directory cannot be written.
set -uo pipefail
unset CDPATH
[ $# -eq 3 ] || { echo "usage: install.sh <guard-dir> <worktree> <branch>" >&2; exit 2; }
GUARD_DIR="$1"; WT_IN="$2"; BRANCH="$3"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/../../.." && pwd)"

refuse() { printf 'fleet-board guard: %s\n' "$1" >&2; exit 2; }

[ -d "$WT_IN" ] || refuse "worktree $WT_IN does not exist; no guard built"
WT="$(cd "$WT_IN" && pwd -P)" || refuse "cannot enter worktree $WT_IN"
CUR="$(git -C "$WT" branch --show-current 2>/dev/null)" || refuse "$WT is not a git worktree"
[ "$CUR" = "$BRANCH" ] || refuse "worktree is on '$CUR', not on the card's branch '$BRANCH'"
case "$BRANCH" in ''|*[!A-Za-z0-9._/-]*) refuse "branch name '$BRANCH' has characters the guard does not accept" ;; esac

mkdir -p "$GUARD_DIR" || refuse "cannot create $GUARD_DIR"
GUARD_DIR="$(cd "$GUARD_DIR" && pwd -P)" || refuse "cannot enter $GUARD_DIR"

# the PATH a shim hands to the real command: this PATH without the guard directory
REAL_PATH=""
IFS=: read -r -a PARTS <<<"$PATH"
for p in "${PARTS[@]}"; do
  [ -n "$p" ] || continue
  [ "$p" = "$GUARD_DIR" ] && continue
  REAL_PATH="${REAL_PATH:+$REAL_PATH:}$p"
done

{
  printf 'GUARD_WORKTREE=%q\n' "$WT"
  printf 'GUARD_BRANCH=%q\n' "$BRANCH"
  printf 'GUARD_REAL_PATH=%q\n' "$REAL_PATH"
  printf 'GUARD_SCRIPTS=%q\n' "${FLEET_SCRIPTS:-$PLUGIN/scripts}"
  printf 'GUARD_GATE=%q\n' "$PLUGIN/hooks/gate.sh"
} > "$GUARD_DIR/guard.env" || refuse "cannot write $GUARD_DIR/guard.env"

for name in gh git curl board-move board-move.sh premise-settle.sh; do
  {
    printf '#!/bin/bash\n'
    printf 'exec bash %q %q %q "$@"\n' "$HERE/shim.sh" "$GUARD_DIR" "$name"
  } > "$GUARD_DIR/$name" || refuse "cannot write shim $name"
  chmod +x "$GUARD_DIR/$name" || refuse "cannot make shim $name executable"
done
printf '%s\n' "$GUARD_DIR"
