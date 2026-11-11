#!/usr/bin/env bash
set -euo pipefail
unset CDPATH
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v node >/dev/null 2>&1; then
  echo "not ok - Node.js is required for supervisor UI tests" >&2
  exit 1
fi
node "$HERE/supervisor-ui.js"
