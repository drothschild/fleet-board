#!/usr/bin/env bash
#
# Plain-bash tests for the rate-limit wait and the per-token stagger in
# fleet-board-run.sh (offline: fake claude replays stream-json, a stub sleep
# records its duration and advances a stubbed clock file).
#
# Usage: bash plugins/fleet-board/tests/test-run-ratelimit.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../scripts/fleet-board-run.sh"
CONFIG="$SCRIPT_DIR/../scripts/config.sh"
FAKE_CLAUDE="$SCRIPT_DIR/fake-claude.sh"
FX="$(cd "$SCRIPT_DIR/../fixtures/claude" && pwd)"
ORIG_PATH="$PATH"
if [ -x /bin/bash ]; then BASH_EXE=/bin/bash; else BASH_EXE=bash; fi

PASS=0
FAIL=0
DIRS=()
trap 'for d in ${DIRS[@]+"${DIRS[@]}"}; do rm -rf "$d"; done' EXIT
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi; }

NOW0=1800000000 # the stubbed clock's start (epoch seconds)

# new_case <limits extra>: a temp repo, fake claude dir, stub gh/sleep, clock
new_case() {
  local tmp; tmp="$(mktemp -d)"; DIRS+=("$tmp")
  T="$(cd "$tmp" && pwd -P)"
  REPO="$T/repo"
  git init -q "$REPO"
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name T
  printf 'board: { repo: acme/toy }\nlimits: { tick_interval: 0%s }\n' "${1:+, $1}" > "$REPO/.fleet-board.yml"
  printf 'x\n' > "$REPO/file"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m initial
  FC="$T/fc"; mkdir -p "$FC"
  HOMEDIR="$T/home"; mkdir -p "$HOMEDIR"
  LOGS="$T/logs"
  BIN="$T/bin"; mkdir -p "$BIN"
  printf '#!/bin/sh\nexit 1\n' > "$BIN/gh"; chmod +x "$BIN/gh"
  CLEAN="$T/cleanup.sh"; printf '#!/bin/sh\nexit 0\n' > "$CLEAN"; chmod +x "$CLEAN"
  CLOCK="$T/clock"; printf '%s\n' "$NOW0" > "$CLOCK"
  SLEEPS="$T/sleeps"; : > "$SLEEPS"
  SLEEPSTUB="$T/sleep-stub.sh"
  printf '#!/bin/sh\nprintf "%%s\\n" "$1" >> "%s"\nn=$(cat "%s")\nprintf "%%s\\n" "$((n + ${1%%.*}))" > "%s"\n' "$SLEEPS" "$CLOCK" "$CLOCK" > "$SLEEPSTUB"
  chmod +x "$SLEEPSTUB"
  LOCK="$T/shared.lock"
}

# reset_in <seconds>: an ISO UTC time that many seconds after the stub clock
iso_at() {
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

# result_fixture <file> <jq object>
result_fixture() { { head -2 "$FX/tick-busy.jsonl"; jq -cn "{type:\"result\"} + $2"; } > "$1"; }
# failed_fixture <file> <plan failed text>
failed_fixture() {
  result_fixture "$1" "{subtype:\"success\",is_error:false,total_cost_usd:0.01,result:\"## tick\\n\\nPlan failed: $2\\n\\ndispatchable: false\"}"
}

run_wrapper() {
  ( umask 022
    export HOME="$HOMEDIR" PATH="$BIN:$ORIG_PATH" FLEET_BOARD_CLAUDE="$FAKE_CLAUDE" FAKE_CLAUDE_DIR="$FC" \
      FLEET_BOARD_LOG_DIR="$LOGS" FLEET_BOARD_CLEANUP="$CLEAN" \
      FLEET_BOARD_SLEEP="$SLEEPSTUB" FLEET_BOARD_NOW_FILE="$CLOCK" FLEET_BOARD_TOKEN_LOCK="$LOCK"
    cd "$REPO" || exit 90
    "$BASH_EXE" "$SCRIPT" --repo "$REPO" ) > "$T/out" 2> "$T/err"
  LAST_EXIT=$?
  LAST_OUT="$(cat "$T/out")"
  LAST_ERR="$(cat "$T/err")"
  LOGTXT="$(cat "$LOGS"/*.log 2>/dev/null)"
}

count() { cat "$FC/count" 2>/dev/null || echo 0; }

echo "rate-limit-wait (sleep until the reset, then run the next tick)"
new_case "rate_limit_max_wait: 7200, rate_limit_margin: 5"
failed_fixture "$FC/1.jsonl" "GraphQL: API rate limit exceeded, resets at $(iso_at $((NOW0 + 600)))"
cp "$FX/tick-idle.jsonl" "$FC/2.jsonl"
run_wrapper
assert_eq "wait: exit 0 after the idle tick" "$LAST_EXIT" "0"
assert_eq "wait: the stub slept until reset plus margin" "$(cat "$SLEEPS")" "605"
assert_eq "wait: the next tick ran" "$(count)" "2"
case "$LAST_OUT" in *"nothing-dispatchable after 2 ticks"*) pass "wait: settles on tick 2" ;; *) fail "wait: settles on tick 2" "$LAST_OUT" ;; esac

