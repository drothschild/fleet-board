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

# --- provider mode (stage-review.sh through a fake curl) ----------------------
run "$RUN" --dry-run --provider openai --model gpt-x --price-in 1 --price-out 2
assert_exit "provider_dry_run_prints_stage_review_commands: exits 0" 0
srlines="$(printf '%s\n' "$LAST_OUT" | grep -c 'stage-review.sh ')"
if [ "$ndefects" -ge 6 ] && [ "$srlines" -eq $((ndefects * 3)) ]; then
  pass "provider_dry_run_prints_stage_review_commands: one stage-review.sh command per defect per run ($srlines)"
else
  fail "provider_dry_run_prints_stage_review_commands: one stage-review.sh command per defect per run" "defects=$ndefects lines=$srlines"
fi
case "$LAST_OUT" in
  *"claude -p"*) fail "provider dry run prints no claude -p" "claude -p present" ;;
  *) pass "provider dry run prints no claude -p" ;;
esac
case "$LAST_OUT" in *"--no-post"*"openai:gpt-x"*|*"openai:gpt-x"*"--no-post"*) pass "provider dry run names openai:gpt-x and --no-post" ;; *) fail "provider dry run names openai:gpt-x and --no-post" "$LAST_OUT" ;; esac
if [ ! -e "$TMP/claude-ran" ]; then pass "provider dry run runs nothing"; else fail "provider dry run runs nothing" "claude was invoked"; fi

run "$RUN" --dry-run --provider openai --model gpt-x
assert_exit "provider_requires_prices: no prices exits 2" 2
run "$RUN" --dry-run --provider openai --model gpt-x --price-in 1
assert_exit "provider_requires_prices: only --price-in exits 2" 2
run "$RUN" --dry-run --provider openai --model gpt-x --price-in 1 --price-out abc
assert_exit "provider_requires_prices: a non-number price exits 2" 2
run "$RUN" --dry-run --provider openai --price-in 1 --price-out 2
assert_exit "provider mode without --model exits 2" 2
run "$RUN" --dry-run --provider "Bad Name" --model gpt-x --price-in 1 --price-out 2
assert_exit "a malformed provider name exits 2" 2
run "$RUN" --dry-run --provider openai --model gpt-x --price-in 1 --price-out 2 --bogus
assert_exit "provider mode: unknown flag still exits 2" 2

# Offline real run: fake curl answers with a chat completion wrapping a canned report.
mkdir -p "$TMP/bin-curl" "$TMP/prov"
ln -sf "$SCRIPT_DIR/fake-curl.sh" "$TMP/bin-curl/curl"
chat_reply() { # report-file out-file
  jq -n --rawfile t "$1" '{id:"c1",model:"gpt-x-2026",choices:[{index:0,message:{role:"assistant",content:$t},finish_reason:"stop"}],usage:{prompt_tokens:1000000,completion_tokens:500000,total_tokens:1500000}}' > "$2"
}
chat_reply "$EVAL/canned/caught.md" "$TMP/prov/caught.json"
chat_reply "$EVAL/canned/missed.md" "$TMP/prov/missed.json"
# prov_run REPLY-BODY OUT [run.sh args...]
prov_run() {
  local body="$1" out="$2"
  shift 2
  rm -f "$TMP/prov/replies" "$TMP/prov/replies.count" "$TMP/prov/curl.log"
  printf '200 %s\n' "$body" > "$TMP/prov/replies"
  LAST_OUT="$(PATH="$TMP/bin-curl:$TMP/bin:$PATH" OPENAI_API_KEY=sk-test-eval FAKE_CURL_LOG="$TMP/prov/curl.log" \
    FAKE_CURL_REPLIES="$TMP/prov/replies" bash "$RUN" --out "$out" --provider openai --model gpt-x \
    --price-in 1 --price-out 2 "$@" 2>"$TMP/err")"
  LAST_EXIT=$?
  LAST_ERR="$(cat "$TMP/err")"
}

prov_run "$TMP/prov/caught.json" "$TMP/p1" --defect off-by-one --runs 1
assert_exit "provider_verdict_from_fake_reply: a caught reply exits 0" 0
verdict_is "provider_verdict_from_fake_reply: the canned caught report is caught" caught "$TMP/p1"
if [ "$(cut -f4 "$TMP/p1/results.tsv" 2>/dev/null)" = "openai:gpt-x" ]; then pass "the model column is provider:model"; else fail "the model column is provider:model" "$(cat "$TMP/p1/results.tsv" 2>/dev/null)"; fi
if [ "$(cut -f7 "$TMP/p1/results.tsv" 2>/dev/null)" = "2.000000" ] || [ "$(cut -f7 "$TMP/p1/results.tsv" 2>/dev/null)" = "2" ]; then
  pass "cost comes from stage-review.sh (1M in at 1 + 0.5M out at 2 = 2)"
else
  fail "cost comes from stage-review.sh" "$(cat "$TMP/p1/results.tsv" 2>/dev/null)"
fi
if [ -f "$TMP/p1/provider-log/provider-spend.jsonl" ]; then pass "the ledger lands under --out"; else fail "the ledger lands under --out" "$(ls -R "$TMP/p1" | head -20)"; fi
if [ ! -e "$TMP/claude-ran" ]; then pass "provider mode never runs claude"; else fail "provider mode never runs claude" "claude was invoked"; fi
if grep -q '^DATA .*pr-paginate\|^DATA .*pageCount' "$TMP/prov/curl.log"; then pass "the request carries the PR diff"; else fail "the request carries the PR diff" "no diff text in the request"; fi
case "$LAST_OUT" in *"| off-by-one | openai:gpt-x |"*) pass "the table shows provider:model" ;; *) fail "the table shows provider:model" "$LAST_OUT" ;; esac

prov_run "$TMP/prov/missed.json" "$TMP/p2" --defect off-by-one --runs 1
assert_exit "provider: a real miss still exits 0" 0
verdict_is "provider_verdict_from_fake_reply: the canned missed report is missed" missed "$TMP/p2"

env_unset_out="$(PATH="$TMP/bin-curl:$TMP/bin:$PATH" OPENAI_API_KEY= FAKE_CURL_LOG="$TMP/prov/curl2.log" FAKE_CURL_REPLIES="$TMP/prov/replies" \
  bash "$RUN" --out "$TMP/p3" --provider openai --model gpt-x --price-in 1 --price-out 2 --defect off-by-one --runs 1 2>"$TMP/err")"
rc3=$?
if [ "$rc3" = 1 ] && [ "$(cut -f6 "$TMP/p3/results.tsv" 2>/dev/null)" = "error" ]; then
  pass "a run where stage-review.sh fails is error and exits 1"
else
  fail "a run where stage-review.sh fails is error and exits 1" "rc=$rc3 $(cat "$TMP/p3/results.tsv" 2>/dev/null)"
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
