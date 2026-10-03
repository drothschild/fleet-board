#!/usr/bin/env bash
#
# Plain-bash tests for fleet-board-run.sh, the headless tick loop (offline:
# tests/fake-claude.sh replays the stream-json fixtures under fixtures/claude,
# a fake cleanup script stands in for cleanup-done.sh, and a stub gh that
# always fails is first on PATH, so nothing reaches the network).
# No framework, no dependencies beyond POSIX tools, jq and git.
#
# Usage: bash plugins/fleet-board/tests/test-run.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/../scripts/fleet-board-run.sh"
FAKE_CLAUDE="$SCRIPT_DIR/fake-claude.sh"
FX="$(cd "$SCRIPT_DIR/../fixtures/claude" && pwd)"

unset FLEET_BOARD_CONFIG FLEET_BOARD_CLAUDE FLEET_BOARD_PLUGIN_DIR FLEET_BOARD_TICK_PROMPT \
  FLEET_BOARD_LOG_DIR FLEET_BOARD_ISOLATE FLEET_BOARD_CLEANUP FAKE_CLAUDE_DIR FAKE_CLAUDE_MAX_CALLS \
  FLEET_BOARD_TEST_BGJOB || true

PASS=0
FAIL=0
LAST_OUT=""
LAST_ERR=""
LAST_EXIT=0
CLEANUP_DIRS=()
ORIG_PATH="$PATH"

if [ -x /bin/bash ]; then
  BASH_EXE="/bin/bash"
else
  BASH_EXE="bash"
fi

cleanup() {
  for dir in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do
    rm -rf "$dir" 2>/dev/null || true
  done
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

assert_exit() {
  if [ "$LAST_EXIT" = "$2" ]; then pass "$1"; else fail "$1" "expected exit $2, got $LAST_EXIT (stderr: $LAST_ERR)"; fi
}
assert_stdout_contains() {
  case "$LAST_OUT" in
    *"$2"*) pass "$1" ;;
    *) fail "$1" "expected '$2' in stdout, got: '$LAST_OUT'" ;;
  esac
}
assert_stderr_contains() {
  case "$LAST_ERR" in
    *"$2"*) pass "$1" ;;
    *) fail "$1" "expected '$2' in stderr, got: '$LAST_ERR'" ;;
  esac
}
assert_stderr_not_contains() {
  case "$LAST_ERR" in
    *"$2"*) fail "$1" "did not expect '$2' in stderr, got: '$LAST_ERR'" ;;
    *) pass "$1" ;;
  esac
}
assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}
# assert_file_contains <desc> <file> <fixed string>
assert_file_contains() {
  if [ -f "$2" ] && grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1" "expected '$3' in $2"; fi
}
assert_file_not_contains() {
  if [ -f "$2" ] && ! grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1" "did not expect '$3' in $2 (or the file is missing)"; fi
}
# assert_file_matches <desc> <file> <extended regex>
assert_file_matches() {
  if [ -f "$2" ] && grep -qE -- "$3" "$2"; then pass "$1"; else fail "$1" "expected a line matching /$3/ in $2"; fi
}
assert_true() {
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d" "command failed: $*"; fi
}
assert_false() {
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$d" "command succeeded: $*"; else pass "$d"; fi
}

# ---------------------------------------------------------------------------
# Case setup

# new_case <limits extra> [<other top-level yaml lines>]
# A temp git repo whose .fleet-board.yml is
#   board: { repo: acme/toy }
#   limits: { tick_interval: 0, <limits extra> }
#   <other lines>
# plus the fake claude dir, a fake cleanup, a failing stub gh, HOME and logs.
new_case() {
  local tmp; tmp="$(mktemp -d)"
  CLEANUP_DIRS+=("$tmp")
  T="$(cd "$tmp" && pwd -P)"
  REPO="$T/repo"
  git init -q "$REPO"
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test User"
  {
    printf 'board: { repo: acme/toy }\n'
    printf 'limits: { tick_interval: 0%s }\n' "${1:+, $1}"
    [ -n "${2:-}" ] && printf '%s\n' "$2"
  } > "$REPO/.fleet-board.yml"
  mkdir -p "$REPO/sub"
  printf 'x\n' > "$REPO/sub/file"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "initial"

  FC="$T/fc"; mkdir -p "$FC"
  HOMEDIR="$T/home"; mkdir -p "$HOMEDIR"
  LOGS="$T/logs"
  BIN="$T/bin"; mkdir -p "$BIN"
  # A stub gh: logs every call and fails, so the shipped cleanup-done.sh
  # (and anything else) can never reach GitHub from this suite
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/gh-calls.log"\nexit 1\n' "$T" > "$BIN/gh"
  chmod +x "$BIN/gh"
  # The default fake cleanup: counts its runs, records its cwd, succeeds
  CLEAN="$T/cleanup.sh"
  printf '#!/bin/sh\nprintf "run\\n" >> "%s/cleanup-count"\npwd -P >> "%s/cleanup-cwd"\necho "fake cleanup ran"\necho "fake cleanup stderr" >&2\nexit ${FAKE_CLEANUP_EXIT:-0}\n' "$T" "$T" > "$CLEAN"
  chmod +x "$CLEAN"

  # Per-case knobs (empty means unset for the run)
  C_LOG_DIR="$LOGS"
  C_PLUGIN_DIR=""
  C_PROMPT=""
  C_ISOLATE=""
  C_CLEANUP="$CLEAN"
  C_CLEANUP_EXIT=""
  C_CWD="$REPO"
  C_LOCALE=""
  C_TEST_BGJOB=""
  RUN_TMP="$T/tmp"; mkdir -p "$RUN_TMP"
}

# seq_fixture <n> <fixture name>: invocation n replays fixtures/claude/<name>.jsonl
seq_fixture() { cp "$FX/$2.jsonl" "$FC/$1.jsonl"; }
default_fixture() { cp "$FX/$1.jsonl" "$FC/default.jsonl"; }

# case_env: the case's environment, applied inside the subshell that runs the
# wrapper (umask 022 so the log-mode checks do not depend on the caller's umask)
case_env() {
  unset FLEET_BOARD_LOG_DIR FLEET_BOARD_PLUGIN_DIR FLEET_BOARD_TICK_PROMPT FLEET_BOARD_ISOLATE \
    FLEET_BOARD_CLEANUP FAKE_CLEANUP_EXIT FLEET_BOARD_CONFIG FLEET_BOARD_TEST_BGJOB || true
  export HOME="$HOMEDIR" PATH="$BIN:$ORIG_PATH" FLEET_BOARD_CLAUDE="$FAKE_CLAUDE" FAKE_CLAUDE_DIR="$FC"
  [ -n "$C_LOG_DIR" ] && export FLEET_BOARD_LOG_DIR="$C_LOG_DIR"
  [ -n "$C_PLUGIN_DIR" ] && export FLEET_BOARD_PLUGIN_DIR="$C_PLUGIN_DIR"
  [ -n "$C_PROMPT" ] && export FLEET_BOARD_TICK_PROMPT="$C_PROMPT"
  [ -n "$C_ISOLATE" ] && export FLEET_BOARD_ISOLATE="$C_ISOLATE"
  [ -n "$C_CLEANUP" ] && export FLEET_BOARD_CLEANUP="$C_CLEANUP"
  [ -n "$C_CLEANUP_EXIT" ] && export FAKE_CLEANUP_EXIT="$C_CLEANUP_EXIT"
  [ -n "$C_LOCALE" ] && export LC_ALL="$C_LOCALE"
  [ -n "$C_TEST_BGJOB" ] && export FLEET_BOARD_TEST_BGJOB="$C_TEST_BGJOB"
  # A private TMPDIR, so a temp file the run leaves behind is seen
  export TMPDIR="$RUN_TMP"
  umask 022
  cd "$C_CWD" || exit 90
}

