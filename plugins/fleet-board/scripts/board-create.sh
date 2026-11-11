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
  elif [ "$1" = "--acceptance-file" ]; then
    shift
    [ $# -gt 0 ] || fb_die 2 "usage: board-create.sh <title> <body-file> [--acceptance-file F]"
    [ -f "$1" ] || fb_die 2 "file not found: $1"
    LABELS+=("--acceptance-file" "$1")
    shift
  elif [ "$1" = "--blocked-by" ]; then
    shift
    [ $# -gt 0 ] || fb_die 2 "usage: board-create.sh <title> <body-file> [--blocked-by N]..."
    fb_valid_number "$1" || fb_die 2 "--blocked-by must be a card number, got: $1"
    LABELS+=("--blocked-by" "$1")
    shift
  else
    fb_die 2 "usage: board-create.sh <title> <body-file> [--label L]... [--state S] [--acceptance-file F] [--blocked-by N]..."
  fi
done

fb_load_config
export FB_CREATE_STATE
exec bash "$FLEET_SCRIPTS/adapters/local/create.sh" "$TITLE" "$BODY_FILE" "${LABELS[@]+"${LABELS[@]}"}"
