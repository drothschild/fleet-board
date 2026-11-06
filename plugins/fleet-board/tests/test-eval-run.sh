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
lines="$(printf '%s\n' "$LAST_OUT" | grep -c 'claude -p ')"
if [ "$ndefects" -ge 6 ] && [ "$lines" -eq $((ndefects * 3)) ]; then
  pass "--dry-run prints one claude -p command per defect per run (default 3 runs: $lines)"
else
  fail "--dry-run prints one claude -p command per defect per run" "defects=$ndefects lines=$lines"
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
lines1="$(printf '%s\n' "$LAST_OUT" | grep -c 'claude -p ')"
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

# --- real-run path, offline (a fake claude that speaks stream-json) --------------
# The reviewer is a subagent, so the session must have the Agent tool: --bare removes it.
run "$RUN" --dry-run --runs 1
case "$LAST_OUT" in *"--bare"*) fail "dry-run commands do not use --bare" "--bare present" ;; *) pass "dry-run commands do not use --bare" ;; esac
case "$LAST_OUT" in *"</dev/null"*) pass "dry-run commands close stdin" ;; *) fail "dry-run commands close stdin" "no </dev/null" ;; esac

FAKE_DIR="$TMP/fake"
mkdir -p "$TMP/bin-real" "$FAKE_DIR"
cat > "$TMP/bin-real/claude" <<'FAKE'
#!/bin/sh
cat >> "$FAKE_DIR/stdin"
echo ran >> "$FAKE_DIR/ran"
for a in "$@"; do last="$a"; done
printf '%s\n' "$last" >> "$FAKE_DIR/prompts"
if [ "$FAKE_MODE" != no-agent ]; then
  echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"fleet-board:reviewer"}}]}}'
fi
jq -c -R -s '{type:"result",result:.,total_cost_usd:1.5}' < "$FAKE_REPORT"
FAKE
chmod +x "$TMP/bin-real/claude"
printf 'I could not dispatch the agent. pageCount looks off by one.\n' > "$TMP/prose.md"

# real_run MODE REPORT OUT [run.sh args...]
real_run() {
  local mode="$1" report="$2" out="$3"
  shift 3
  rm -rf "$FAKE_DIR" && mkdir -p "$FAKE_DIR"
  LAST_OUT="$(PATH="$TMP/bin-real:$PATH" FAKE_DIR="$FAKE_DIR" FAKE_MODE="$mode" FAKE_REPORT="$report" \
    bash "$RUN" --out "$out" "$@" 2>"$TMP/err")"
  LAST_EXIT=$?
  LAST_ERR="$(cat "$TMP/err")"
}
verdict_is() {
  local got
  got="$(cut -f6 "$3/results.tsv" 2>/dev/null)"
  if [ "$got" = "$2" ]; then pass "$1"; else fail "$1" "expected verdict '$2', got '$got'"; fi
}

real_run agent "$EVAL/canned/caught.md" "$TMP/o1" --defect off-by-one --runs 1
assert_exit "a dispatched reviewer's run exits 0" 0
verdict_is "a dispatched reviewer naming the defect is caught" caught "$TMP/o1"
if [ "$(cut -f7 "$TMP/o1/results.tsv" 2>/dev/null)" = "1.5" ]; then pass "cost comes from the result event"; else fail "cost comes from the result event" "$(cat "$TMP/o1/results.tsv" 2>/dev/null)"; fi
if [ -s "$TMP/o1/work/off-by-one-1.jsonl" ]; then pass "the run's transcript is kept"; else fail "the run's transcript is kept" "no jsonl"; fi

real_run agent "$EVAL/canned/missed.md" "$TMP/o2" --defect off-by-one --runs 1
assert_exit "a real miss still exits 0" 0
verdict_is "a dispatched reviewer that misses the defect is missed" missed "$TMP/o2"

real_run no-agent "$TMP/prose.md" "$TMP/o3" --defect off-by-one --runs 1
assert_exit "a run where the reviewer was never dispatched exits 1" 1
verdict_is "a run where the reviewer was never dispatched is error, not missed" error "$TMP/o3"
case "$LAST_OUT" in
  *"| off-by-one | opus | on | 0 | 0 | n/a |"*) pass "an errored run is left out of the catch rate" ;;
  *) fail "an errored run is left out of the catch rate" "$LAST_OUT" ;;
esac
case "$LAST_OUT" in *"1 run(s) errored"*) pass "the runner reports how many runs errored" ;; *) fail "the runner reports how many runs errored" "$LAST_OUT" ;; esac

real_run agent "$TMP/prose.md" "$TMP/o4" --defect off-by-one --runs 1
assert_exit "a report without a Findings section exits 1" 1
verdict_is "a report without a Findings section is error" error "$TMP/o4"

real_run agent "$EVAL/canned/missed.md" "$TMP/o5" --runs 1
if [ "$(wc -l < "$FAKE_DIR/ran" 2>/dev/null | tr -d ' ')" = "$ndefects" ]; then
  pass "a full run reaches every defect"
else
  fail "a full run reaches every defect" "ran $(wc -l < "$FAKE_DIR/ran" 2>/dev/null) of $ndefects"
fi
if [ -f "$FAKE_DIR/stdin" ] && [ ! -s "$FAKE_DIR/stdin" ]; then
  pass "claude gets no stdin, so the catalogue cannot reach the reviewer"
else
  fail "claude gets no stdin" "stdin held: $(head -c 200 "$FAKE_DIR/stdin" 2>/dev/null)"
fi
if grep -qF 'pageCount|off-by-one|floor' "$FAKE_DIR/prompts"; then
  fail "the prompt holds no scoring pattern" "pattern found in prompt"
else
  pass "the prompt holds no scoring pattern"
fi

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
