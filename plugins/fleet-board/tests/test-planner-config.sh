#!/usr/bin/env bash
#
# Plain-bash tests for the planner.provider and planner.model config keys.
#
# Usage: bash plugins/fleet-board/tests/test-planner-config.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/../scripts/config.sh"

unset FLEET_BOARD_CONFIG || true

PASS=0
FAIL=0
CLEANUP_DIRS=()
LAST_OUT=""
LAST_ERR=""
LAST_EXIT=0

cleanup() {
  for dir in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do
    rm -rf "$dir" 2>/dev/null || true
  done
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

make_repo() { # YAML body on arg 1
  local tmpdir
  tmpdir="$(mktemp -d)"
  git init -q "$tmpdir"
  git -C "$tmpdir" config user.email "test@example.com"
  git -C "$tmpdir" config user.name "Test User"
  printf 'board:\n  repo: a/b\n%s\n' "$1" > "$tmpdir/.fleet-board.yml"
  git -C "$tmpdir" add .fleet-board.yml
  git -C "$tmpdir" commit -q -m initial
  CLEANUP_DIRS+=("$tmpdir")
  REPO="$tmpdir"
}

run_config() { # key optional
  local out err
  out="$(mktemp)"; err="$(mktemp)"
  if [ -n "${1:-}" ]; then
    /bin/bash "$SCRIPT" --dir "$REPO" "$1" > "$out" 2> "$err"
  else
    /bin/bash "$SCRIPT" --dir "$REPO" > "$out" 2> "$err"
  fi
  LAST_EXIT=$?
  LAST_OUT="$(cat "$out")"; LAST_ERR="$(cat "$err")"
  rm -f "$out" "$err"
}

expect_invalid() { # NAME YAML MESSAGE
  make_repo "$2"
  run_config
  if [ "$LAST_EXIT" = "5" ]; then pass "$1: exit 5"; else fail "$1: exit 5" "got exit $LAST_EXIT"; fi
  case "$LAST_ERR" in
    *"$3"*) pass "$1: names the field" ;;
    *) fail "$1: names the field" "expected '$3' in: $LAST_ERR" ;;
  esac
}

echo "Test: planner provider and model config keys"

make_repo ''
run_config planner.provider
if [ "$LAST_OUT" = "claude" ]; then pass "no planner block: planner.provider defaults to claude"; else fail "no planner block: planner.provider defaults to claude" "got '$LAST_OUT'"; fi
run_config
model_type="$(printf '%s' "$LAST_OUT" | jq -r '.planner.model | type' 2>&1)"
if [ "$model_type" = "null" ]; then pass "no planner block: planner.model defaults to null"; else fail "no planner block: planner.model defaults to null" "got type '$model_type'"; fi

make_repo 'planner: { provider: codex, model: gpt-x }'
run_config
if [ "$LAST_EXIT" = "0" ]; then pass "provider codex with string model is valid"; else fail "provider codex with string model is valid" "exit $LAST_EXIT: $LAST_ERR"; fi

expect_invalid "planner.provider gemini" 'planner: { provider: gemini }' "planner.provider"
expect_invalid "planner.provider number" 'planner: { provider: 5 }' "planner.provider"
expect_invalid "planner.model number" 'planner: { model: 5 }' "planner.model"
expect_invalid "planner.model list" 'planner: { model: [a] }' "planner.model"

make_repo ''
run_config
model_present="$(printf '%s' "$LAST_OUT" | jq -r '.planner | has("model")' 2>&1)"
if [ "$model_present" = "true" ]; then pass "no planner block: planner.model key is present"; else fail "no planner block: planner.model key is present" "has(model) printed '$model_present'"; fi

echo ""
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
