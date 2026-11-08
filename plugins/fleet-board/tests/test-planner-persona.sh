#!/usr/bin/env bash
# Plain-bash tests for the planner persona file (config key planner.persona
# and board-web.py resolve_persona()).
# Usage: bash plugins/fleet-board/tests/test-planner-persona.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPTS="${SCRIPT_DIR}/../scripts"
DEFAULT_PERSONA="${SCRIPT_DIR}/../skills/planner/references/persona.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

# resolve <root> <persona-json>: prints JSON {"text":..., "warning":...}
resolve() {
  python3 -I - "$SCRIPTS/board-web.py" "$1" "$2" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("board_web", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
cfg = {"planner": {"persona": json.loads(sys.argv[3])}}
text, warning = m.resolve_persona(sys.argv[2], cfg)
print(json.dumps({"text": text, "warning": warning}))
PY
}
field() { python3 -I -c 'import json,sys; v=json.load(sys.stdin)[sys.argv[1]]; sys.stdout.write("" if v is None else v)' "$1"; }

echo "Case: planner.persona unset returns the shipped default"
mkdir -p "$TMP/repo"
out="$(resolve "$TMP/repo" null 2>&1)"
text="$(printf '%s' "$out" | field text 2>/dev/null)"
if [ -f "$DEFAULT_PERSONA" ] && [ -n "$text" ] && [ "$text" = "$(cat "$DEFAULT_PERSONA")" ]; then
  pass "planner.persona unset: resolve_persona returns shipped default text"
else fail "planner.persona unset: resolve_persona returns shipped default text" "got: $out"; fi

echo "Case: planner.persona set to an existing file"
printf 'my custom persona\n' > "$TMP/repo/mine.md"
out="$(resolve "$TMP/repo" '"mine.md"' 2>&1)"
text="$(printf '%s' "$out" | field text 2>/dev/null)"
if [ "$text" = "$(cat "$TMP/repo/mine.md")" ]; then
  pass "planner.persona set to existing file: resolve_persona returns that file's text"
else fail "planner.persona set to existing file: resolve_persona returns that file's text" "got: $out"; fi

echo "Case: planner.persona set to a missing file"
out="$(resolve "$TMP/repo" '"nope/missing.md"' 2>&1)"
text="$(printf '%s' "$out" | field text 2>/dev/null)"
warn="$(printf '%s' "$out" | field warning 2>/dev/null)"
if [ -f "$DEFAULT_PERSONA" ] && [ "$text" = "$(cat "$DEFAULT_PERSONA")" ] && case "$warn" in *nope/missing.md*) true;; *) false;; esac; then
  pass "planner.persona set to missing file: falls back to shipped default and warns naming the path"
else fail "planner.persona set to missing file: falls back to shipped default and warns naming the path" "got: $out"; fi

echo "Case: config default and shipped persona are portable"
cfg_default="$(grep -c '"persona"' "$SCRIPTS/config-defaults.json")"
if [ "$cfg_default" -ge 1 ]; then pass "config-defaults.json declares planner.persona"
else fail "config-defaults.json declares planner.persona" "no persona key"; fi
if [ -f "$DEFAULT_PERSONA" ] && ! grep -Eq '/Users/|/home/|~/' "$DEFAULT_PERSONA" "$SCRIPTS/config-defaults.json"; then
  pass "no absolute or personal path in the shipped default or config-defaults.json"
else fail "no absolute or personal path in the shipped default or config-defaults.json" "missing persona file or path found"; fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
