#!/bin/bash
set -eu
unset CDPATH
HERE=$(cd "$(dirname "$0")" && pwd)
PYTHONDONTWRITEBYTECODE=1 python3 "$HERE/../fixtures/supervisor/runner_cases.py"