# after_run <stdout file> <stderr file>: the no-temp-files check, then LAST_OUT/LAST_ERR
after_run() {
  LEFT="$(ls -A "$RUN_TMP" | wc -l | tr -d ' ')"
  if [ "$LEFT" = 0 ]; then pass "run leaves no temp files"; else fail "run leaves no temp files" "$(ls -A "$RUN_TMP")"; fi
  LAST_OUT="$(cat "$1")"
  LAST_ERR="$(cat "$2")"
  rm -f "$1" "$2"
}

# run_wrapper [args...]: runs the wrapper in a subshell with the case env
run_wrapper() {
  local tmpout tmperr
  tmpout="$(mktemp)"
  tmperr="$(mktemp)"
  (
    case_env
    "$BASH_EXE" "$SCRIPT" "$@"
  ) > "$tmpout" 2> "$tmperr"
  LAST_EXIT=$?
  after_run "$tmpout" "$tmperr"
}

# run_wrapper_term <marker> [args...]: runs the wrapper in the background with
# the case env, waits (up to 10 s) until <marker> exists, then 1 s more, sends
# the wrapper TERM, and waits for it. TERM_SECS is the whole seconds from the
# TERM to the wrapper's exit. (TERM, not INT: a background job of a
# non-interactive shell starts with INT ignored, and bash cannot trap a signal
# ignored on entry.)
run_wrapper_term() {
  local marker="$1" tmpout tmperr pid i t0 t1
  shift
  tmpout="$(mktemp)"
  tmperr="$(mktemp)"
  (
    case_env
    exec "$BASH_EXE" "$SCRIPT" "$@"
  ) > "$tmpout" 2> "$tmperr" &
  pid=$!
  i=0
  while [ ! -e "$marker" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  sleep 1
  t0="$(date +%s)"
  kill -TERM "$pid" 2>/dev/null
  wait "$pid"
  LAST_EXIT=$?
  t1="$(date +%s)"
  TERM_SECS=$((t1 - t0))
  echo "       (TERM to exit: ${TERM_SECS} s)"
  after_run "$tmpout" "$tmperr"
}

count() { if [ -f "$FC/count" ]; then cat "$FC/count"; else echo absent; fi; }
lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
# the one run log in a directory (empty when there is not exactly one)
the_log() {
  local d="$1" n
  n="$(find "$d" -type f -name '*.log' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$n" = 1 ] && find "$d" -type f -name '*.log'
}
# the number of saved failed-tick streams (*.jsonl) under a directory
jsonl_count() { find "$1" -type f -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' '; }
# mode_of <path>: the ten-character mode column of ls -ld (BSD and GNU alike)
mode_of() { ls -ld "$1" 2>/dev/null | cut -c1-10; }
args_line() { sed -n "${1}p" "$FC/args.log" 2>/dev/null; }
# line number of the first line matching a fixed string (0 when none)
line_of() { local l; l="$(grep -nF -- "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1)"; echo "${l:-0}"; }
# a stream-json result event with the given fields, as one tick's output
result_fixture() { # <file> <jq object>
  { head -2 "$FX/tick-busy.jsonl"; jq -cn "{type:\"result\"} + $2"; } > "$1"
}

ISO='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'

echo "Test: fleet-board-run.sh"
echo ""

# ---------------------------------------------------------------------------
echo "AC6.5 stops-when-idle / AC6.9 log-appends-each-tick"
new_case
seq_fixture 1 tick-busy
seq_fixture 2 tick-idle
run_wrapper --repo "$REPO"
assert_exit "stops-when-idle: exit 0" 0
assert_stdout_contains "stops-when-idle: stop line" "stopped: nothing-dispatchable after 2 ticks"
assert_stdout_contains "stops-when-idle: full summary" "fleet-board-run: stopped: nothing-dispatchable after 2 ticks, 0.00 h, cost_estimate_usd 0.7 (estimate)"
assert_eq "stops-when-idle: count == 2" "$(count)" "2"
LOG="$(the_log "$LOGS")"
assert_true "log-appends-each-tick: exactly one file in FLEET_BOARD_LOG_DIR" test -n "$LOG"
assert_true "log-appends-each-tick: named <owner>-<name>-<YYYYmmdd-HHMMSS>.log" \
  sh -c 'basename "$1" | grep -qE "^acme-toy-[0-9]{8}-[0-9]{6}\.log$"' _ "$LOG"
assert_stdout_contains "log path printed on start" "fleet-board-run: log: ${LOG:-<no log>}"
assert_file_matches "log: tick 1 header" "$LOG" "^=== tick 1 $ISO rc=0 cost_estimate_usd=0\.6 \(estimate\) ===$"
assert_file_matches "log: tick 2 header" "$LOG" "^=== tick 2 $ISO rc=0 cost_estimate_usd=0\.1 \(estimate\) ===$"
assert_file_contains "log: tick 1 result text" "$LOG" "dispatchable: true"
assert_file_contains "log: tick 2 result text" "$LOG" "dispatchable: false"
assert_file_contains "log: stopped line" "$LOG" "fleet-board-run: stopped: nothing-dispatchable after 2 ticks, 0.00 h, cost_estimate_usd 0.7 (estimate)"
assert_eq "log: the stopped line is last" "$(tail -1 "$LOG" 2>/dev/null)" "fleet-board-run: stopped: nothing-dispatchable after 2 ticks, 0.00 h, cost_estimate_usd 0.7 (estimate)"
assert_true "log: tick 1 block before tick 2 block" \
  test "$(line_of "$LOG" "=== tick 1 ")" -gt 0 -a "$(line_of "$LOG" "=== tick 1 ")" -lt "$(line_of "$LOG" "=== tick 2 ")"
assert_eq "log: nothing under HOME" "$(find "$HOMEDIR" -type f | wc -l | tr -d ' ')" "0"
assert_eq "log: no saved stream for successful ticks" "$(jsonl_count "$LOGS")" "0"

