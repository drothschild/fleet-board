#!/usr/bin/env bash
# docs/stack-dogfood.md does not exist in the repository.
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
fail=0
if [ -e "$ROOT/docs/stack-dogfood.md" ]; then
  echo "FAIL: docs/stack-dogfood.md does not exist in the repository"
  fail=1
else
  echo "PASS: docs/stack-dogfood.md does not exist in the repository"
fi
exit $fail
