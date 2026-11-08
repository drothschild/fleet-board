#!/bin/bash
set -eu
unset CDPATH
HERE=$(cd "$(dirname "$0")" && pwd)
plugin_dir=$(cd "$HERE/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/supervisor-providers.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$plugin_dir/scripts" python3 "$plugin_dir/fixtures/supervisor/provider_cases.py" "$tmp"
