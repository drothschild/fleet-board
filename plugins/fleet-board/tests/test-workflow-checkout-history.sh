#!/usr/bin/env bash
# The version history check on merged main needs the complete checkout ancestry.
set -u
unset CDPATH
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

if awk '
  /uses: actions\/checkout@/ { in_checkout=1; next }
  in_checkout && /^[[:space:]]*-[[:space:]]/ { in_checkout=0 }
  in_checkout && /fetch-depth:[[:space:]]*0([[:space:]]*(#.*)?)?$/ { found=1 }
  END { exit !found }
' "$ROOT/.github/workflows/tests.yml"; then
  echo "ok - workflow checkout fetches full history"
  exit 0
fi

echo "not ok - workflow checkout must set fetch-depth: 0"
exit 1