# ---------------------------------------------------------------------------
echo "AC6.6 stops-on-hours"
new_case "max_hours: 0.0002"
default_fixture tick-busy
printf '1\n' > "$FC/1.sleep"
run_wrapper --repo "$REPO"
assert_exit "stops-on-hours: exit 0" 0
assert_stdout_contains "stops-on-hours: stop line" "stopped: max-hours after 1 ticks"
assert_eq "stops-on-hours: count == 1" "$(count)" "1"

# ---------------------------------------------------------------------------
echo "AC6.7 stops-on-cost"
new_case "max_cost_usd: 1"
default_fixture tick-busy
run_wrapper --repo "$REPO"
assert_exit "stops-on-cost: exit 0" 0
assert_stdout_contains "stops-on-cost: stop line" "stopped: max-cost after 2 ticks"
assert_stdout_contains "stops-on-cost: summary cost" "cost_estimate_usd 1.2 (estimate)"
assert_eq "stops-on-cost: count == 2" "$(count)" "2"

echo "AC6.7 cost-checked-after-tick (before the next loop's stop-file check)"
new_case "max_cost_usd: 1"
default_fixture tick-busy
printf '%s\n' "$REPO/.fleet-board.stop" > "$FC/2.touch"
run_wrapper --repo "$REPO"
assert_exit "cost-after-tick: exit 0" 0
assert_stdout_contains "cost-after-tick: max-cost, not stop-file" "stopped: max-cost after 2 ticks"

echo "AC6.7 cost-fallback-model-usage"
new_case "max_cost_usd: 0.6"
default_fixture tick-no-cost
run_wrapper --repo "$REPO"
assert_exit "cost-fallback: exit 0" 0
assert_stdout_contains "cost-fallback: stops max-cost after 3 ticks" "stopped: max-cost after 3 ticks"
assert_stdout_contains "cost-fallback: summary cost" "cost_estimate_usd 0.75 (estimate)"
LOG="$(the_log "$LOGS")"
assert_file_matches "cost-fallback: tick header from modelUsage" "$LOG" "^=== tick 1 $ISO rc=0 cost_estimate_usd=0\.25 \(estimate\) ===$"
assert_eq "cost-fallback: count == 3" "$(count)" "3"

echo "last-result-wins (several result events in one session)"
new_case
seq_fixture 1 tick-multi-result
seq_fixture 2 tick-idle
run_wrapper --repo "$REPO"
assert_exit "last-result-wins: exit 0" 0
assert_stdout_contains "last-result-wins: stops on the last result's signal" "stopped: nothing-dispatchable after 1 ticks"
assert_stdout_contains "last-result-wins: the last result's cost" "cost_estimate_usd 0.5 (estimate)"
assert_eq "last-result-wins: count == 1" "$(count)" "1"

echo "failed-tick-cost-counts"
new_case "max_cost_usd: 1, max_consecutive_failures: 5"
default_fixture tick-error
run_wrapper --repo "$REPO"
assert_exit "failed-tick-cost: exit 0" 0
assert_stdout_contains "failed-tick-cost: a failed tick's cost counts" "stopped: max-cost after 2 ticks"
assert_stdout_contains "failed-tick-cost: summary cost" "cost_estimate_usd 1.4 (estimate)"

echo "cost-unknown"
new_case
result_fixture "$FC/1.jsonl" '{subtype:"success",is_error:false,result:"r\ndispatchable: true"}'
seq_fixture 2 tick-idle
run_wrapper --repo "$REPO"
assert_exit "cost-unknown: exit 1" 1
assert_stdout_contains "cost-unknown: stops" "stopped: cost-unknown after 1 ticks"
assert_eq "cost-unknown: count == 1" "$(count)" "1"

# ---------------------------------------------------------------------------
echo "AC6.8 stop-file-before-start"
new_case
default_fixture tick-busy
touch "$REPO/.fleet-board.stop"
run_wrapper --repo "$REPO"
assert_exit "stop-file-before-start: exit 0" 0
assert_stdout_contains "stop-file-before-start: stop line" "stopped: stop-file after 0 ticks"
assert_eq "stop-file-before-start: claude never ran" "$(count)" "absent"

echo "AC6.8 stop-file-mid-run"
new_case
default_fixture tick-busy
printf '%s\n' "$REPO/.fleet-board.stop" > "$FC/2.touch"
run_wrapper --repo "$REPO"
assert_exit "stop-file-mid-run: exit 0" 0
assert_stdout_contains "stop-file-mid-run: stop line" "stopped: stop-file after 2 ticks"
assert_eq "stop-file-mid-run: count == 2" "$(count)" "2"

# ---------------------------------------------------------------------------
echo "AC6.9 log-default-under-home"
new_case
seq_fixture 1 tick-idle
C_LOG_DIR=""
run_wrapper --repo "$REPO"
assert_exit "log-default: exit 0" 0
LOG="$(the_log "$HOMEDIR/.fleet-board/runs")"
assert_true "log-default: one log under \$HOME/.fleet-board/runs/" test -n "$LOG"
assert_file_contains "log-default: it holds the run" "$LOG" "stopped: nothing-dispatchable after 1 ticks"
assert_false "log-default: nothing in the unused log dir" test -e "$LOGS"

# ---------------------------------------------------------------------------
echo "AC6.10 continues-after-failure"
new_case "max_consecutive_failures: 3"
seq_fixture 1 tick-error
printf '1\n' > "$FC/1.exit"
seq_fixture 2 tick-busy
seq_fixture 3 tick-idle
run_wrapper --repo "$REPO"
assert_exit "continues-after-failure: exit 0" 0
assert_stdout_contains "continues-after-failure: stop line" "stopped: nothing-dispatchable after 3 ticks"
LOG="$(the_log "$LOGS")"
assert_file_contains "continues-after-failure: log has the failed tick" "$LOG" "=== tick 1 FAILED"
assert_file_matches "continues-after-failure: failed header" "$LOG" "^=== tick 1 FAILED $ISO rc=1 ===$"
assert_file_contains "continues-after-failure: log has the raw output tail" "$LOG" "error_max_turns"
assert_eq "continues-after-failure: count == 3" "$(count)" "3"

echo "AC6.10 stops-after-consecutive-failures"
new_case "max_consecutive_failures: 2"
default_fixture tick-error
run_wrapper --repo "$REPO"
assert_exit "consecutive-failures: exit 1" 1
assert_stdout_contains "consecutive-failures: stop line" "stopped: consecutive-failures after 2 ticks"
assert_eq "consecutive-failures: count == 2" "$(count)" "2"

echo "AC6.10 failure-counter-resets"
new_case "max_consecutive_failures: 2"
seq_fixture 1 tick-error
seq_fixture 2 tick-busy
seq_fixture 3 tick-error
seq_fixture 4 tick-busy
seq_fixture 5 tick-idle
run_wrapper --repo "$REPO"
assert_exit "failure-counter-resets: exit 0" 0
assert_stdout_contains "failure-counter-resets: stop line" "stopped: nothing-dispatchable after 5 ticks"

