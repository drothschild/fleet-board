#!/usr/bin/env bash
set -euo pipefail
unset CDPATH
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
node "$HERE/board-unknown-interaction.js"
