#!/usr/bin/env bash
set -euo pipefail
unset CDPATH
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
if ! command -v node >/dev/null 2>&1; then
  echo "not ok - Node.js is required for supervisor UI tests" >&2
  exit 1
fi
TMP="$(mktemp -d "${TMPDIR:-/tmp}/supervisor-ui.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Drift guard: the status payloads a REAL Service produces.
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$PLUGIN/scripts" \
  python3 "$PLUGIN/fixtures/supervisor/dump_real_shapes.py" "$TMP/real-shapes.json"

# The shapes carry the premise counts a supervisor now reports.
python3 - "$TMP/real-shapes.json" <<'PY'
import json, sys
keys = {'checked', 'go', 'needs', 'built', 'stale', 'drafted', 'failed'}
shapes = json.load(open(sys.argv[1]))
for name, shape in shapes.items():
    premise = shape['status'].get('premise')
    if not isinstance(premise, dict) or set(premise) != keys:
        print('not ok - the %s shape lacks the premise counts: %r' % (name, premise), file=sys.stderr)
        sys.exit(1)
PY

# The suite must leave nothing behind in the repository (it once rewrote a file under
# .superpowers on every run): any file touched under the checkout after the marker fails.
touch "$TMP/marker"
SUPERVISOR_REAL_SHAPES="$TMP/real-shapes.json" node "$HERE/supervisor-ui.js"
ROOT="$(cd "$PLUGIN/../.." && pwd)"
if [ -d "$ROOT/.superpowers" ]; then
  touched="$(find "$ROOT/.superpowers" -type f -newer "$TMP/marker" 2>/dev/null | head -5)"
  if [ -n "$touched" ]; then
    echo "not ok - supervisor UI suite wrote into the repository: $touched" >&2
    exit 1
  fi
fi