echo "AC6.10 missing-signal-is-failure"
new_case "max_consecutive_failures: 1"
default_fixture tick-no-signal
run_wrapper --repo "$REPO"
assert_exit "missing-signal: exit 1" 1
assert_stdout_contains "missing-signal: stop line" "stopped: consecutive-failures after 1 ticks"

echo "signal-not-last-is-failure"
new_case "max_consecutive_failures: 1"
result_fixture "$FC/1.jsonl" '{subtype:"success",is_error:false,total_cost_usd:0.1,result:"r\ndispatchable: false\nmore text"}'
run_wrapper --repo "$REPO"
assert_exit "signal-not-last: exit 1" 1
assert_stdout_contains "signal-not-last: a failure" "stopped: consecutive-failures after 1 ticks"

echo "bad-signal-value-is-failure"
new_case "max_consecutive_failures: 1"
result_fixture "$FC/1.jsonl" '{subtype:"success",is_error:false,total_cost_usd:0.1,result:"r\ndispatchable: maybe"}'
run_wrapper --repo "$REPO"
assert_exit "bad-signal-value: exit 1" 1
assert_stdout_contains "bad-signal-value: a failure" "stopped: consecutive-failures after 1 ticks"

echo "is-error-is-failure (even with a signal)"
new_case "max_consecutive_failures: 1"
result_fixture "$FC/1.jsonl" '{subtype:"error_during_execution",is_error:true,total_cost_usd:0.1,result:"r\ndispatchable: false"}'
run_wrapper --repo "$REPO"
assert_exit "is-error: exit 1" 1
assert_stdout_contains "is-error: a failure" "stopped: consecutive-failures after 1 ticks"

echo "nonzero-exit-is-failure (even with a good result)"
new_case "max_consecutive_failures: 3"
seq_fixture 1 tick-idle
printf '2\n' > "$FC/1.exit"
seq_fixture 2 tick-idle
run_wrapper --repo "$REPO"
assert_exit "nonzero-exit: exit 0" 0
LOG="$(the_log "$LOGS")"
assert_stdout_contains "nonzero-exit: tick 1 failed, tick 2 stopped" "stopped: nothing-dispatchable after 2 ticks"
assert_file_matches "nonzero-exit: failed header" "$LOG" "^=== tick 1 FAILED $ISO rc=2 ===$"

echo "empty-output-is-failure"
new_case "max_consecutive_failures: 1"
run_wrapper --repo "$REPO"
assert_exit "empty-output: exit 1" 1
assert_stdout_contains "empty-output: a failure" "stopped: consecutive-failures after 1 ticks"
assert_eq "empty-output: count == 1" "$(count)" "1"

# ---------------------------------------------------------------------------
echo "invocation-args"
new_case
seq_fixture 1 tick-idle
C_CWD="$T"
run_wrapper --repo "$REPO/sub"
assert_exit "invocation-args: exit 0" 0
A1="$(args_line 1)"
for want in "-p /fleet-board:tick" "--model sonnet" "--permission-mode auto" "--output-format stream-json" "--verbose" "--max-turns 200"; do
  case "$A1" in
    *"$want"*) pass "invocation-args: contains '$want'" ;;
    *) fail "invocation-args: contains '$want'" "args line 1: '$A1'" ;;
  esac
done
case "$A1" in
  *dangerously*) fail "invocation-args: no dangerously" "args line 1: '$A1'" ;;
  *) pass "invocation-args: no dangerously" ;;
esac
assert_eq "invocation-args: exact line" "$A1" "-p /fleet-board:tick --model sonnet --permission-mode auto --output-format stream-json --verbose --max-turns 200"
assert_eq "invocation-args: claude runs in the repo root (from --repo <root>/sub)" "$(sed -n 1p "$FC/cwd.log" 2>/dev/null)" "$REPO"

echo "tick-prompt-override"
new_case "" "models: { manager: opus }
headless: { permission_mode: acceptEdits }"
seq_fixture 1 tick-idle
C_PROMPT="run one fleet tick"
run_wrapper --repo "$REPO"
assert_eq "tick-prompt-override: prompt, model and mode from env and config" "$(args_line 1)" \
  "-p run\\ one\\ fleet\\ tick --model opus --permission-mode acceptEdits --output-format stream-json --verbose --max-turns 200"

echo "plugin-dir-passthrough"
new_case "max_turns: 7"
seq_fixture 1 tick-idle
C_PLUGIN_DIR="/x"
run_wrapper --repo "$REPO"
assert_exit "plugin-dir: exit 0" 0
case "$(args_line 1)" in
  *"--plugin-dir /x"*) pass "plugin-dir: args contain --plugin-dir /x" ;;
  *) fail "plugin-dir: args contain --plugin-dir /x" "args line 1: '$(args_line 1)'" ;;
esac
assert_eq "plugin-dir: exact line" "$(args_line 1)" \
  "-p /fleet-board:tick --plugin-dir /x --model sonnet --permission-mode auto --output-format stream-json --verbose --max-turns 7"

echo "isolation-applied: not run (ROLE_ISOLATION: none; see rehearsal-notes.md)"
echo "isolate-without-mechanism (fail closed)"
new_case
seq_fixture 1 tick-idle
C_ISOLATE=1
run_wrapper --repo "$REPO"
assert_exit "isolate=1 without a mechanism: exit 2" 2
assert_stderr_contains "isolate=1 without a mechanism: says why" "FLEET_BOARD_ISOLATE"
assert_eq "isolate=1 without a mechanism: claude never ran" "$(count)" "absent"
new_case
seq_fixture 1 tick-idle
C_ISOLATE=0
run_wrapper --repo "$REPO"
assert_exit "isolate=0: runs normally" 0
assert_eq "isolate=0: count == 1" "$(count)" "1"

echo "bypass-warning"
new_case "" "headless: { permission_mode: bypassPermissions }"
seq_fixture 1 tick-idle
run_wrapper --repo "$REPO"
assert_exit "bypass-warning: exit 0" 0
assert_stderr_contains "bypass-warning: stderr warning" "warning"
assert_stderr_contains "bypass-warning: names the mode" "bypassPermissions"
LOG="$(the_log "$LOGS")"
W="$(line_of "$LOG" "warning")"
T1="$(line_of "$LOG" "=== tick 1 ")"
assert_true "bypass-warning: the warning is logged before the first tick" test "$W" -gt 0 -a "$T1" -gt "$W"
case "$(args_line 1)" in
  *"--permission-mode bypassPermissions"*) pass "bypass-warning: the mode is passed as configured" ;;
  *) fail "bypass-warning: the mode is passed as configured" "args line 1: '$(args_line 1)'" ;;
esac
assert_file_not_contains "bypass-warning: still no dangerously flag" "$FC/args.log" "dangerously"

echo "no bypass warning by default"
new_case
seq_fixture 1 tick-idle
run_wrapper --repo "$REPO"
assert_stderr_not_contains "default mode: no warning" "warning"

