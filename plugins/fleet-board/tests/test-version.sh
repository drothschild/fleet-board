#!/usr/bin/env bash
#
# Plain-bash tests for the fleet-board plugin version metadata.
#
# Usage: bash plugins/fleet-board/tests/test-version.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN="${SCRIPT_DIR}/.."
REPO="${PLUGIN}/../.."
PLUGIN_JSON="${PLUGIN}/.claude-plugin/plugin.json"
MARKETPLACE="${REPO}/.claude-plugin/marketplace.json"
# Version on main before card 56.
BASE_VERSION="0.6.0"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

plugin_version=$(sed -n 's/^  "version": "\([^"]*\)".*/\1/p' "$PLUGIN_JSON" | head -1)
market_version=$(awk '/"source": "\.\/plugins\/fleet-board"/{f=1} f && /"version"/{gsub(/.*"version": "|".*/,""); print; exit}' "$MARKETPLACE")

semver_gt() {
  local IFS=.
  local -a a b
  read -r -a a <<< "$1"
  read -r -a b <<< "$2"
  local i
  for i in 0 1 2; do
    if (( ${a[$i]:-0} > ${b[$i]:-0} )); then return 0; fi
    if (( ${a[$i]:-0} < ${b[$i]:-0} )); then return 1; fi
  done
  return 1
}

if semver_gt "$plugin_version" "$BASE_VERSION"; then
  pass "plugin.json version ($plugin_version) is higher than main's $BASE_VERSION"
else
  fail "plugin.json version ($plugin_version) is higher than main's $BASE_VERSION"
fi

if [[ -n "$market_version" && "$market_version" == "$plugin_version" ]]; then
  pass "marketplace.json version equals plugin.json version"
else
  fail "marketplace.json version ($market_version) equals plugin.json version ($plugin_version)"
fi

if [[ ! -e "${PLUGIN}/plugin.json" ]]; then
  pass "no plugin.json at the plugin root"
else
  fail "no plugin.json at the plugin root"
fi

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
