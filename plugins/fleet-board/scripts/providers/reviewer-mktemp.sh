#!/usr/bin/env bash
# Darwin's default mktemp ignores TMPDIR. Use an explicit scratch template
# for the two implicit-template forms; preserve explicit arguments unchanged.
set -eu
: "${FLEET_REVIEW_MKTEMP:?missing original mktemp path}"
: "${TMPDIR:?missing reviewer scratch temp directory}"
if [ "$#" -eq 0 ]; then
  exec "$FLEET_REVIEW_MKTEMP" "$TMPDIR/tmp.XXXXXXXXXX"
elif [ "$#" -eq 1 ] && [ "$1" = -d ]; then
  exec "$FLEET_REVIEW_MKTEMP" -d "$TMPDIR/tmp.XXXXXXXXXX"
fi
exec "$FLEET_REVIEW_MKTEMP" "$@"