echo "haiku-warning"
new_case "" "models: { manager: haiku }"
seq_fixture 1 tick-idle
run_wrapper --repo "$REPO"
assert_exit "haiku-warning: exit 0" 0
assert_stderr_contains "haiku-warning: stderr names haiku" "warning: models.manager is haiku"

echo "no-config"
new_case
rm -f "$REPO/.fleet-board.yml"
seq_fixture 1 tick-idle
run_wrapper --repo "$REPO"
assert_exit "no-config: exit 3" 3
assert_eq "no-config: claude never ran" "$(count)" "absent"

echo "invalid-limit"
new_case "max_hours: soon"
seq_fixture 1 tick-idle
run_wrapper --repo "$REPO"
assert_exit "invalid-limit: exit 5" 5
assert_stderr_contains "invalid-limit: names the key" "limits.max_hours"
assert_eq "invalid-limit: claude never ran" "$(count)" "absent"

echo "usage"
new_case
run_wrapper --bogus
assert_exit "unknown flag: exit 2" 2
run_wrapper --repo
assert_exit "--repo without a value: exit 2" 2
assert_eq "usage: claude never ran" "$(count)" "absent"

# ---------------------------------------------------------------------------
echo "cleanup-after-tick"
new_case "max_consecutive_failures: 3"
seq_fixture 1 tick-busy
seq_fixture 2 tick-error
seq_fixture 3 tick-idle
run_wrapper --repo "$REPO/sub"
assert_exit "cleanup-after-tick: exit 0" 0
assert_eq "cleanup-after-tick: one cleanup per successful tick" "$(lines "$T/cleanup-count")" "2"
assert_eq "cleanup-after-tick: runs from the repo root" "$(sed -n 1p "$T/cleanup-cwd" 2>/dev/null)" "$REPO"
LOG="$(the_log "$LOGS")"
assert_file_contains "cleanup-after-tick: its stdout is logged" "$LOG" "fake cleanup ran"
assert_file_not_contains "cleanup-after-tick: no warning when it succeeds" "$LOG" "warning: cleanup-done.sh exited"

new_case
seq_fixture 1 tick-busy
seq_fixture 2 tick-idle
C_CLEANUP_EXIT=1
run_wrapper --repo "$REPO"
assert_exit "cleanup fails: still exit 0" 0
assert_stdout_contains "cleanup fails: still stops nothing-dispatchable" "stopped: nothing-dispatchable after 2 ticks"
LOG="$(the_log "$LOGS")"
assert_file_contains "cleanup fails: warning in the log" "$LOG" "warning: cleanup-done.sh exited 1"
assert_file_contains "cleanup fails: its stderr in the log" "$LOG" "fake cleanup stderr"
assert_eq "cleanup fails: it ran after each successful tick" "$(lines "$T/cleanup-count")" "2"

echo "cleanup-default-script (FLEET_BOARD_CLEANUP unset runs the shipped cleanup-done.sh)"
new_case
seq_fixture 1 tick-idle
C_CLEANUP=""
run_wrapper --repo "$REPO"
assert_exit "cleanup-default: exit 0" 0
LOG="$(the_log "$LOGS")"
assert_file_contains "cleanup-default: the shipped script listed the done column" "$T/gh-calls.log" "issue list --repo acme/toy --label fleet:done"
assert_file_contains "cleanup-default: its failure (stub gh) is a logged warning" "$LOG" "warning: cleanup-done.sh exited 1"
assert_eq "cleanup-default: the fake cleanup did not run" "$(lines "$T/cleanup-count")" "0"

# ---------------------------------------------------------------------------
# Review cycle 1

INTERRUPTED='^fleet-board-run: stopped: interrupted \(TERM\) after [0-9]+ ticks, [0-9]+\.[0-9]{2} h, cost_estimate_usd [0-9.]+ \(estimate\)$'

echo "interrupted-during-tick (TERM while claude runs)"
new_case
default_fixture tick-busy
printf '10\n' > "$FC/1.sleep"
run_wrapper_term "$FC/count" --repo "$REPO"
assert_exit "interrupted-during-tick: exit 143" 143
assert_true "interrupted-during-tick: exits within 3 s of TERM (claude sleeps 10 s)" test "$TERM_SECS" -le 3
LOG="$(the_log "$LOGS")"
assert_eq "interrupted-during-tick: the last log line is the interrupted stop line" \
  "$(tail -1 "$LOG" 2>/dev/null)" "fleet-board-run: stopped: interrupted (TERM) after 1 ticks, 0.00 h, cost_estimate_usd 0 (estimate)"
assert_stdout_contains "interrupted-during-tick: stop line printed" "fleet-board-run: stopped: interrupted (TERM) after 1 ticks"
assert_eq "interrupted-during-tick: count == 1" "$(count)" "1"
CPID="$(sed -n 1p "$FC/pids.log" 2>/dev/null)"
i=0
while [ -n "$CPID" ] && kill -0 "$CPID" 2>/dev/null && [ "$i" -lt 20 ]; do sleep 0.1; i=$((i + 1)); done
assert_false "interrupted-during-tick: claude got TERM too (gone within 2 s)" kill -0 "${CPID:-0}"

echo "interrupted-between-ticks (TERM during tick_interval)"
new_case "tick_interval: 10"
sed -i.bak 's/tick_interval: 0, //' "$REPO/.fleet-board.yml" && rm -f "$REPO/.fleet-board.yml.bak"
default_fixture tick-busy
run_wrapper_term "$T/cleanup-count" --repo "$REPO"
assert_exit "interrupted-between-ticks: exit 143" 143
assert_true "interrupted-between-ticks: exits within 3 s of TERM (interval 10 s)" test "$TERM_SECS" -le 3
LOG="$(the_log "$LOGS")"
assert_eq "interrupted-between-ticks: the last log line is the interrupted stop line" \
  "$(tail -1 "$LOG" 2>/dev/null)" "fleet-board-run: stopped: interrupted (TERM) after 1 ticks, 0.00 h, cost_estimate_usd 0.6 (estimate)"
assert_stdout_contains "interrupted-between-ticks: stop line printed" "fleet-board-run: stopped: interrupted (TERM) after 1 ticks"
assert_true "interrupted-between-ticks: the stop line has the documented form" \
  sh -c 'tail -1 "$1" | grep -qE "$2"' _ "$LOG" "$INTERRUPTED"
assert_eq "interrupted-between-ticks: count == 1" "$(count)" "1"

echo "log-dir-relative (resolved against the caller's directory, not the repo root)"
new_case
seq_fixture 1 tick-idle
C_CWD="$T"
C_LOG_DIR="rel-logs"
run_wrapper --repo "$REPO"
assert_exit "log-dir-relative: exit 0" 0
LOG="$(the_log "$T/rel-logs")"
assert_true "log-dir-relative: the log is under <caller cwd>/rel-logs" test -n "$LOG"
assert_false "log-dir-relative: nothing under <repo root>/rel-logs" test -e "$REPO/rel-logs"
assert_stdout_contains "log-dir-relative: the printed path is absolute" "fleet-board-run: log: $T/rel-logs/acme-toy-"

