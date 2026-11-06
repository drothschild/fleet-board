#!/usr/bin/env bash
#
# Plain-bash tests for the local board backend (config identity and names)
# No framework, no dependencies beyond POSIX tools.
#
# Usage: bash plugins/fleet-board/tests/test-board-local.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPTS="$SCRIPT_DIR/../scripts"
export SCRIPTS

unset FLEET_BOARD_CONFIG FLEET_BOARD_USER FLEET_BOARD_LOCK_WAIT || true

PASS=0
FAIL=0
LAST_OUT=""
LAST_ERR=""
LAST_EXIT=0
CLEANUP_DIRS=()
ORIG_PATH="$PATH"

# Choose a bash executable for consistent invocation.
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
  if [ "$LAST_EXIT" = "$2" ]; then pass "$1"; else fail "$1" "expected exit $2, got $LAST_EXIT"; fi
}

assert_stdout_exact() {
  if [ "$LAST_OUT" = "$2" ]; then pass "$1"; else fail "$1" "expected stdout: '$2', got: '$LAST_OUT' (stderr: '$LAST_ERR')"; fi
}

assert_stdout_contains() {
  case "$LAST_OUT" in
    *"$2"*) pass "$1" ;;
    *) fail "$1" "expected '$2' in stdout" ;;
  esac
}

assert_stderr_contains() {
  case "$LAST_ERR" in
    *"$2"*) pass "$1" ;;
    *) fail "$1" "expected '$2' in stderr" ;;
  esac
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

# run_check_in <dir> <cmd...>: run the command with <dir> as its cwd.
run_check_in() {
  local dir="$1"
  shift
  local tmpout tmperr
  tmpout="$(mktemp)"
  tmperr="$(mktemp)"
  ( unset CDPATH; cd "$dir" && "$@" ) > "$tmpout" 2> "$tmperr"
  LAST_EXIT=$?
  LAST_OUT="$(cat "$tmpout")"
  LAST_ERR="$(cat "$tmperr")"
  rm -f "$tmpout" "$tmperr"
}

# A gh that exits 99 on every call: any stray gh call fails the case.
NOGH_DIR="$(mktemp -d)"
CLEANUP_DIRS+=("$NOGH_DIR")
printf '#!/bin/sh\necho "gh must not be called: $*" >&2\nexit 99\n' > "$NOGH_DIR/gh"
chmod +x "$NOGH_DIR/gh"
PATH="$NOGH_DIR:$ORIG_PATH"

# setup_case: sets REPO to a fresh git repo with a committed local-backend config.
setup_case() {
  REPO="$(mktemp -d)"
  CLEANUP_DIRS+=("$REPO")
  git init -q "$REPO"
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test User"
  cat > "$REPO/.fleet-board.yml" <<'YML'
board:
  backend: local
  repo: acme/toy
worktrees:
  dir: .fw
YML
  git -C "$REPO" add .fleet-board.yml
  git -C "$REPO" commit -q -m "initial"
}

echo "Test: local board backend"
echo ""

setup_case

run_check_in "$REPO" "$BASH_EXE" -c '. "$SCRIPTS/board-lib.sh"; fb_load_config; fb_login'
assert_exit "fb_login exits 0 without gh" "0"
assert_stdout_exact "fb_login is USER on local" "$USER"

FLEET_BOARD_USER=robot run_check_in "$REPO" "$BASH_EXE" -c '. "$SCRIPTS/board-lib.sh"; fb_load_config; fb_login'
assert_stdout_exact "fb_login honors FLEET_BOARD_USER" "robot"

run_check_in "$REPO" "$BASH_EXE" -c '. "$SCRIPTS/board-lib.sh"; fb_load_config; fb_state_name in_progress; fb_state_name wont_do'
assert_stdout_exact "local default names" $'In Progress\nWon'"'"'t Do'

run_check_in "$REPO" "$BASH_EXE" -c '. "$SCRIPTS/board-lib.sh"; fb_load_config; for s in backlog ready in_progress in_review human_qa blocked done wont_do; do fb_state_name $s; done'
assert_stdout_exact "local names for all eight states" $'Backlog\nReady\nIn Progress\nIn Review\nHuman QA\nBlocked\nDone\nWon\'t Do'

# A review stage prints "Review: <name>" like Projects does.
setup_case
cat >> "$REPO/.fleet-board.yml" <<'YML'
review:
  stages:
    - name: security
      agent: acme:sec
YML
run_check_in "$REPO" "$BASH_EXE" -c '. "$SCRIPTS/board-lib.sh"; fb_load_config; fb_state_name review_security'
assert_stdout_exact "local review stage name" "Review: security"

echo ""
echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
