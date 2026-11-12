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
#      tick-stop file, no "ignored by the running supervisor" banner;
#   5. no leftover names the cost estimator, its price table or the tick-stop
#      file (*.json and *.html included), except the upgrade notes in the README and
#      docs/config.md;
#   6. no skill, agent, hook, script or doc names a removed config key, except
#      config.sh's refusal table and the upgrade notes;
#   7. no agent, skill or the plugin's CLAUDE.md says "fleet-board manager",
#      and no agent or skill says "the manager" except the quoted re-dispatch
#      text "rejected by the manager:" (the supervisor dispatches the roles);
#   8. no file is named settle.sh, and nothing names it outside the upgrade
#      notes (test-readme-claims.sh, which checks the docs, excepted).
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
  scripts/settle.sh tests/test-settle.sh \
  tests/test-manager-blocked-from.sh tests/test-manager-completion.sh \
  tests/test-manager-conflict-dispatch.sh tests/test-manager-evidence-review.sh tests/test-manager-stages.sh; do
  if [ -e "$PLUGIN_DIR/$rel" ]; then
    fail "$rel is deleted" "still present"
  else
    pass "$rel is deleted"
  fi
done

# The upgrade notes say what was removed: the README's "Upgrading from an earlier version" section and the
# paragraph of docs/config.md that names the removed keys. They are the only notes excluded below.
README="$PLUGIN_DIR/README.md"
CONFIG_MD="$PLUGIN_DIR/docs/config.md"
up_from="$(grep -n '^### Upgrading from an earlier version$' "$README" | head -1 | cut -d: -f1)"
up_to="$(awk -v s="${up_from:-0}" 'NR > s && /^#/ {print NR; exit}' "$README")"
if [ -n "$up_from" ] && [ -n "$up_to" ]; then
  pass "the README's upgrade section is found"
else
  fail "the README's upgrade section is found" "no '### Upgrading from an earlier version' section"
fi
UPGRADE_NOTES='($1 == r && $2 > a && $2 < b) || ($1 == c && /belonged to the tick system/)'

# absent_but NAME KEEP GREP_ARGS...: passes when every line grep prints (path:line:text) is one KEEP leaves
# out. KEEP is an awk condition (fields split on ":"; r, a, b and c name the upgrade notes). A grep error
# (exit 2) fails.
absent_but() {
  local name="$1" keep="$2" out rc left
  shift 2
  out="$(grep "$@" 2>&1)"
  rc=$?
  if [ "$rc" -gt 1 ]; then
    fail "$name" "grep error (exit $rc): $(printf '%s' "$out" | tr '\n' ' ')"
    return
  fi
  left="$(printf '%s\n' "$out" | awk -F: -v r="$README" -v a="${up_from:-0}" -v b="${up_to:-0}" -v c="$CONFIG_MD" \
    -v cs="$PLUGIN_DIR/scripts/config.sh" '$0 == "" { next } '"$keep"' { next } { print }')"
  if [ -z "$left" ]; then pass "$name"; else fail "$name" "$(printf '%s' "$left" | head -20 | tr '\n' ' ')"; fi
}
INCLUDES="--include=*.sh --include=*.py --include=*.md --include=*.js --include=*.json --include=*.html"

echo "no reference to the wrapper, the tick skill or the manager agent"
# shellcheck disable=SC2086 # INCLUDES is a list of options
grep_absent "no file names fleet-board-run or agents/manager.md" \
  -rn -e 'fleet-board-run' -e 'agents/manager\.md' $INCLUDES --exclude='test-no-tick-system.sh' "$PLUGIN_DIR"
# shellcheck disable=SC2086
grep_absent "no file names fleet-board:run, fleet-board:tick or the manager agent type" \
  -rnE 'fleet-board:(run|tick)\b|fleet-board:manager([^-]|$)' $INCLUDES \
  --exclude='test-no-tick-system.sh' "$PLUGIN_DIR"

echo "no leftover names the cost estimator, its prices or the tick-stop file"
# shellcheck disable=SC2086
absent_but "no estimate-cost, prices.json or .fleet-board.stop outside the upgrade notes" "$UPGRADE_NOTES" \
  -rnE 'estimate-cost|prices\.json|\.fleet-board\.stop' $INCLUDES --exclude='test-no-tick-system.sh' "$PLUGIN_DIR"

echo "settle.sh is gone, by file name and by mention"
found="$(find "$PLUGIN_DIR" -name 'settle.sh' 2>&1)"
if [ -z "$found" ]; then pass "no file named settle.sh anywhere under the plugin"; else fail "no file named settle.sh anywhere under the plugin" "$found"; fi
# test-readme-claims.sh is the check that the docs do not name it, so it names it.
# shellcheck disable=SC2086
absent_but "nothing names settle.sh outside the upgrade notes" "$UPGRADE_NOTES" \
  -rn 'settle\.sh' $INCLUDES --exclude='test-no-tick-system.sh' --exclude='test-readme-claims.sh' "$PLUGIN_DIR"

echo "no skill, agent, hook, script or doc names a removed config key"
# config.sh's refusal table names them to refuse them; the upgrade notes name them to say they went.
absent_but "no removed key outside config.sh's refusal table and the upgrade notes" \
  "$UPGRADE_NOTES"' || ($1 == cs && (/\["max_cost_usd", "tick_interval"/ || /has\("manager"\)/))' \
  -rnE 'max_cost_usd|tick_interval|min_tick_gap|max_consecutive_failures|models\.manager' \
  "$PLUGIN_DIR/skills" "$PLUGIN_DIR/agents" "$PLUGIN_DIR/hooks" "$PLUGIN_DIR/scripts" "$PLUGIN_DIR/docs"

echo "the roles are dispatched by the supervisor, not a manager"
grep_absent "no agent or skill says fleet-board manager" \
  -rni 'fleet-board manager' "$PLUGIN_DIR/agents" "$PLUGIN_DIR/skills"
grep_absent "the plugin's CLAUDE.md does not say fleet-board manager" -ni 'fleet-board manager' "$PLUGIN_DIR/CLAUDE.md"
# The quoted re-dispatch text is the driver's exact wording ("rejected by the manager:"); nothing else.
absent_but "no agent or skill names the manager, except the quoted re-dispatch text" \
  '/:rejected by the manager:$/' \
  -rnoiE 'rejected by the manager:|\bthe manager\b' "$PLUGIN_DIR/agents" "$PLUGIN_DIR/skills"

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