echo "tiny-cost (0.00005 and 5e-05 are costs, not cost-unknown)"
new_case
result_fixture "$FC/1.jsonl" '{subtype:"success",is_error:false,total_cost_usd:0.00005,result:"r\ndispatchable: true"}'
{ head -2 "$FX/tick-busy.jsonl"; printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":5e-05,"result":"r\ndispatchable: false"}'; } > "$FC/2.jsonl"
run_wrapper --repo "$REPO"
assert_exit "tiny-cost: exit 0" 0
assert_stdout_contains "tiny-cost: summary in fixed point" "fleet-board-run: stopped: nothing-dispatchable after 2 ticks, 0.00 h, cost_estimate_usd 0.0001 (estimate)"
LOG="$(the_log "$LOGS")"
assert_file_matches "tiny-cost: tick 1 header" "$LOG" "^=== tick 1 $ISO rc=0 cost_estimate_usd=0\.00005 \(estimate\) ===$"
assert_file_matches "tiny-cost: tick 2 header" "$LOG" "^=== tick 2 $ISO rc=0 cost_estimate_usd=0\.00005 \(estimate\) ===$"

echo "log-modes (dir 700, files 600; the ticks' umask untouched)"
new_case "max_consecutive_failures: 3"
seq_fixture 1 tick-error
seq_fixture 2 tick-idle
C_LOG_DIR="$T/logs/nested"
printf '#!/bin/sh\numask > "%s/cleanup-umask"\n' "$T" > "$T/umask-cleanup.sh"
chmod +x "$T/umask-cleanup.sh"
C_CLEANUP="$T/umask-cleanup.sh"
run_wrapper --repo "$REPO"
assert_exit "log-modes: exit 0" 0
LOG="$(the_log "$T/logs/nested")"
assert_eq "log-modes: the log dir is 700" "$(mode_of "$T/logs/nested")" "drwx------"
assert_eq "log-modes: a parent it created is 700" "$(mode_of "$T/logs")" "drwx------"
assert_eq "log-modes: the run log is 600" "$(mode_of "$LOG")" "-rw-------"
assert_eq "log-modes: the saved failed-tick stream is 600" "$(mode_of "${LOG%.log}-tick-1.jsonl")" "-rw-------"
assert_eq "log-modes: cleanup runs with the caller's umask" "$(cat "$T/cleanup-umask" 2>/dev/null)" "0022"

echo "failed-tick-full-output (saved stream, capped tail lines)"
new_case "max_consecutive_failures: 3"
LONG="$(awk 'BEGIN { while (n++ < 5000) printf "x" }')"
{ head -1 "$FX/tick-error.jsonl"; jq -cn --arg t "$LONG" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}'; tail -n +2 "$FX/tick-error.jsonl"; } > "$FC/1.jsonl"
seq_fixture 2 tick-idle
run_wrapper --repo "$REPO"
assert_exit "failed-tick-full-output: exit 0" 0
LOG="$(the_log "$LOGS")"
JL="${LOG%.log}-tick-1.jsonl"
assert_true "failed-tick-full-output: the stream is saved next to the log" test -f "$JL"
assert_true "failed-tick-full-output: it is the tick's whole stream" cmp -s "$JL" "$FC/1.jsonl"
assert_file_contains "failed-tick-full-output: the FAILED block names it" "$LOG" "full output: $JL"
assert_eq "failed-tick-full-output: nothing saved for the successful tick" "$(jsonl_count "$LOGS")" "1"
assert_true "failed-tick-full-output: no log line over 2100 characters" \
  awk 'length($0) > 2100 { bad = 1 } END { exit bad }' "$LOG"
assert_file_contains "failed-tick-full-output: a capped line says so" "$LOG" "[line truncated]"

echo "is-error-missing-is-failure (is_error must be exactly false)"
new_case "max_consecutive_failures: 1"
result_fixture "$FC/1.jsonl" '{subtype:"success",total_cost_usd:0.1,result:"r\ndispatchable: false"}'
run_wrapper --repo "$REPO"
assert_exit "is-error-missing: exit 1" 1
assert_stdout_contains "is-error-missing: a failure" "stopped: consecutive-failures after 1 ticks"

echo "signal-with-suffix-is-failure (the line must be exactly the signal)"
for bad in "dispatchable: true." "dispatchable: truex" "dispatchable: false."; do
  new_case "max_consecutive_failures: 1"
  result_fixture "$FC/1.jsonl" "{subtype:\"success\",is_error:false,total_cost_usd:0.1,result:\"r\\n$bad\"}"
  run_wrapper --repo "$REPO"
  assert_exit "signal-with-suffix '$bad': exit 1" 1
  assert_stdout_contains "signal-with-suffix '$bad': a failure" "stopped: consecutive-failures after 1 ticks"
done

echo "signal-trailing-whitespace-and-crlf (accepted)"
new_case "max_consecutive_failures: 1"
result_fixture "$FC/1.jsonl" '{subtype:"success",is_error:false,total_cost_usd:0.1,result:"r\ndispatchable: false  \t"}'
run_wrapper --repo "$REPO"
assert_exit "trailing-whitespace: exit 0" 0
assert_stdout_contains "trailing-whitespace: accepted" "stopped: nothing-dispatchable after 1 ticks"
new_case "max_consecutive_failures: 1"
result_fixture "$FC/1.jsonl" '{subtype:"success",is_error:false,total_cost_usd:0.1,result:"r\r\ndispatchable: false\r\n"}'
run_wrapper --repo "$REPO"
assert_exit "crlf: exit 0" 0
assert_stdout_contains "crlf: accepted" "stopped: nothing-dispatchable after 1 ticks"

echo "plan-failed-is-failure (a report saying Plan failed: is a failed tick, not a settled board)"
PLAN_FAILED='{subtype:"success",is_error:false,total_cost_usd:0.01,result:"## fleet-board tick\n\nPlan failed: GraphQL: API rate limit exceeded  \r\n\nWarnings:\n- GraphQL: API rate limit exceeded\n\nReports rejected: 0\ncost_estimate_usd: 0.0000 (estimate)\ndispatchable: false"}'
new_case "max_consecutive_failures: 2"
result_fixture "$FC/default.jsonl" "$PLAN_FAILED"
run_wrapper --repo "$REPO"
assert_exit "plan-failed: exit 1" 1
assert_stdout_contains "plan-failed: stops consecutive-failures" "stopped: consecutive-failures after 2 ticks"
case "$LAST_OUT" in
  *nothing-dispatchable*) fail "plan-failed: not nothing-dispatchable" "got: $LAST_OUT" ;;
  *) pass "plan-failed: not nothing-dispatchable" ;;
