#!/usr/bin/env bash
# board-comment.sh <number> <file> - post <file> as a comment on card <number>
#
# Dispatches to adapters/<board.backend>/comment.sh. Refuses (exit 1, nothing
# posted, before any gh call and for every backend) a body that starts with
# the manager-note marker ($FB_MARKER), after optional leading whitespace
# (CR and LF included) and an optional UTF-8 BOM. The manager reads the newest
# comment whose body starts with the marker as the card's note, so a role
# posting a stray file that starts with it would forge that note; the note is
# written only by board-note.sh. Only what the reader would trust as a note is
# refused (the slack for whitespace and a BOM covers a host that trims them).
# A marker later in the body is not a note, and refusing it would lose a
# legitimate comment for good, e.g. a Human QA comment quoting an Acceptance
# section that mentions the marker. Other fleet-board comments, such as the
# skip-no-acceptance marker, post as usual.
set -uo pipefail
unset CDPATH # a relative cd must not follow CDPATH (it would also echo the path)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"
[ $# -eq 2 ] || fb_die 2 "usage: board-comment.sh <number> <file>"
fb_valid_number "$1" || fb_die 2 "card number must be numeric, got: $1"
[ -f "$2" ] || fb_die 2 "file not found: $2"
# Exit 0 when the body starts with the marker (as above), 1 when it does not,
# 2 when the file cannot be read. The subshell keeps LC_ALL=C (byte-wise
# matching, so the BOM is three bytes) away from the adapter.
starts_with_marker() (
  LC_ALL=C
  body="$(cat -- "$1")" || exit 2
  body="${body#"${body%%[![:space:]]*}"}"
  body="${body#$'\357\273\277'}"
  body="${body#"${body%%[![:space:]]*}"}"
  case "$body" in
    "$FB_MARKER"*) exit 0 ;;
    *) exit 1 ;;
  esac
)
starts_with_marker "$2"
case $? in
  0) fb_die 1 "refusing to post $2 on #$1: it starts with the manager-note marker $FB_MARKER; only board-note.sh writes the note" ;;
  1) ;;
  *) fb_die 1 "cannot read $2 to check it for the manager-note marker" ;;
esac
fb_load_config
exec bash "$FLEET_SCRIPTS/adapters/$(fb_cfg board.backend)/comment.sh" "$@"
