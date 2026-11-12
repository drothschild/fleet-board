#!/usr/bin/env bash
#
# The tick system is gone: the supervisor (scripts/supervisor.sh) is the only
# thing that dispatches the board's work. Checks:
#   1. the tick system's files are deleted (skills tick and run, the headless
#      wrapper, the manager agent, the cost estimator, their tests and fakes);
#   2. nothing under the plugin, its docs/ included, names the wrapper, the
#      tick or run skill or the manager agent (*.sh, *.py, *.md, *.js); the
#      repository's docs/ history is outside the plugin and not checked;
#   3. no runtime script prices tokens: no cost_usd, cost_estimate or price
#      lookup under scripts/ (tokens are the only unit);
#   4. the board page has no tick-wrapper controls: no /api/run route, no
#      Start/Stop/log buttons or run pill outside the supervisor panel, no
#      tick-stop file, no "ignored by the running supervisor" banner.
#
# Usage: bash plugins/fleet-board/tests/test-no-tick-system.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

# grep_absent NAME GREP_ARGS...: passes only when grep exits 1 (no match).
grep_absent() {
  local name="$1" out rc
  shift
  out="$(grep "$@" 2>&1)"
  rc=$?
  case "$rc" in
    1) pass "$name" ;;
    0) fail "$name" "$(printf '%s' "$out" | head -20 | tr '\n' ' ')" ;;
    *) fail "$name" "grep error (exit $rc): $(printf '%s' "$out" | tr '\n' ' ')" ;;
  esac
}

echo "the tick system is removed"

echo "deleted files"
for rel in skills/tick skills/run scripts/fleet-board-run.sh agents/manager.md \
  scripts/estimate-cost.sh scripts/prices.json \
  tests/test-run.sh tests/test-run-ratelimit.sh tests/test-tick-background.sh tests/fake-run.sh \
  tests/test-estimate-cost.sh tests/behavioral-tick.sh \
  tests/test-manager-blocked-from.sh tests/test-manager-completion.sh \
  tests/test-manager-conflict-dispatch.sh tests/test-manager-evidence-review.sh tests/test-manager-stages.sh; do
  if [ -e "$PLUGIN_DIR/$rel" ]; then
    fail "$rel is deleted" "still present"
  else
    pass "$rel is deleted"
  fi
done

echo "no reference to the wrapper, the tick skill or the manager agent"
grep_absent "no file names fleet-board-run, /fleet-board:tick or agents/manager.md" \
  -rn -e 'fleet-board-run' -e '/fleet-board:tick' -e 'agents/manager\.md' \
  --include='*.sh' --include='*.py' --include='*.md' --include='*.js' \
  --exclude='test-no-tick-system.sh' "$PLUGIN_DIR"
grep_absent "no file names the run skill or the manager agent type" \
  -rnE '/fleet-board:run\b|fleet-board:manager([^-]|$)' \
  --include='*.sh' --include='*.py' --include='*.md' --include='*.js' \
  --exclude='test-no-tick-system.sh' "$PLUGIN_DIR"

echo "tokens only: no runtime script prices tokens"
# config.sh is left out: it names the removed keys (limits.max_cost_usd, an old price) only to refuse or drop them.
grep_absent "no cost_usd, cost_estimate or price under scripts/" \
  -rnE 'cost_usd|cost_estimate|max_cost|PRICE_|\.price\b|"price"|price:' --exclude=config.sh "$PLUGIN_DIR/scripts"

echo "the board page has no tick-wrapper controls"
WEB="$PLUGIN_DIR/scripts/board-web.py"
STATIC="$PLUGIN_DIR/scripts/board-web/static"
grep_absent "board-web.py has no /api/run route" -nE '"/api/run|r"/api/run' "$WEB"
grep_absent "board-web.py has no tick-stop file, wrapper or marker clearing" \
  -nE 'fleet-board\.stop|STOP_FILE|FLEET_BOARD_RUN\b|clear_markers|cost_estimate|start_run|stop_run' "$WEB"
grep_absent "board.js has no /api/run call or legacy run controls" \
  -nE '/api/run|startRun|stopRun|pollRun|runPillText|stuckIgnoredText|ignored by the running' "$STATIC/board.js"
grep_absent "index.html has no legacy Start, Stop, log button or run pill" \
  -nE 'id="(start-btn|stop-btn|log-btn|run-pill|run-pill-text|run-hours|log)"' "$STATIC/index.html"

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