echo "rate-limit-wait-does-not-count-as-failure"
new_case "rate_limit_max_wait: 7200, rate_limit_margin: 5, max_consecutive_failures: 1"
failed_fixture "$FC/1.jsonl" "GraphQL: API rate limit exceeded, resets at $(iso_at $((NOW0 + 60)))"
cp "$FX/tick-idle.jsonl" "$FC/2.jsonl"
run_wrapper
assert_eq "wait-no-fail: exit 0, not consecutive-failures" "$LAST_EXIT" "0"

echo "rate-limit-cap (total wait over the cap ends the run non-zero)"
new_case "rate_limit_max_wait: 100, rate_limit_margin: 5"
failed_fixture "$FC/default.jsonl" "GraphQL: API rate limit exceeded, resets at $(iso_at $((NOW0 + 600)))"
run_wrapper
assert_eq "cap: exit 1" "$LAST_EXIT" "1"
assert_eq "cap: no sleep happened" "$(wc -l < "$SLEEPS" | tr -d ' ')" "0"
case "$LOGTXT" in *"rate limit"*"cap"*) pass "cap: the log names the reason" ;; *) fail "cap: the log names the reason" "$LOGTXT" ;; esac

echo "rate-limit-cap-cumulative (two waits add up against the cap)"
new_case "rate_limit_max_wait: 700, rate_limit_margin: 0"
failed_fixture "$FC/1.jsonl" "GraphQL: API rate limit exceeded, resets at $(iso_at $((NOW0 + 400)))"
failed_fixture "$FC/2.jsonl" "GraphQL: API rate limit exceeded, resets at $(iso_at $((NOW0 + 800)))"
cp "$FX/tick-idle.jsonl" "$FC/3.jsonl"
run_wrapper
assert_eq "cumulative: exit 1" "$LAST_EXIT" "1"
assert_eq "cumulative: only the first wait slept" "$(cat "$SLEEPS")" "400"

echo "non-rate-limit Plan failed still fails the tick"
new_case "max_consecutive_failures: 2, rate_limit_max_wait: 7200"
failed_fixture "$FC/default.jsonl" "bad glob in test_paths"
run_wrapper
assert_eq "other-plan-failed: exit 1" "$LAST_EXIT" "1"
case "$LAST_OUT" in *"consecutive-failures after 2 ticks"*) pass "other-plan-failed: consecutive-failures" ;; *) fail "other-plan-failed: consecutive-failures" "$LAST_OUT" ;; esac
assert_eq "other-plan-failed: no wait" "$(wc -l < "$SLEEPS" | tr -d ' ')" "0"

echo "rate-limit without a reset time is a plain failed tick"
new_case "max_consecutive_failures: 1"
failed_fixture "$FC/default.jsonl" "GraphQL: API rate limit exceeded"
run_wrapper
assert_eq "no-reset: exit 1" "$LAST_EXIT" "1"
assert_eq "no-reset: no wait" "$(wc -l < "$SLEEPS" | tr -d ' ')" "0"

