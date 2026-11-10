#!/bin/bash
set -eu
unset CDPATH
HERE=$(cd "$(dirname "$0")" && pwd)
plugin_dir=$(cd "$HERE/.." && pwd)
if [ -z "${FLEET_BOARD_DOCKER_PROBE_IMAGE:-}" ]; then
  echo "FLEET_BOARD_DOCKER_PROBE_IMAGE must name a cached immutable image ID" >&2
  exit 1
fi
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$plugin_dir/scripts" python3 -m supervisor.docker_probe
