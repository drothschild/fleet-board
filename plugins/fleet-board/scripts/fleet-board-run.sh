#!/usr/bin/env bash
# fleet-board-run.sh - runs fleet-board ticks headless until a stop condition.
#
# Usage: fleet-board-run.sh [--repo DIR]
#
# Loops `claude -p "<tick prompt>"` (stream-json output), one tick at a time,
# from the repo root (DIR, default $PWD, then its git toplevel). From each
# tick it reads the LAST stream-json `result` event (a session can emit
# several; total_cost_usd is cumulative, so the last one is the tick's), and:
#   - a tick fails when claude exits non-zero, there is no result event,
#     is_error is not false, or the result text's last non-blank line is not
#     exactly `dispatchable: true` or `dispatchable: false`, or the result
#     text has a line starting `Plan failed:`, optionally after, in this
#     order, whitespace; list markers (`- `, `* `, `+ `, `1. `, `1) `) and
#     quote `>`; then one heading `#`..`######` plus a space (so `## - ` does
#     not count), and with up to three `*`, `_` or backtick characters around
#     the label (`**Plan failed**:`, `` `Plan failed:` ``); any other text
#     before it does not count. That line means tick-plan.sh failed (e.g. a
#     GitHub rate limit; the report still ends `dispatchable: false`); it is
#     logged as `reason: plan failed: <rest of that line, cut to 200
#     characters>`, without up to three closing `*`, `_` or backticks
#   - the tick's cost is total_cost_usd, or, when that is absent, modelUsage
#     priced by estimate-cost.sh --model-usage; either way an estimate. A
#     failed tick's cost counts when its result carries one.
#   - after each successful tick, cleanup-done.sh runs from the repo root,
#     outside any Claude session; its failure is logged as a warning only
#
# Stops (checked before each tick, and after it where noted):
#   stop-file             <root>/.fleet-board.stop exists              exit 0
#   max-hours             elapsed hours > limits.max_hours             exit 0
#   max-cost              cost estimate > limits.max_cost_usd (also after) exit 0
#   nothing-dispatchable  a successful tick says dispatchable: false   exit 0
#                         (never a tick whose report says `Plan failed:`: that
#                         tick failed, so it counts toward consecutive-failures)
#   consecutive-failures  limits.max_consecutive_failures failed ticks in a row  exit 1
#   cost-unknown          a successful tick gives no cost at all       exit 1
#   interrupted (<sig>)   INT or TERM: the running claude, cleanup or sleep
#                         (every background job) gets TERM, then KILL if it is
#                         still running 5 s later; the run stops   exit 130 / 143
# On stop it prints, and appends to the log:
#   fleet-board-run: stopped: <reason> after <n> ticks, <h.hh> h, cost_estimate_usd <x> (estimate)
# (<n> counts the tick an interrupt cut short.) The limits are checked between
# ticks only: one tick can overrun max-hours or max-cost; --max-turns bounds it.
#
# Every tick is appended to one run log per run:
#   $FLEET_BOARD_LOG_DIR/<owner>-<name>-<YYYYmmdd-HHMMSS>.log
# whose path is printed on start. A failed tick's whole stream-json output is
# kept next to it, as <log name without .log>-tick-<n>.jsonl. A relative
# FLEET_BOARD_LOG_DIR is taken from the caller's directory. A log directory the
# wrapper creates is mode 700, and the files it writes there 600.
#
# Environment:
#   FLEET_BOARD_CLAUDE       the claude binary (default: claude)
#   FLEET_BOARD_PLUGIN_DIR   when set, passed as --plugin-dir
#   FLEET_BOARD_TICK_PROMPT  the tick prompt (default: /fleet-board:tick)
#   FLEET_BOARD_LOG_DIR      the log directory (default: $HOME/.fleet-board/runs)
#   FLEET_BOARD_ISOLATE      unset or 0 by default: no role-isolation mechanism
#                            is recorded for this plugin, so 1 is refused (exit 2)
#   FLEET_BOARD_CLEANUP      the cleanup script (default: cleanup-done.sh here)
#   FLEET_BOARD_TEST_BGJOB   tests only: a file; when set, the wrapper starts one
#                            extra background `sleep` and writes its pid there
#
# Numbers: every awk that reads or prints a decimal runs under LC_ALL=C
# (cawk), so a comma-decimal locale cannot turn 0.6 into 0,6; claude and
# cleanup keep the caller's locale.
#
# Permissions: --permission-mode comes from headless.permission_mode (default
# auto). The wrapper never passes --dangerously-skip-permissions, and warns
# before the first tick when the mode is bypassPermissions. Claude Code can
# silently start a session in another mode (some models fall back to default),
# and a headless tick cannot answer prompts. So after each tick the wrapper
# compares the permissionMode of the stream's system/init event with the
# requested one, and a difference stops the run (permission-mode-mismatch).
# A tick with no init event is not a mismatch.
#
# Exit codes:
#   0 - stopped: nothing-dispatchable, stop-file, max-hours or max-cost
#   1 - stopped: consecutive-failures, cost-unknown or permission-mode-mismatch;
#       or a setup failure
#   2 - usage error, or FLEET_BOARD_ISOLATE=1
#   3, 4, 5 - config.sh --check failed (3: no .fleet-board.yml); 5 also for
#       a limit that is not a valid number
#   130, 143 - interrupted by INT, TERM

