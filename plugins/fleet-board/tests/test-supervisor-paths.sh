#!/bin/bash
set -eu
unset CDPATH
plugin_dir=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/supervisor-paths.XXXXXX")
. "$plugin_dir/tests/supervisor-socket-base.sh"
socket_base_snapshot
trap 'pkill -f "supervisor.cli serve --domain /tmp/fbp-" 2>/dev/null || true; rm -rf "$tmp"; socket_base_cleanup' EXIT
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$plugin_dir/scripts" python3 "$plugin_dir/fixtures/supervisor/paths_cases.py" "$tmp"
