#!/usr/bin/env bash
#
# Plain-bash tests for deps.sh (offline, fake gh): parse reads a card body's
# "## Depends on" section, check looks each dependency up.
# No framework, no dependencies beyond POSIX tools, jq and git.
#
# Usage: bash plugins/fleet-board/tests/test-deps.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/../scripts/deps.sh"

unset FLEET_BOARD_CONFIG FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT || true

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

# jq -c of the last stdout; INVALID when it does not parse
jqc() { jq -c "$1" <<<"$LAST_OUT" 2>/dev/null || echo INVALID; }

# assert_jq <desc> <filter> <expected compact JSON>
assert_jq() { assert_eq "$1" "$(jqc "$2")" "$3"; }

# setup_repo [extra YAML appended to the config]: a repo for acme/toy
setup_repo() {
  REPO="$(mktemp -d)"
  git init -q "$REPO"
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test User"
  {
    printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\n'
    [ -n "${1:-}" ] && printf '%s\n' "$1"
  } > "$REPO/.fleet-board.yml"
  git -C "$REPO" add .fleet-board.yml
  git -C "$REPO" commit -q -m "initial"
  CLEANUP_DIRS+=("$REPO")
  unset CDPATH FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT FLEET_BOARD_CONFIG || true
  cd "$REPO"
}

# parse_body <body text>: runs deps.sh parse on the body
parse_body() {
  local f
  setup_repo
  f="$(mktemp)"
  CLEANUP_DIRS+=("$f")
  printf '%s\n' "$1" > "$f"
  run_check "$SCRIPT" parse "$f"
}

echo "Test: deps.sh"
echo ""

# ---------------------------------------------------------------------------
# parse
echo "parse"

parse_body "Do the thing.

## Acceptance
- it works

## Depends on
- #22
- other/repo#7

* acme/toy#5
## Notes
- #99"
assert_exit "parse: exit" 0
assert_jq "parse: same-repo, other-repo and star bullets; the next section is not read" '.refs' \
  '[{"repo":"acme/toy","number":22,"ref":"acme/toy#22"},{"repo":"other/repo","number":7,"ref":"other/repo#7"},{"repo":"acme/toy","number":5,"ref":"acme/toy#5"}]'
assert_jq "parse: no warnings" '.warnings' '[]'

parse_body "Body.

## Acceptance
- ok"
assert_exit "parse: no section, exit" 0
assert_jq "parse: no section gives no refs and no warnings" '.' '{"refs":[],"warnings":[]}'

parse_body "## Depends on
- #22
- not a dependency
- #22 (and a note)
see the other card
- acme/toy#22
- #x1
- Other/Repo#3"
assert_exit "parse: bad lines, exit" 0
assert_jq "parse: only the valid bullets count, duplicates dropped" '[.refs[].ref]' '["acme/toy#22","Other/Repo#3"]'
assert_jq "parse: every other nonblank line is a warning naming the line" '.warnings' \
  '["unrecognized dependency line: - not a dependency","unrecognized dependency line: - #22 (and a note)","unrecognized dependency line: see the other card","unrecognized dependency line: - #x1"]'

parse_body "## depends on
- #4"
assert_jq "parse: the heading is case-insensitive" '[.refs[].ref]' '["acme/toy#4"]'

parse_body "## Depends on
- #4

## Depends on
- #5"
assert_jq "parse: a repeated section is read too" '[.refs[].ref]' '["acme/toy#4","acme/toy#5"]'

parse_body "## Dependson
- #4"
assert_jq "parse: a different heading is not the section" '.refs' '[]'

setup_repo
run_check "$SCRIPT" parse "$REPO/no-such-file"
assert_exit "parse: missing file is a usage error" 2
run_check "$SCRIPT" parse
assert_exit "parse: no file is a usage error" 2
run_check "$SCRIPT" frobnicate
assert_exit "unknown subcommand is a usage error" 2

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
