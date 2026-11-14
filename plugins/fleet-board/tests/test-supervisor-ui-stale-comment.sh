#!/usr/bin/env bash
# supervisor-ui.js must not keep the stale "carries no stuck findings" comment.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
n=$(grep -c "carries no stuck findings" "$here/supervisor-ui.js")
if [ "$n" = "0" ]; then
  echo "ok - supervisor-ui.js has no 'carries no stuck findings' comment"
else
  echo "not ok - supervisor-ui.js still has $n 'carries no stuck findings' line(s)"
  exit 1
fi
