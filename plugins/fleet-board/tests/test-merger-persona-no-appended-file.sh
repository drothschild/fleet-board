#!/bin/bash
# The default merger persona does not call the extension an "appended" file.
set -eu
unset CDPATH
plugin_dir=$(cd "$(dirname "$0")/.." && pwd)
persona="$plugin_dir/scripts/supervisor/defaults/merger-persona.md"

n=$(grep -c "appended" "$persona" || true)
if [ "$n" = 0 ]; then
  echo "ok - The default merger persona does not contain the word appended."
else
  echo "not ok - The default merger persona does not contain the word appended ($n lines)."
  exit 1
fi
