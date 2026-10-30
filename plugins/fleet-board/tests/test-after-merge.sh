#!/usr/bin/env bash
#
#
# Plain-bash tests for after-merge.sh (offline): parse reads a card body's
# "## After merge" section, run executes allowlisted commands after a merge.
#
# Usage: bash plugins/fleet-board/tests/test-after-merge.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/../scripts/after-merge.sh"
CONFIG="${SCRIPT_DIR}/../scripts/config.sh"
DOCS="${SCRIPT_DIR}/../docs/config.md"

unset FLEET_BOARD_CONFIG || true

PASS=0
FAIL=0
LAST_OUT=""
LAST_ERR=""
LAST_EXIT=0
CLEANUP_DIRS=()

cleanup() {
  for dir in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do rm -rf "$dir" 2>/dev/null || true; done
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
  local tmpout tmperr
  tmpout="$(mktemp)"; tmperr="$(mktemp)"
  bash "$@" > "$tmpout" 2> "$tmperr"
  LAST_EXIT=$?
  LAST_OUT="$(cat "$tmpout")"; LAST_ERR="$(cat "$tmperr")"
  rm -f "$tmpout" "$tmperr"
}
jqc() { jq -c "$1" <<<"$LAST_OUT" 2>/dev/null || echo INVALID; }
assert_jq() { assert_eq "$1" "$(jqc "$2")" "$3"; }

# setup_repo [extra top-level yaml]: a repo for acme/toy
setup_repo() {
  REPO="$(mktemp -d)"
  git init -q "$REPO"
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test User"
  {
    printf 'board:\n  repo: acme/toy\n'
    [ -n "${1:-}" ] && printf '%s\n' "$1"
  } > "$REPO/.fleet-board.yml"
  git -C "$REPO" add .fleet-board.yml
  git -C "$REPO" commit -q -m "initial"
  CLEANUP_DIRS+=("$REPO")
  unset FLEET_BOARD_CONFIG || true
  cd "$REPO"
}

# body_file <text>: writes the text to a temp file and sets BODY
body_file() {
  BODY="$(mktemp)"
  CLEANUP_DIRS+=("$BODY")
  printf '%s\n' "$1" > "$BODY"
}

echo "Test: after-merge.sh"
echo ""

echo "parse"
setup_repo
body_file "Body.

## Acceptance
- it works

## After merge
- git tag v1.2.3
* git push origin v1.2.3

Some prose.
## Notes
- not a command"
run_check "$SCRIPT" parse "$BODY"
assert_exit "parse: exit" 0
assert_jq "parse: one command per bullet, other sections not read" '.commands' '["git tag v1.2.3","git push origin v1.2.3"]'

body_file "Body.

## Acceptance
- ok"
run_check "$SCRIPT" parse "$BODY"
assert_exit "parse: no section, exit" 0
assert_jq "parse: no section gives no commands" '.commands' '[]'

echo "config"
setup_repo
run_check "$CONFIG" after_merge.allow
assert_exit "config: missing after_merge key is valid" 0
assert_eq "config: missing key defaults to an empty allowlist" "$(bash "$CONFIG" after_merge.allow)" "[]"
setup_repo "after_merge:
  allow: [\"git tag\", \"git push origin\"]"
assert_eq "config: after_merge.allow is read as a list" "$(bash "$CONFIG" after_merge.allow)" '["git tag","git push origin"]'
setup_repo "after_merge:
  allow: git tag"
run_check "$CONFIG" --check
assert_exit "config: a non-list after_merge.allow is invalid" 5

echo "run"
setup_repo
body_file "## After merge
- git tag v1"
run_check "$SCRIPT" run "$BODY"
assert_exit "run: exit with a refusal" 0
assert_jq "run: no allowlist means refused and blocked" '[.outcome, .results[0].status]' '["blocked","refused"]'
assert_jq "run: refusal comment names the command and the missing entry" \
  '.comment | (contains("git tag v1") and contains("after_merge.allow"))' 'true'

setup_repo "after_merge:
  allow: [\"echo\", \"test -f\"]"
body_file "## After merge
- echo hello
- echo world"
run_check "$SCRIPT" run "$BODY"
assert_exit "run: exit when all succeed" 0
assert_jq "run: all succeed gives done and no human qa" '.outcome' '"done"'
assert_jq "run: each command's exit status is recorded" '[.results[] | [.command, .status, .exit]]' '[["echo hello","ok",0],["echo world","ok",0]]'
assert_jq "run: a note line per command" '.note | length' '2'

body_file "## After merge
- echo first
- test -f /nonexistent-fleet-board-path
- echo never"
run_check "$SCRIPT" run "$BODY"
assert_jq "run: a non-zero exit blocks" '.outcome' '"blocked"'
assert_jq "run: the failure is recorded with its exit status and later commands do not run" \
  '[.results[] | [.command, .status, .exit]]' '[["echo first","ok",0],["test -f /nonexistent-fleet-board-path","failed",1]]'
assert_jq "run: failure comment names command and exit status" \
  '.comment | (contains("test -f /nonexistent-fleet-board-path") and contains("exit 1"))' 'true'

body_file "## After merge
- echo ok
- rm -rf /tmp/never"
run_check "$SCRIPT" run "$BODY"
assert_jq "run: unlisted command is refused, not run, and blocks" '[.outcome, .results[1].status, .results[1].exit]' '["blocked","refused",null]'

body_file "## After merge
- echo ok; touch $REPO/pwned"
run_check "$SCRIPT" run "$BODY"
assert_jq "run: a prefix match cannot chain another command" '.results[0].status' '"refused"'
assert_eq "run: the chained command did not run" "$([ -e "$REPO/pwned" ] && echo yes || echo no)" "no"

body_file "## After merge
- echoes hi"
run_check "$SCRIPT" run "$BODY"
assert_jq "run: prefix matches whole words only" '.results[0].status' '"refused"'

body_file "Nothing here."
run_check "$SCRIPT" run "$BODY"
assert_jq "run: no section gives done with no results" '[.outcome, (.results | length)]' '["done",0]'

echo "docs"
for needle in 'after_merge.allow' '## After merge'; do
  if grep -qF -- "$needle" "$DOCS"; then pass "docs: config.md mentions $needle"; else fail "docs: config.md mentions $needle" "missing"; fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
