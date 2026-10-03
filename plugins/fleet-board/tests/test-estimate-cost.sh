#!/usr/bin/env bash
#
# Plain-bash tests for estimate-cost.sh and prices.json (offline, no gh).
# No framework, no dependencies beyond POSIX tools and jq.
#
# Usage: bash plugins/fleet-board/tests/test-estimate-cost.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/../scripts/estimate-cost.sh"
PRICES="${SCRIPT_DIR}/../scripts/prices.json"

PASS=0
FAIL=0
LAST_OUT=""
LAST_ERR=""
LAST_EXIT=0

if [ -x /bin/bash ]; then
  BASH_EXE="/bin/bash"
else
  BASH_EXE="bash"
fi

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

assert_exit() {
  if [ "$LAST_EXIT" = "$2" ]; then pass "$1"; else fail "$1" "expected exit $2, got $LAST_EXIT (stderr: $LAST_ERR)"; fi
}

assert_stdout_exact() {
  if [ "$LAST_OUT" = "$2" ]; then pass "$1"; else fail "$1" "expected stdout: '$2', got: '$LAST_OUT'"; fi
}

assert_stderr_contains() {
  case "$LAST_ERR" in
    *"$2"*) pass "$1" ;;
    *) fail "$1" "expected to find '$2' in stderr, got: '$LAST_ERR'" ;;
  esac
}

assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}

run_check() {
  local script="$1"
  shift
  local tmpout tmperr
  tmpout="$(mktemp)"
  tmperr="$(mktemp)"
  "$BASH_EXE" "$script" "$@" > "$tmpout" 2> "$tmperr"
  LAST_EXIT=$?
  LAST_OUT="$(cat "$tmpout")"
  LAST_ERR="$(cat "$tmperr")"
  rm -f "$tmpout" "$tmperr"
}

cost() { run_check "$SCRIPT" "$@"; }

echo "Test: estimate-cost.sh"
echo ""

# ---------------------------------------------------------------------------
# prices.json is exactly the plan's table
assert_eq "prices: as_of" "$(jq -r .as_of "$PRICES" 2>/dev/null)" "2026-09-28"
assert_eq "prices: aliases" "$(jq -c -S .aliases "$PRICES" 2>/dev/null)" \
  '{"fable":"claude-fable-5-1","haiku":"claude-haiku-4-5-20251001","opus":"claude-opus-5-5","sonnet":"claude-sonnet-5"}'
assert_eq "prices: models" "$(jq -c -S .models "$PRICES" 2>/dev/null)" \
  '{"claude-fable-5-1":{"cache_read":1,"cache_write":12.5,"input":10,"output":50},"claude-haiku-4-5-20251001":{"cache_read":0.1,"cache_write":1.25,"input":1,"output":5},"claude-opus-5-5":{"cache_read":0.2,"cache_write":5,"input":4,"output":20},"claude-sonnet-5":{"cache_read":0.2,"cache_write":2.5,"input":2,"output":10}}'
case "$(jq -r .note "$PRICES" 2>/dev/null)" in
  "Estimate only. Update from https://platform.claude.com/docs/en/about-claude/pricing"*"Fable 5.1"*"carried over"*"Fable 5"*)
    pass "prices: note marks the Fable 5.1 price as carried over" ;;
  *) fail "prices: note marks the Fable 5.1 price as carried over" "$(jq -r .note "$PRICES" 2>/dev/null)" ;;
esac

# --input/--output
cost --model sonnet --input 1000000 --output 1000000
assert_exit "sonnet 1M/1M: exit" 0
assert_stdout_exact "sonnet 1M/1M: 12.0000" "12.0000"

# Input and output priced separately (catches a swapped rate)
cost --model opus --input 1000000 --output 0
assert_stdout_exact "opus 1M input only: 4.0000" "4.0000"
cost --model opus --input 0 --output 1000000
assert_stdout_exact "opus 1M output only: 20.0000" "20.0000"

# Cache writes and reads, by full model id
cost --model claude-haiku-4-5-20251001 --input 0 --output 0 --cache-write 1000000 --cache-read 1000000
assert_exit "haiku cache: exit" 0
assert_stdout_exact "haiku cache: 1.25 + 0.1" "1.3500"

