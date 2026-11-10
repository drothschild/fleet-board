#!/bin/bash
set -e
unset CDPATH
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}"
export PYTHONPATH
exec python3 -m supervisor.cli "$@"
