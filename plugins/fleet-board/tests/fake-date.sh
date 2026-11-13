#!/usr/bin/env bash
# fake-date.sh - a `date` stub for test-gate.sh, linked as `date` into the fake PATH.
# `date -u +%Y-%m-%d` prints $FB_TEST_TODAY when it is set; every other call is the real date ($REAL_DATE).
if [ -n "${FB_TEST_TODAY:-}" ] && [ "$*" = "-u +%Y-%m-%d" ]; then
  printf '%s\n' "$FB_TEST_TODAY"
  exit 0
fi
exec "${REAL_DATE:-/bin/date}" "$@"
