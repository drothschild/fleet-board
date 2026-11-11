#!/bin/bash
# Offline contract cases for boot registration, service files and boot recovery.
# Generated-file tests do not prove reboot behaviour; see docs/overnight.md.
set -eu
unset CDPATH
plugin_dir=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/supervisor-boot.XXXXXX")
. "$plugin_dir/tests/supervisor-socket-base.sh"
socket_base_snapshot
trap 'pkill -f "supervisor.cli serve --domain (/private)?/tmp/fbb-" 2>/dev/null || true; rm -rf "$tmp"; socket_base_cleanup' EXIT
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$plugin_dir/scripts" python3 "$plugin_dir/fixtures/supervisor/boot_cases.py" "$tmp"
