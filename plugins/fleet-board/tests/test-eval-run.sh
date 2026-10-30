#!/usr/bin/env bash
#
# Plain-bash tests for eval/run.sh and eval/parse-result.sh (offline: a fake
# claude on PATH records any invocation, so a dry run is proven to run nothing).
#
# Usage: bash plugins/fleet-board/tests/test-eval-run.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
EVAL="${SCRIPT_DIR}/eval"
RUN="${EVAL}/run.sh"
PARSE="${EVAL}/parse-result.sh"
CAT="${EVAL}/defects/catalogue.tsv"

PASS=0
FAIL=0
LAST_OUT=""
LAST_ERR=""
LAST_EXIT=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fb-eval-run.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# fake claude: records that it ran
mkdir -p "$TMP/bin"
printf '#!/bin/sh\necho ran >> "%s/claude-ran"\nexit 0\n' "$TMP" > "$TMP/bin/claude"
chmod +x "$TMP/bin/claude"

run() {
  LAST_OUT="$(PATH="$TMP/bin:$PATH" bash "$@" 2>"$TMP/err")"
  LAST_EXIT=$?
  LAST_ERR="$(cat "$TMP/err")"
}
assert_exit() {
  if [ "$LAST_EXIT" = "$2" ]; then pass "$1"; else fail "$1" "expected exit $2, got $LAST_EXIT (stderr: $LAST_ERR)"; fi
}

ndefects="$(grep -vc '^#' "$CAT" 2>/dev/null || echo 0)"

# --- dry run ---------------------------------------------------------------
run "$RUN" --dry-run
assert_exit "--dry-run exits 0" 0
lines="$(printf '%s\n' "$LAST_OUT" | grep -c 'claude -p --bare')"
if [ "$ndefects" -ge 6 ] && [ "$lines" -eq $((ndefects * 3)) ]; then
  pass "--dry-run prints one claude -p --bare command per defect per run (default 3 runs: $lines)"
else
  fail "--dry-run prints one claude -p --bare command per defect per run" "defects=$ndefects lines=$lines"
fi
cfg="$(printf '%s\n' "$LAST_OUT" | grep -c 'CLAUDE_CONFIG_DIR=')"
if [ "$cfg" -eq "$lines" ] && [ "$lines" -gt 0 ]; then
  pass "every dry-run command sets a fresh CLAUDE_CONFIG_DIR"
else
  fail "every dry-run command sets a fresh CLAUDE_CONFIG_DIR" "cfg=$cfg lines=$lines"
fi
if [ ! -e "$TMP/claude-ran" ]; then
  pass "--dry-run runs nothing (fake claude never invoked)"
else
  fail "--dry-run runs nothing" "claude was invoked"
fi
while IFS="$(printf '\t')" read -r id _rest; do
  [ -z "$id" ] && continue
  case "$id" in \#*) continue ;; esac
  if printf '%s\n' "$LAST_OUT" | grep -q "$id"; then pass "dry run names defect $id"; else fail "dry run names defect $id" "absent"; fi
done < "$CAT"

# --- flags -----------------------------------------------------------------
run "$RUN" --dry-run --runs 1
lines1="$(printf '%s\n' "$LAST_OUT" | grep -c 'claude -p --bare')"
if [ "$lines1" -eq "$ndefects" ] && [ "$lines1" -gt 0 ]; then pass "--runs 1 gives one command per defect"; else fail "--runs 1 gives one command per defect" "lines=$lines1"; fi
run "$RUN" --dry-run --runs 1 --model sonnet
case "$LAST_OUT" in *"--model sonnet"*) pass "--model sonnet reaches the command" ;; *) fail "--model sonnet reaches the command" "$LAST_OUT" ;; esac
run "$RUN" --dry-run --runs 1 --mutation off
assert_exit "--mutation off accepted" 0
case "$LAST_OUT" in *"mutation=off"*) pass "--mutation off is recorded in the dry-run output" ;; *) fail "--mutation off is recorded" "$LAST_OUT" ;; esac
run "$RUN" --dry-run --mutation maybe
assert_exit "--mutation maybe rejected with exit 2" 2
run "$RUN" --dry-run --runs zero
assert_exit "--runs zero rejected with exit 2" 2
run "$RUN" --bogus
assert_exit "unknown flag rejected with exit 2" 2

# --- result parser -----------------------------------------------------------
run "$PARSE" "$EVAL/canned/caught.md" off-by-one
assert_exit "parser exits 0 on a caught report" 0
if [ "$LAST_OUT" = "caught" ]; then pass "report naming the defect at Important is caught"; else fail "report naming the defect at Important is caught" "got '$LAST_OUT'"; fi
run "$PARSE" "$EVAL/canned/missed.md" off-by-one
assert_exit "parser exits 0 on a missed report" 0
if [ "$LAST_OUT" = "missed" ]; then pass "report naming the defect only at Minor is missed"; else fail "report naming the defect only at Minor is missed" "got '$LAST_OUT'"; fi
run "$PARSE" "$EVAL/canned/caught.md" mocked-dependency
if [ "$LAST_OUT" = "missed" ]; then pass "a report about another defect is missed"; else fail "a report about another defect is missed" "got '$LAST_OUT'"; fi
run "$PARSE" "$EVAL/canned/caught.md" no-such-defect
assert_exit "parser rejects an unknown defect id with exit 2" 2

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
