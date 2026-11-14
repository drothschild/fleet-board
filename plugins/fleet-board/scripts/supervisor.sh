#!/bin/bash
# Exit codes: the exec'd supervisor.cli returns exit 4 when `start` is refused because
# cards are stuck (see supervisor/cli.py); other failures exit 1 or 2.
set -e
unset CDPATH
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}"
export PYTHONPATH
exec python3 -m supervisor.cli "$@"
