#!/usr/bin/env bash
# board-web.sh - serves the local board page and API on 127.0.0.1.
#
# Usage: board-web.sh [--repo DIR] [--port N]
#
# Runs from the repo root (DIR, default $PWD; the main checkout, the directory
# holding the git common dir, so a linked worktree serves the main store). The
# port defaults to board.port; --port takes 1024-65535. Needs board.backend:
# local and python3.
#
# Exit codes:
#   1 - not a git repository, a config read failed, python3 is not on PATH, or
#       (from board-web.py) the port is in use
#   2 - usage error (including a --port outside 1024-65535), or board.backend is not local
#   3, 4, 5 - config.sh --check failed (3: no .fleet-board.yml)
# Otherwise it execs board-web.py, which serves until interrupted.

set -uo pipefail
unset CDPATH # a relative cd must not follow CDPATH (it would also echo the path)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USAGE="usage: board-web.sh [--repo DIR] [--port N]"
die() { printf 'board-web: %s\n' "$2" >&2; exit "$1"; }

DIR="$PWD"
PORT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      [ $# -ge 2 ] || die 2 "$USAGE"
      DIR="$2"
      shift 2
      ;;
    --port)
      [ $# -ge 2 ] || die 2 "$USAGE"
      # 1024-65535 (the board.port range); the length check keeps the test in range for bash
      case "$2" in ''|*[!0-9]*|0*) die 2 "$USAGE" ;; esac
      [ "${#2}" -le 5 ] && [ "$2" -ge 1024 ] && [ "$2" -le 65535 ] || die 2 "$USAGE"
      PORT="$2"
      shift 2
      ;;
    *) die 2 "$USAGE" ;;
  esac
done

cd "$DIR" 2>/dev/null || die 2 "cannot cd to $DIR"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$ROOT" ] || die 1 "$DIR is not inside a git repository"
# The root is the main checkout, the directory holding the git common dir, as
# board-lib.sh resolves FLEET_ROOT: from a linked worktree the page then shows
# the store the scripts write
COMMON="$(. "$HERE/board-lib.sh" && fb_git_common_dir .)" && [ -n "$COMMON" ] && ROOT="$(dirname "$COMMON")"
cd "$ROOT" || die 1 "cannot cd to $ROOT"

bash "$HERE/config.sh" --dir "$ROOT" --check </dev/null
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"

cfg() {
  local v
  v="$(bash "$HERE/config.sh" --dir "$ROOT" "$1" </dev/null)" || die 1 "cannot read $1 from the config"
  printf '%s' "$v"
}

BACKEND="$(cfg board.backend)" || exit 1
[ "$BACKEND" = local ] || die 2 "board.backend is $BACKEND; the board page needs local"
if [ -z "$PORT" ]; then
  PORT="$(cfg board.port)" || exit 1
fi

command -v python3 >/dev/null 2>&1 || die 1 "python3 is not on PATH"
exec python3 "$HERE/board-web.py" --root "$ROOT" --port "$PORT" --scripts "$HERE"