esac
assert_eq "plan-failed: count == 2" "$(count)" "2"
LOG="$(the_log "$LOGS")"
assert_file_matches "plan-failed: tick 1 FAILED header" "$LOG" "^=== tick 1 FAILED $ISO rc=0 ===$"
assert_file_matches "plan-failed: tick 2 FAILED header" "$LOG" "^=== tick 2 FAILED $ISO rc=0 ===$"
assert_file_matches "plan-failed: reason line (whitespace trimmed)" "$LOG" "^reason: plan failed: GraphQL: API rate limit exceeded$"
assert_file_contains "plan-failed: cost logged" "$LOG" "cost_estimate_usd=0.01 (estimate)"
assert_stdout_contains "plan-failed: cost counted" "cost_estimate_usd 0.02 (estimate)"
assert_eq "plan-failed: full output saved per tick" "$(jsonl_count "$LOGS")" "2"
assert_false "plan-failed: cleanup-done never ran" test -e "$T/cleanup-count"

echo "plan-failed-then-idle (the failure count resets; the idle tick stops the run)"
new_case "max_consecutive_failures: 2"
result_fixture "$FC/1.jsonl" "$PLAN_FAILED"
seq_fixture 2 tick-idle
run_wrapper --repo "$REPO"
assert_exit "plan-failed-then-idle: exit 0" 0
assert_stdout_contains "plan-failed-then-idle: stop line" "stopped: nothing-dispatchable after 2 ticks"
LOG="$(the_log "$LOGS")"
assert_file_matches "plan-failed-then-idle: tick 1 FAILED" "$LOG" "^=== tick 1 FAILED $ISO rc=0 ===$"
assert_file_matches "plan-failed-then-idle: tick 2 is a normal tick" "$LOG" "^=== tick 2 $ISO rc=0 cost_estimate_usd=0\.1 \(estimate\) ===$"
assert_eq "plan-failed-then-idle: cleanup ran once, for tick 2" "$(lines "$T/cleanup-count")" "1"
new_case "max_consecutive_failures: 2"
result_fixture "$FC/1.jsonl" "$PLAN_FAILED"
seq_fixture 2 tick-busy
result_fixture "$FC/3.jsonl" "$PLAN_FAILED"
seq_fixture 4 tick-idle
run_wrapper --repo "$REPO"
assert_exit "plan-failed-resets: exit 0" 0
assert_stdout_contains "plan-failed-resets: a good tick resets the count" "stopped: nothing-dispatchable after 4 ticks"

echo "plan-failed-mid-line (only a line that starts with Plan failed: counts)"
new_case "max_consecutive_failures: 1"
result_fixture "$FC/1.jsonl" '{subtype:"success",is_error:false,total_cost_usd:0.1,result:"## fleet-board tick\n\n| Card | Action | Result |\n|---|---|---|\n| #12 | skip | last tick: Plan failed: rate limit; plan failed again? no |\n\nWarnings: the plan failed yesterday\n\nReports rejected: 0\ndispatchable: false"}'
run_wrapper --repo "$REPO"
assert_exit "plan-failed-mid-line: exit 0" 0
assert_stdout_contains "plan-failed-mid-line: a normal idle tick" "stopped: nothing-dispatchable after 1 ticks"
LOG="$(the_log "$LOGS")"
assert_file_not_contains "plan-failed-mid-line: no FAILED tick" "$LOG" "FAILED"

echo "plan-failed-decorated (leading whitespace and markdown decoration before Plan failed: still count)"
for deco in '**Plan failed:**' '- Plan failed:' '* Plan failed:' '+ Plan failed:' '> Plan failed:' \
    '>Plan failed:' '  Plan failed:' '1. Plan failed:' '- **Plan failed:**' '> - *Plan failed:*' '__Plan failed:__' \
    '1) Plan failed:' '**Plan failed**:' '__Plan failed__:' '`Plan failed`:' '`Plan failed:`' '## Plan failed:' \
    '###### Plan failed:' '- **Plan failed**:' '- ## Plan failed:'; do
  new_case "max_consecutive_failures: 1"
  result_fixture "$FC/1.jsonl" "{subtype:\"success\",is_error:false,total_cost_usd:0.01,result:\"## fleet-board tick\\n\\n$deco GraphQL: API rate limit exceeded\\n\\nReports rejected: 0\\ndispatchable: false\"}"
  run_wrapper --repo "$REPO"
  assert_exit "plan-failed-decorated '$deco': exit 1" 1
  assert_stdout_contains "plan-failed-decorated '$deco': a failed tick" "stopped: consecutive-failures after 1 ticks"
  LOG="$(the_log "$LOGS")"
  assert_file_matches "plan-failed-decorated '$deco': reason line" "$LOG" "^reason: plan failed: GraphQL: API rate limit exceeded$"
done

echo "plan-failed-wrapped (a line wrapped in emphasis or backticks logs the reason without the closing markers)"
for pair in '`Plan failed: GraphQL error`|GraphQL error' '**Plan failed: rate limit**|rate limit'; do
  line="${pair%%|*}"
  want="${pair#*|}"
  new_case "max_consecutive_failures: 1"
  result_fixture "$FC/1.jsonl" "{subtype:\"success\",is_error:false,total_cost_usd:0.01,result:\"## fleet-board tick\\n\\n$line\\n\\nReports rejected: 0\\ndispatchable: false\"}"
  run_wrapper --repo "$REPO"
  assert_exit "plan-failed-wrapped '$line': exit 1" 1
  assert_stdout_contains "plan-failed-wrapped '$line': a failed tick" "stopped: consecutive-failures after 1 ticks"
  LOG="$(the_log "$LOGS")"
  assert_file_matches "plan-failed-wrapped '$line': clean reason line" "$LOG" "^reason: plan failed: $want\$"
done

echo "plan-failed-after-text (text before Plan failed: that is not decoration does not count)"
for pre in 'Note: Plan failed:' 'see **Plan failed:**' '| #12 | Plan failed:' '-Plan failed:' 'x - Plan failed:' \
    '| Plan failed: x |' 'Note: **Plan failed**:' '#Plan failed:' '####### Plan failed:' '## Note: Plan failed:' \
    '## - Plan failed:' '## > Plan failed:'; do
  new_case "max_consecutive_failures: 1"
  result_fixture "$FC/1.jsonl" "{subtype:\"success\",is_error:false,total_cost_usd:0.1,result:\"## fleet-board tick\\n\\n$pre rate limit\\n\\nReports rejected: 0\\ndispatchable: false\"}"
  run_wrapper --repo "$REPO"
  assert_exit "plan-failed-after-text '$pre': exit 0" 0
  assert_stdout_contains "plan-failed-after-text '$pre': a normal idle tick" "stopped: nothing-dispatchable after 1 ticks"
done