echo "plan-failed-never-settled (not an empty board)"
new_case "max_consecutive_failures: 1"
failed_fixture "$FC/default.jsonl" "GraphQL: API rate limit exceeded"
run_wrapper
case "$LAST_OUT" in *nothing-dispatchable*) fail "never-settled: not nothing-dispatchable" "$LAST_OUT" ;; *) pass "never-settled: not nothing-dispatchable" ;; esac
assert_eq "never-settled: exit non-zero" "$((LAST_EXIT != 0))" "1"

echo "stagger (two wrappers sharing one lock file keep min_tick_gap apart)"
new_case "min_tick_gap: 120"
cp "$FX/tick-idle.jsonl" "$FC/default.jsonl"
run_wrapper
assert_eq "stagger: first run exit 0" "$LAST_EXIT" "0"
assert_eq "stagger: first run did not wait" "$(wc -l < "$SLEEPS" | tr -d ' ')" "0"
assert_eq "stagger: lock file records the tick start" "$(tr -d '[:space:]' < "$LOCK" 2>/dev/null)" "$NOW0"
printf '%s\n' "$((NOW0 + 30))" > "$CLOCK"
rm -rf "$LOGS"
run_wrapper
assert_eq "stagger: second run exit 0" "$LAST_EXIT" "0"
assert_eq "stagger: second run waited the rest of the gap" "$(cat "$SLEEPS")" "90"
assert_eq "stagger: lock file records the later start" "$(tr -d '[:space:]' < "$LOCK" 2>/dev/null)" "$((NOW0 + 120))"

echo "stagger-off (min_tick_gap 0 never waits)"
new_case "min_tick_gap: 0"
cp "$FX/tick-idle.jsonl" "$FC/default.jsonl"
run_wrapper
run_wrapper
assert_eq "stagger-off: no sleeps" "$(wc -l < "$SLEEPS" | tr -d ' ')" "0"

echo "config validation (exit 5 on a bad value)"
bad_cfg() { # <name> <limits yaml body>
  local d; d="$(mktemp -d)"; DIRS+=("$d")
  git init -q "$d"
  printf 'board: { repo: a/b }\nlimits: { %s }\n' "$2" > "$d/.fleet-board.yml"
  ( cd "$d" && "$BASH_EXE" "$CONFIG" --check ) > /dev/null 2> "$d/err"
  assert_eq "config $1: exit 5" "$?" "5"
  case "$(cat "$d/err")" in *"limits.$3"*) pass "config $1: names the key" ;; *) fail "config $1: names the key" "$(cat "$d/err")" ;; esac
}
bad_cfg "rate_limit_max_wait word" "rate_limit_max_wait: soon" rate_limit_max_wait
bad_cfg "rate_limit_max_wait negative" "rate_limit_max_wait: -1" rate_limit_max_wait
bad_cfg "rate_limit_margin word" "rate_limit_margin: lots" rate_limit_margin
bad_cfg "min_tick_gap negative" "min_tick_gap: -5" min_tick_gap
good="$(mktemp -d)"; DIRS+=("$good"); git init -q "$good"
printf 'board: { repo: a/b }\nlimits: { rate_limit_max_wait: 0, rate_limit_margin: 2.5, min_tick_gap: 60 }\n' > "$good/.fleet-board.yml"
( cd "$good" && "$BASH_EXE" "$CONFIG" --check ) > /dev/null 2>&1
assert_eq "config valid values: exit 0" "$?" "0"
assert_eq "config default min_tick_gap" "$(cd "$good" && printf 'board: { repo: a/b }\n' > .fleet-board.yml && "$BASH_EXE" "$CONFIG" limits.min_tick_gap)" "0"

echo "docs mention the new keys"
for k in rate_limit_max_wait rate_limit_margin min_tick_gap; do
  if grep -q "$k" "$SCRIPT_DIR/../docs/config.md"; then pass "docs/config.md documents $k"; else fail "docs/config.md documents $k" "missing"; fi
  if grep -q "$k" "$SCRIPT_DIR/../docs/overnight.md"; then pass "docs/overnight.md describes $k"; else fail "docs/overnight.md describes $k" "missing"; fi
done

echo ""
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
