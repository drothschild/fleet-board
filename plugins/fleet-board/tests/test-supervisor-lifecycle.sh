#!/bin/bash
set -eu
unset CDPATH
plugin_dir=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/supervisor-lifecycle.XXXXXX")
. "$plugin_dir/tests/supervisor-socket-base.sh"
socket_base_snapshot
trap 'rm -rf "$tmp"; socket_base_cleanup' EXIT
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$plugin_dir/scripts" python3 "$plugin_dir/fixtures/supervisor/lifecycle_cases.py" "$tmp"