echo "long-whitespace-line (a long run of spaces not at line end is processed in linear time)"
new_case "max_consecutive_failures: 1"
result_fixture "$FC/1.jsonl" '{subtype:"success",is_error:false,total_cost_usd:0.1,result:("## fleet-board tick\n\n" + (" " * 100000) + "x\n\ndispatchable: false")}'
LW_T0="$(date +%s)"
run_wrapper --repo "$REPO"
LW_T1="$(date +%s)"
LW_SECS=$((LW_T1 - LW_T0))
echo "       (long-whitespace-line run: ${LW_SECS} s)"
assert_exit "long-whitespace-line: exit 0" 0
assert_stdout_contains "long-whitespace-line: a normal idle tick" "stopped: nothing-dispatchable after 1 ticks"
assert_true "long-whitespace-line: the run takes under 20 s (took ${LW_SECS} s)" test "$LW_SECS" -lt 20

# ---------------------------------------------------------------------------
# Review cycle 2

# A comma-decimal locale (LC_NUMERIC), when this machine has one
DE_LOCALE="$(locale -a 2>/dev/null | grep -iE '^de_DE\.utf-?8$' | head -1)"
if [ -z "$DE_LOCALE" ]; then
  echo "locale-de-* cases: SKIPPED (locale -a lists no de_DE UTF-8 locale)"
else
  case "$(LC_ALL="$DE_LOCALE" awk 'BEGIN { printf "%.1f", 0.5 }')" in
    0,5) ;;
    *) echo "       (note: awk ignores LC_NUMERIC here, so the locale-de-* cases cannot fail on this machine)" ;;
  esac

  echo "locale-de-costs (LC_ALL=$DE_LOCALE: dot decimals, not cost-unknown)"
  new_case
  seq_fixture 1 tick-busy
  seq_fixture 2 tick-idle
  C_LOCALE="$DE_LOCALE"
  run_wrapper --repo "$REPO"
  assert_exit "locale-de-costs: exit 0" 0
  assert_stdout_contains "locale-de-costs: summary with dot decimals" \
    "fleet-board-run: stopped: nothing-dispatchable after 2 ticks, 0.00 h, cost_estimate_usd 0.7 (estimate)"
  LOG="$(the_log "$LOGS")"
  assert_file_matches "locale-de-costs: tick 1 header" "$LOG" "^=== tick 1 $ISO rc=0 cost_estimate_usd=0\.6 \(estimate\) ===$"
  assert_eq "locale-de-costs: claude keeps the caller's locale" "$(sort -u "$FC/locale.log" 2>/dev/null)" "$DE_LOCALE"

  echo "locale-de-model-usage (LC_ALL=$DE_LOCALE: the estimate-cost.sh fallback)"
  new_case "max_cost_usd: 0.6"
  default_fixture tick-no-cost
  C_LOCALE="$DE_LOCALE"
  run_wrapper --repo "$REPO"
  assert_exit "locale-de-model-usage: exit 0" 0
  assert_stdout_contains "locale-de-model-usage: stops max-cost after 3 ticks, 0.75" \
    "stopped: max-cost after 3 ticks, 0.00 h, cost_estimate_usd 0.75 (estimate)"

  echo "locale-de-max-hours (LC_ALL=$DE_LOCALE: elapsed hours compared as numbers)"
  new_case "max_hours: 0.0002"
  default_fixture tick-busy
  printf '1\n' > "$FC/1.sleep"
  C_LOCALE="$DE_LOCALE"
  run_wrapper --repo "$REPO"
  assert_exit "locale-de-max-hours: exit 0" 0
  assert_stdout_contains "locale-de-max-hours: stop line" "stopped: max-hours after 1 ticks"
  assert_eq "locale-de-max-hours: count == 1" "$(count)" "1"

  echo "locale-de-interrupted (LC_ALL=$DE_LOCALE: the interrupted stop line)"
  new_case "tick_interval: 10"
  sed -i.bak 's/tick_interval: 0, //' "$REPO/.fleet-board.yml" && rm -f "$REPO/.fleet-board.yml.bak"
  default_fixture tick-busy
  C_LOCALE="$DE_LOCALE"
  run_wrapper_term "$T/cleanup-count" --repo "$REPO"
  assert_exit "locale-de-interrupted: exit 143" 143
  LOG="$(the_log "$LOGS")"
  assert_eq "locale-de-interrupted: the stop line has dot decimals" \
    "$(tail -1 "$LOG" 2>/dev/null)" "fleet-board-run: stopped: interrupted (TERM) after 1 ticks, 0.00 h, cost_estimate_usd 0.6 (estimate)"
fi

echo "interrupted-child-ignores-term (TERM, a grace period, then KILL)"
new_case
default_fixture tick-busy
: > "$FC/1.ignore-term"
printf '20\n' > "$FC/1.sleep"
run_wrapper_term "$FC/count" --repo "$REPO"
assert_exit "child-ignores-term: exit 143" 143
assert_true "child-ignores-term: exits within 8 s of TERM (5 s grace; claude ignores TERM, sleeps 20 s)" test "$TERM_SECS" -le 8
assert_true "child-ignores-term: gives the child a grace period first (>= 4 s)" test "$TERM_SECS" -ge 4
CPID="$(sed -n 1p "$FC/pids.log" 2>/dev/null)"
i=0
while [ -n "$CPID" ] && kill -0 "$CPID" 2>/dev/null && [ "$i" -lt 10 ]; do sleep 0.1; i=$((i + 1)); done
assert_false "child-ignores-term: claude is gone (killed)" kill -0 "${CPID:-0}"
LOG="$(the_log "$LOGS")"
assert_eq "child-ignores-term: the last log line is the interrupted stop line" \
  "$(tail -1 "$LOG" 2>/dev/null)" "fleet-board-run: stopped: interrupted (TERM) after 1 ticks, 0.00 h, cost_estimate_usd 0 (estimate)"

echo "interrupted-kills-every-job (FLEET_BOARD_TEST_BGJOB: a job CHILD does not name)"
new_case
default_fixture tick-busy
printf '10\n' > "$FC/1.sleep"
C_TEST_BGJOB="$T/bgjob.pid"
run_wrapper_term "$FC/count" --repo "$REPO"
assert_exit "kills-every-job: exit 143" 143
assert_true "kills-every-job: exits within 3 s (the extra job got TERM, not only the grace-period KILL)" test "$TERM_SECS" -le 3
BGPID="$(cat "$T/bgjob.pid" 2>/dev/null)"
assert_true "kills-every-job: the test hook started its job" test -n "$BGPID"
i=0
while [ -n "$BGPID" ] && kill -0 "$BGPID" 2>/dev/null && [ "$i" -lt 20 ]; do sleep 0.1; i=$((i + 1)); done
assert_false "kills-every-job: the extra job is gone within 2 s" kill -0 "${BGPID:-0}"
[ -n "$BGPID" ] && kill -KILL "$BGPID" 2>/dev/null

echo "children-without-fd3 (the wrapper's saved stdout is not inherited)"
new_case
seq_fixture 1 tick-busy
seq_fixture 2 tick-idle
run_wrapper --repo "$REPO"
assert_exit "children-without-fd3: exit 0" 0
assert_eq "children-without-fd3: claude never had fd 3 open" "$(sort -u "$FC/fd3.log" 2>/dev/null)" "closed"

echo ""
echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
