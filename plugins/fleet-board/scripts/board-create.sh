#!/usr/bin/env bash
set -uo pipefail
unset CDPATH # a relative cd must not follow CDPATH (it would also echo the path)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"
[ $# -ge 2 ] || fb_die 2 "usage: board-create.sh <title> <body-file> [--label L]..."
[ -f "$2" ] || fb_die 2 "file not found: $2"

# Validate arguments after the first two
TITLE="$1"
BODY_FILE="$2"
shift 2
LABELS=()
FB_CREATE_STATE=backlog
while [ $# -gt 0 ]; do
  if [ "$1" = "--label" ]; then
    shift
    [ $# -gt 0 ] || fb_die 2 "usage: board-create.sh <title> <body-file> [--label L]..."
    [ -n "$1" ] || fb_die 2 "usage: board-create.sh <title> <body-file> [--label L]..."
    LABELS+=("--label" "$1")
    shift
  elif [ "$1" = "--state" ]; then
    shift
    [ $# -gt 0 ] || fb_die 2 "usage: board-create.sh <title> <body-file> [--label L]... [--state ready|backlog]"
    case "$1" in ready|backlog) FB_CREATE_STATE="$1" ;; *) fb_die 2 "--state must be ready or backlog, got: $1" ;; esac
    shift
  else
    fb_die 2 "usage: board-create.sh <title> <body-file> [--label L]..."
  fi
done

fb_load_config
export FB_CREATE_STATE
exec bash "$FLEET_SCRIPTS/adapters/$(fb_cfg board.backend)/create.sh" "$TITLE" "$BODY_FILE" "${LABELS[@]+"${LABELS[@]}"}"
