#!/usr/bin/env bash
# Card 115 (review fixes): the Revision 23 isolation evidence must really show an isolated run (built-in
# plugins only, tools exactly Edit and Read).
set -u
unset CDPATH
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$HERE/.."
SPECS="${SPECS_DIR:-$PLUGIN/../../docs/implementation-plans/2026-09-28-fleet-board/specs}"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

# The 3.5 exit-2 rules lived in the manager agent and its spec, which went with the tick system; the
# supervisor's driver treats a parse-report.sh exit 2 as its own failure (driver.py), never a re-dispatch.
if [ -d "$SPECS" ]; then
  E="$SPECS/evidence/author-status.r14.init.json"
  if [ -f "$E" ]; then
    # every plugin is built in
    plugins="$(grep -o '"plugins":\[[^]]*\]' "$E")"
    nonbuiltin="$(printf '%s\n' "$plugins" | grep -o '"source":"[^"]*"' | grep -v '@builtin"' || true)"
    paths_bad="$(printf '%s\n' "$plugins" | grep -o '"path":"[^"]*"' | grep -v '"path":"builtin"' || true)"
    if [ -n "$plugins" ] && [ -z "$nonbuiltin" ] && [ -z "$paths_bad" ]; then ok "evidence: only built-in plugins"; else bad "evidence: only built-in plugins ($nonbuiltin $paths_bad)"; fi
    if grep -qF '"tools":["Edit","Read"]' "$E"; then ok "evidence: tools are exactly Edit and Read"; else bad "evidence: tools are exactly Edit and Read"; fi
    if grep -qE '"mcp_servers":\[[^]]' "$E"; then bad "evidence: no MCP servers"; else ok "evidence: no MCP servers"; fi
    if grep -qF '"apiKeySource":"apiKeyHelper"' "$E"; then ok "evidence: apiKeySource is apiKeyHelper"; else bad "evidence: apiKeySource is apiKeyHelper"; fi
    if grep -qE '/Users/|sk-ant|ANTHROPIC_API_KEY' "$E"; then bad "evidence: no key or local path"; else ok "evidence: no key or local path"; fi
    # skills carry no plugin namespace
    if grep -o '"skills":\[[^]]*\]' "$E" | sed 's/^"skills"://' | grep -q ':'; then bad "evidence: no namespaced skills"; else ok "evidence: no namespaced skills"; fi
  else
    bad "evidence file exists"
  fi
fi
exit $fail
