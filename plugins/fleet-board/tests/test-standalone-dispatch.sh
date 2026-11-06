#!/usr/bin/env bash
# Verify the documented named acceptance cases are reachable through the dispatcher.
set -uo pipefail
case "${1:-}" in run-limits|legacy-entry) ;; *) exit 2 ;; esac
TESTS="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp)" || exit 1
trap 'rm -f "$TMP"' EXIT
if ! bash "$TESTS/test-standalone-tick.sh" "$1" > "$TMP"; then
  echo "FAIL: $1 is not reachable through the acceptance dispatcher" >&2
  exit 1
fi
if ! grep -q "PASS: $1" "$TMP"; then
  echo "FAIL: $1 did not finish its named acceptance case" >&2
  exit 1
fi
printf 'PASS: dispatch-%s\n' "$1"