# Four decimals on a small count
cost --model sonnet --input 1234 --output 567
assert_stdout_exact "sonnet small: 0.002468 + 0.00567 -> 0.0081" "0.0081"

# --tokens: blended 0.8*input + 0.2*output
cost --model opus --tokens 1000000
assert_exit "opus --tokens: exit" 0
assert_stdout_exact "opus --tokens 1M: 7.2000" "7.2000"
cost --model fable --tokens 1000000
assert_stdout_exact "fable --tokens 1M: 0.8*10 + 0.2*50" "18.0000"

# --model-usage: sums costUSD when present
cost --model-usage '{"claude-opus-5-5":{"inputTokens":10,"outputTokens":20,"costUSD":1.25},"claude-sonnet-5":{"inputTokens":5,"outputTokens":5,"costUSD":0.5}}'
assert_exit "model-usage costUSD: exit" 0
assert_stdout_exact "model-usage costUSD: 1.25 + 0.5" "1.7500"

# --model-usage without costUSD prices the tokens
cost --model-usage '{"claude-sonnet-5":{"inputTokens":1000000,"outputTokens":0,"cacheReadInputTokens":1000000,"cacheCreationInputTokens":1000000}}'
assert_exit "model-usage priced: exit" 0
assert_stdout_exact "model-usage priced: 2 + 0.2 + 2.5" "4.7000"

# Unknown models exit 1
cost --model gpt --input 1 --output 1
assert_exit "unknown model: exit 1" 1
assert_eq "unknown model: no stdout" "$LAST_OUT" ""
assert_stderr_contains "unknown model: names it" "gpt"
cost --model gpt --tokens 5
assert_exit "unknown model --tokens: exit 1" 1
cost --model-usage '{"gpt-9":{"inputTokens":1,"outputTokens":1}}'
assert_exit "unknown model in model-usage without costUSD: exit 1" 1

# Usage errors
cost --model sonnet --input abc --output 1
assert_exit "non-numeric count: exit 2" 2
cost --model sonnet
assert_exit "no counts: exit 2" 2
cost --model-usage 'not json'
assert_exit "model-usage not JSON: exit 2" 2

# A comma-decimal locale (LC_NUMERIC) must not change the output or the parsing
DE_LOCALE="$(locale -a 2>/dev/null | grep -iE '^de_DE\.utf-?8$' | head -1)"
if [ -z "$DE_LOCALE" ]; then
  echo "locale-de cases: SKIPPED (locale -a lists no de_DE UTF-8 locale)"
else
  case "$(LC_ALL="$DE_LOCALE" awk 'BEGIN { printf "%.1f", 0.5 }')" in
    0,5) ;;
    *) echo "       (note: awk ignores LC_NUMERIC here, so the locale-de cases cannot fail on this machine)" ;;
  esac
  LC_ALL="$DE_LOCALE" cost --model sonnet --input 1000000 --output 1000000
  assert_exit "locale-de --input/--output: exit 0" 0
  assert_stdout_exact "locale-de --input/--output: dot decimal" "12.0000"
  LC_ALL="$DE_LOCALE" cost --model sonnet --tokens 1000000
  assert_stdout_exact "locale-de --tokens: 0.8*2 + 0.2*10, dot decimal" "3.6000"
  LC_ALL="$DE_LOCALE" cost --model haiku --input 0 --output 0 --cache-read 1000000
  assert_stdout_exact "locale-de: a decimal rate (cache_read 0.1) is read as a number" "0.1000"
  LC_ALL="$DE_LOCALE" cost --model-usage '{"claude-opus-5-5":{"costUSD":1.25},"claude-sonnet-5":{"costUSD":0.5}}'
  assert_exit "locale-de model-usage costUSD: exit 0" 0
  assert_stdout_exact "locale-de model-usage costUSD: 1.25 + 0.5 read as numbers" "1.7500"
  LC_ALL="$DE_LOCALE" cost --model-usage '{"claude-sonnet-5":{"inputTokens":1000000,"outputTokens":0,"cacheReadInputTokens":1000000,"cacheCreationInputTokens":1000000}}'
  assert_stdout_exact "locale-de model-usage priced: 2 + 0.2 + 2.5" "4.7000"
fi

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