set -uo pipefail
unset CDPATH # a relative cd must not follow CDPATH (it would also echo the path)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USAGE="usage: fleet-board-run.sh [--repo DIR]"
die() { printf 'fleet-board-run: %s\n' "$2" >&2; exit "$1"; }

DIR="$PWD"
CALLER_PWD="$PWD"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      [ $# -ge 2 ] || die 2 "$USAGE"
      DIR="$2"
      shift 2
      ;;
    *) die 2 "$USAGE" ;;
  esac
done

case "${FLEET_BOARD_ISOLATE:-}" in
  ""|0) ;;
  1) die 2 "FLEET_BOARD_ISOLATE=1, but fleet-board records no role-isolation mechanism (ROLE_ISOLATION: none); unset it or set it to 0" ;;
  *) die 2 "FLEET_BOARD_ISOLATE must be 0 or 1, got: $FLEET_BOARD_ISOLATE" ;;
esac

CLAUDE="${FLEET_BOARD_CLAUDE:-claude}"
PROMPT="${FLEET_BOARD_TICK_PROMPT:-/fleet-board:tick}"
CLEANUP="${FLEET_BOARD_CLEANUP:-$HERE/cleanup-done.sh}"
LOG_DIR="${FLEET_BOARD_LOG_DIR:-$HOME/.fleet-board/runs}"
case "$LOG_DIR" in
  /*) ;;
  *) LOG_DIR="$CALLER_PWD/$LOG_DIR" ;; # before the cd below changes what it means
esac

cd "$DIR" 2>/dev/null || die 2 "cannot cd to $DIR"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$ROOT" ] || die 1 "$DIR is not inside a git repository"
cd "$ROOT" || die 1 "cannot cd to $ROOT"

bash "$HERE/config.sh" --dir "$ROOT" --check </dev/null
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"

# cfg <key>: one config value; fails the run when it cannot be read
cfg() {
  local v
  v="$(bash "$HERE/config.sh" --dir "$ROOT" "$1" </dev/null)" || die 1 "cannot read $1 from the config"
  printf '%s' "$v"
}
num_ok() { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; }
posint_ok() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
word_ok() { [[ "$1" =~ ^[^[:space:]]+$ ]]; }

REPO_SLUG="$(cfg board.repo)" || exit 1
MODEL="$(cfg models.manager)" || exit 1
MODE="$(cfg headless.permission_mode)" || exit 1
MAX_HOURS="$(cfg limits.max_hours)" || exit 1
MAX_COST="$(cfg limits.max_cost_usd)" || exit 1
INTERVAL="$(cfg limits.tick_interval)" || exit 1
MAX_FAILS="$(cfg limits.max_consecutive_failures)" || exit 1
MAX_TURNS="$(cfg limits.max_turns)" || exit 1

num_ok "$MAX_HOURS" || die 5 "invalid config: limits.max_hours must be a non-negative number, got: $MAX_HOURS"
num_ok "$MAX_COST" || die 5 "invalid config: limits.max_cost_usd must be a non-negative number, got: $MAX_COST"
num_ok "$INTERVAL" || die 5 "invalid config: limits.tick_interval must be a non-negative number, got: $INTERVAL"
posint_ok "$MAX_FAILS" || die 5 "invalid config: limits.max_consecutive_failures must be a positive integer, got: $MAX_FAILS"
posint_ok "$MAX_TURNS" || die 5 "invalid config: limits.max_turns must be a positive integer, got: $MAX_TURNS"
word_ok "$MODEL" || die 5 "invalid config: models.manager must be one word, got: $MODEL"
word_ok "$MODE" || die 5 "invalid config: headless.permission_mode must be one word, got: $MODE"

command -v "$CLAUDE" >/dev/null 2>&1 || die 1 "cannot find the claude binary: $CLAUDE"

# Float helpers (awk, so they behave the same on BSD and GNU). Numbers print
# in fixed point with trailing zeros trimmed: %g would print 0.00005 as 5e-05,
# which num_ok rejects. cawk runs awk in the C locale: macOS awk honours
# LC_NUMERIC, so under de_DE it prints 0.6 as 0,6 (and reads "0.6" as 0).
cawk() { LC_ALL=C awk "$@"; }
AWK_FIX='function fix(x,  s) { s = sprintf("%.10f", x); sub(/0+$/, "", s); sub(/\.$/, "", s); return s }'
fgt() { cawk -v a="$1" -v b="$2" 'BEGIN { exit !((a + 0) > (b + 0)) }'; }
fadd() { cawk -v a="$1" -v b="$2" "$AWK_FIX"' BEGIN { printf "%s", fix((a + 0) + (b + 0)) }'; }
fnum() { cawk -v a="$1" "$AWK_FIX"' BEGIN { printf "%s", fix(a + 0) }'; }
# hours <printf format>: the hours since START
hours() { cawk -v s="$(( $(date +%s) - START ))" -v f="$1" 'BEGIN { printf f, s / 3600 }'; }
iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# run_bg <command...>: runs a command in the background and waits for it,
# returning its status. bash runs a trap only after a foreground child exits,
# so an INT or TERM during a long tick would wait for the tick; during `wait`
# it runs at once. CHILD is the pid the trap forwards TERM to. The caller's
# redirections (a tick's output file) are in force while the trap runs, so the
# wrapper's own stdout is kept on fd 3, which children do not get.
CHILD=""
exec 3>&1
run_bg() {
  local rc
  "$@" 3>&- &
  CHILD=$!
  wait "$CHILD"
  rc=$?
  CHILD=""
  return "$rc"
}

# on_signal <name> <exit code>: TERM the running child and every other
# background job (a signal between `&` and `CHILD=$!` leaves CHILD empty, but
# the job is already in `jobs -p`), wait up to 5 s for them, KILL any still
# running, log the stop (best effort: the log may not exist yet), and exit;
# the EXIT trap removes $WORK. `jobs -rp` (running jobs), not `kill -0`: a
# child that has exited stays a zombie, which kill -0 still finds.
on_signal() {
  local h line pids i
  trap '' INT TERM
  pids="$(jobs -p) $CHILD"
  # shellcheck disable=SC2086 # word splitting intended: a list of pids
  kill -TERM $pids 2>/dev/null
  i=0
  while [ -n "$(jobs -rp)" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done 2>/dev/null
  pids="$(jobs -rp)"
  # shellcheck disable=SC2086
  [ -n "$pids" ] && kill -KILL $pids 2>/dev/null
  if [ -n "${START:-}" ]; then
    h="$(hours %.2f)"
    line="fleet-board-run: stopped: interrupted ($1) after $TICK ticks, $h h, cost_estimate_usd $(fnum "$COST") (estimate)"
    printf '%s\n' "$line" >&3 2>/dev/null
    printf '%s\n' "$line" >> "$LOG" 2>/dev/null
  fi
  exit "$2"
}

WORK="$(mktemp -d)" || die 1 "mktemp failed"
trap 'rm -rf "$WORK"' EXIT
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM

# The logs hold tick reports and raw session output: umask 077, in subshells
# only, so claude and cleanup keep the caller's umask
( umask 077; mkdir -p "$LOG_DIR" ) 2>/dev/null || die 1 "cannot create the log directory $LOG_DIR"
LOG="$LOG_DIR/$(printf '%s' "$REPO_SLUG" | tr '/' '-')-$(date +%Y%m%d-%H%M%S).log"
[ -e "$LOG" ] && LOG="${LOG%.log}-$$.log"
( umask 077; set -C; : > "$LOG" ) 2>/dev/null || die 1 "cannot create the run log $LOG"

# log <line>...: append to the run log; a failed write ends the run
log() { printf '%s\n' "$@" >> "$LOG" || die 1 "cannot write the run log $LOG"; }
logfile() { cat "$1" >> "$LOG" || die 1 "cannot write the run log $LOG"; }
# logtail <file>: its last 20 lines, each cut to 2000 characters
logtail() {
  tail -20 "$1" | awk '{ if (length($0) > 2000) print substr($0, 1, 2000) " [line truncated]"; else print }' \
    > "$WORK/tail" && logfile "$WORK/tail"
}
warn() { printf 'fleet-board-run: warning: %s\n' "$1" >&2; log "fleet-board-run: warning: $1"; }

echo "fleet-board-run: log: $LOG"
log "fleet-board-run: start $(iso) repo=$REPO_SLUG root=$ROOT model=$MODEL permission_mode=$MODE"

if [ "$MODE" = bypassPermissions ]; then
  warn "headless.permission_mode is bypassPermissions: every tool call of every tick runs without a permission check"
fi

TICK=0
FAILS=0
COST=0
START="$(date +%s)"

stop() { # <reason> <exit code>
  local h line
  h="$(hours %.2f)"
  line="fleet-board-run: stopped: $1 after $TICK ticks, $h h, cost_estimate_usd $(fnum "$COST") (estimate)"
  echo "$line"
  log "$line"
  exit "$2"
}

# tick_cost <result json>: the tick's cost estimate, or nothing when unknown
tick_cost() {
  local c mu
  c="$(jq -r '.total_cost_usd | numbers' <<<"$1" 2>/dev/null)"
  if [ -n "$c" ] && num_ok "$(fnum "$c")"; then fnum "$c"; return 0; fi
  mu="$(jq -c '.modelUsage | objects' <<<"$1" 2>/dev/null)"
  [ -n "$mu" ] || return 1
  c="$(bash "$HERE/estimate-cost.sh" --model-usage "$mu" </dev/null 2>/dev/null)" || return 1
  num_ok "$c" || return 1
  fnum "$c"
}

# jq: rtrimws drops trailing spaces, tabs and CRs in linear time. (A regex
# sub("[ \t\r]+$") is quadratic on a long run of spaces not at the end of a
# line, and rtrim is not in jq 1.6.)
JQ_RTRIMWS='def rtrimws: explode as $c
  | ($c | length | until(. == 0 or ($c[. - 1] | . != 32 and . != 9 and . != 13); . - 1)) as $i
  | $c[:$i] | implode;'

# run_cleanup: cleanup-done.sh from the repo root; a failure is only a warning
run_cleanup() {
  local rc
  run_bg bash "$CLEANUP" </dev/null >"$WORK/cleanup.out" 2>"$WORK/cleanup.err"
  rc=$?
  log "--- cleanup-done.sh ---"
  logfile "$WORK/cleanup.out"
  if [ "$rc" -ne 0 ]; then
    log "warning: cleanup-done.sh exited $rc"
  fi
  logfile "$WORK/cleanup.err"
}

if [ -n "${FLEET_BOARD_TEST_BGJOB:-}" ]; then
  sleep 60 </dev/null >/dev/null 2>&1 3>&- &
  printf '%s\n' "$!" > "$FLEET_BOARD_TEST_BGJOB"
fi

PLUGIN_ARGS=()
[ -n "${FLEET_BOARD_PLUGIN_DIR:-}" ] && PLUGIN_ARGS=(--plugin-dir "$FLEET_BOARD_PLUGIN_DIR")

while :; do
  [ -e "$ROOT/.fleet-board.stop" ] && stop stop-file 0
  fgt "$(hours %.10f)" "$MAX_HOURS" && stop max-hours 0
  fgt "$COST" "$MAX_COST" && stop max-cost 0

  TICK=$((TICK + 1))
  OUT="$WORK/tick.jsonl"
  ERR="$WORK/tick.err"
  run_bg "$CLAUDE" -p "$PROMPT" ${PLUGIN_ARGS[@]+"${PLUGIN_ARGS[@]}"} --model "$MODEL" \
    --permission-mode "$MODE" --output-format stream-json --verbose \
    --max-turns "$MAX_TURNS" </dev/null >"$OUT" 2>"$ERR"
  RC=$?

  # The session's init event: a different permission mode would deny the
  # same tool calls on every later tick, so the run stops (no retry)
  INIT="$(jq -cR 'fromjson? | select(type == "object" and .type == "system" and .subtype == "init")' "$OUT" 2>/dev/null | head -1)"
  GOT_MODE="$(jq -r '.permissionMode | strings' <<<"$INIT" 2>/dev/null)"
  if [ -n "$GOT_MODE" ] && [ "$GOT_MODE" != "$MODE" ]; then
    log "=== tick $TICK $(iso) rc=$RC ===" \
      "permission mode mismatch: requested $MODE, session ran in $GOT_MODE (model $(jq -r '.model // "unknown"' <<<"$INIT" 2>/dev/null))"
    SAVED="${LOG%.log}-tick-$TICK.jsonl"
    if ( umask 077; set -C; cat "$OUT" > "$SAVED" ) 2>/dev/null; then
      log "full output: $SAVED"
    else
      log "warning: cannot save the full output to $SAVED"
    fi
    stop permission-mode-mismatch 1
  fi

  # The LAST result event: a session can emit several, and cost is cumulative
  RESULT="$(jq -cR 'fromjson? | select(type == "object" and .type == "result")' "$OUT" 2>/dev/null | tail -1)"
  WHY=""
  SIGNAL=""
  if [ "$RC" -ne 0 ]; then
    WHY="claude exited $RC"
  elif [ -z "$RESULT" ]; then
    WHY="no result event"
  elif [ "$(jq -r '.is_error' <<<"$RESULT" 2>/dev/null)" != false ]; then
    WHY="the result is an error ($(jq -r '.subtype // "no subtype"' <<<"$RESULT" 2>/dev/null))"
  else
    SIGNAL="$(jq -r "$JQ_RTRIMWS"'
      .result | strings | split("\n") | map(rtrimws) | map(select(length > 0))
      | (last // "") | (capture("^dispatchable: (?<v>true|false)$").v // empty)' <<<"$RESULT" 2>/dev/null)"
    case "$SIGNAL" in
      true|false) ;;
      *) SIGNAL=""; WHY="the result text does not end with a dispatchable: true|false line" ;;
    esac
    # A report whose plan failed (tick-plan.sh exited non-zero, e.g. a GitHub
    # rate limit) ends dispatchable: false, but the board is not settled: the
    # tick failed. Only a line that starts with the label "Plan failed:"
    # counts, since a model may format the report. Allowed before the label,
    # in this order: whitespace; any list markers "-", "*", "+", "1.", "1)"
    # (each followed by whitespace) and blockquote ">"; one heading "#" to
    # "######" followed by whitespace. Up to three emphasis or backtick
    # characters ("*", "_", "`") may sit before "Plan", between "failed" and
    # ":", and after ":" (e.g. **Plan failed**:, `Plan failed:`). Any other
    # text before the label (a table cell, a sentence, "-" with no space)
    # does not count. Up to three emphasis or backtick characters at the end
    # of the line (the close of a wrapped line) are left out of the reason.
    if [ -n "$SIGNAL" ]; then
      WHY="$(jq -r "$JQ_RTRIMWS"'
        "^[ \t]*(?:(?:[-*+]|[0-9]+[.)])[ \t]+|>[ \t]*)*(?:#{1,6}[ \t]+)?[*_`]{0,3}Plan failed[*_`]{0,3}:[*_`]{0,3}" as $pf
        | .result | strings | split("\n") | map(rtrimws)
        | map(select(test($pf))) | first // empty
        | sub($pf; "") | sub("^[ \t]+"; "") | sub("[*_`]{1,3}$"; "") | rtrimws
        | if length > 200 then .[0:200] + " [truncated]" else . end
        | "plan failed: " + . | sub(" +$"; "")' <<<"$RESULT" 2>/dev/null)"
    fi
  fi

  if [ -n "$WHY" ]; then
    FAILS=$((FAILS + 1))
    log "=== tick $TICK FAILED $(iso) rc=$RC ===" "reason: $WHY"
    if [ -n "$RESULT" ] && TC="$(tick_cost "$RESULT")"; then
      COST="$(fadd "$COST" "$TC")"
      log "cost_estimate_usd=$TC (estimate)"
    else
      log "cost_estimate_usd=unknown"
    fi
    SAVED="${LOG%.log}-tick-$TICK.jsonl"
    if ( umask 077; set -C; cat "$OUT" > "$SAVED" ) 2>/dev/null; then
      log "full output: $SAVED"
    else
      log "warning: cannot save the full output to $SAVED"
    fi
    log "--- last 20 lines of output ---"
    logtail "$OUT"
    if [ -s "$ERR" ]; then
      log "--- last 20 lines of stderr ---"
      logtail "$ERR"
    fi
    [ "$FAILS" -ge "$MAX_FAILS" ] && stop consecutive-failures 1
    [ "$INTERVAL" = 0 ] || run_bg sleep "$INTERVAL"
    continue
  fi

  FAILS=0
  if TC="$(tick_cost "$RESULT")"; then
    COST="$(fadd "$COST" "$TC")"
    log "=== tick $TICK $(iso) rc=0 cost_estimate_usd=$TC (estimate) ==="
  else
    TC=""
    log "=== tick $TICK $(iso) rc=0 cost_estimate_usd=unknown ==="
  fi
  jq -r '.result' <<<"$RESULT" > "$WORK/result.txt" && logfile "$WORK/result.txt"
  run_cleanup

  [ -n "$TC" ] || stop cost-unknown 1
  [ "$SIGNAL" = false ] && stop nothing-dispatchable 0
  fgt "$COST" "$MAX_COST" && stop max-cost 0
  [ "$INTERVAL" = 0 ] || run_bg sleep "$INTERVAL"
done
