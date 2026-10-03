#!/usr/bin/env bash
#
# Plain-bash tests for plugin-interaction-scan.sh (the stream-json transcript
# scanner for signs that another plugin or the user's CLAUDE.md derailed a
# role session). No framework, no dependencies beyond POSIX tools and jq.
#
# Usage: bash plugins/fleet-board/tests/test-plugin-interaction-scan.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/plugin-interaction-scan.sh"
TRANSCRIPTS="${SCRIPT_DIR}/../fixtures/transcripts"
CLEAN="$TRANSCRIPTS/role-clean.jsonl"
DERAILED="$TRANSCRIPTS/role-derailed.jsonl"

PASS=0
FAIL=0
LAST_OUT=""
LAST_ERR=""
LAST_EXIT=0

TAB="$(printf '\t')"

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

assert_exit() {
  if [ "$LAST_EXIT" = "$2" ]; then pass "$1"; else fail "$1" "expected exit $2, got $LAST_EXIT (stderr: $LAST_ERR)"; fi
}

assert_stdout_exact() {
  if [ "$LAST_OUT" = "$2" ]; then pass "$1"; else fail "$1" "expected stdout: '$2', got: '$LAST_OUT'"; fi
}

assert_stdout_contains() {
  case "$LAST_OUT" in
    *"$2"*) pass "$1" ;;
    *) fail "$1" "expected to find '$2' in stdout, got: '$LAST_OUT'" ;;
  esac
}

assert_stderr_contains() {
  case "$LAST_ERR" in
    *"$2"*) pass "$1" ;;
    *) fail "$1" "expected to find '$2' in stderr, got: '$LAST_ERR'" ;;
  esac
}

run_check() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  bash "$SCRIPT" "$@" > "$tmpdir/out.txt" 2> "$tmpdir/err.txt"
  LAST_EXIT=$?
  LAST_OUT="$(cat "$tmpdir/out.txt")"
  LAST_ERR="$(cat "$tmpdir/err.txt")"
  rm -rf "$tmpdir"
}

# field NAME: the NAME=value field of the single stdout line (value only)
field() {
  printf '%s\n' "$LAST_OUT" | tr '\t' '\n' | awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }'
}

assert_field() {
  local got
  got="$(field "$2")"
  if [ "$got" = "$3" ]; then pass "$1"; else fail "$1" "expected $2=$3, got $2='$got' (line: '$LAST_OUT')"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# bash_event ID PARENT COMMAND: one assistant event holding a Bash tool_use
bash_event() {
  jq -cn --arg id "$1" --arg p "$2" --arg c "$3" '
    {type:"assistant",
     message:{role:"assistant", content:[{type:"tool_use", id:$id, name:"Bash", input:{command:$c}}]},
     parent_tool_use_id:(if $p == "" then null else $p end)}'
}

echo "plugin-interaction-scan"

# --- usage -----------------------------------------------------------------
echo "usage"
run_check
assert_exit "no arguments: exit 2" 2
assert_stderr_contains "no arguments: usage on stderr" "usage"

# --- clean fixture ---------------------------------------------------------
echo "clean transcript"
run_check "$CLEAN"
assert_exit "clean: exit 0" 0
assert_stdout_exact "clean: whole line" \
  "${CLEAN}${TAB}foreign_skill=0${TAB}foreign_agent=0${TAB}ask_user=0${TAB}pr_create=0${TAB}browser=0${TAB}plugins=fleet-board,agents-md,telemetry"

# --- derailed fixture ------------------------------------------------------
echo "derailed transcript"
run_check "$DERAILED"
assert_exit "derailed: exit 0" 0
assert_field "derailed: foreign skill (top level) counted, fleet-board skill not" foreign_skill 1
assert_field "derailed: foreign Agent dispatch counted, fleet-board:implementor dispatch not" foreign_agent 1
assert_field "derailed: AskUserQuestion inside the subagent counted" ask_user 1
assert_field "derailed: gh pr create inside the subagent counted; Agent prompt, hook text and tool_result text not" pr_create 1
assert_field "derailed: --web inside the subagent counted; Agent prompt not" browser 1
assert_field "derailed: plugins from the init event" plugins "fleet-board,workflow-helpers,agents-md"
assert_stdout_exact "derailed: whole line" \
  "${DERAILED}${TAB}foreign_skill=1${TAB}foreign_agent=1${TAB}ask_user=1${TAB}pr_create=1${TAB}browser=1${TAB}plugins=fleet-board,workflow-helpers,agents-md"

# --- several files: one line each, in argument order -----------------------
echo "several files"
run_check "$DERAILED" "$CLEAN"
assert_exit "two files: exit 0" 0
lines="$(printf '%s\n' "$LAST_OUT" | wc -l | tr -d ' ')"
if [ "$lines" = "2" ]; then pass "two files: two lines"; else fail "two files: two lines" "got $lines lines: '$LAST_OUT'"; fi
first="$(printf '%s\n' "$LAST_OUT" | head -1 | cut -f1)"
second="$(printf '%s\n' "$LAST_OUT" | sed -n 2p | cut -f1)"
if [ "$first" = "$DERAILED" ] && [ "$second" = "$CLEAN" ]; then
  pass "two files: argument order kept"
else
  fail "two files: argument order kept" "got '$first' then '$second'"
fi

# --- browser patterns ------------------------------------------------------
echo "browser patterns"
{
  bash_event t1 "" "open https://github.com/owner/repo/pull/1"
  bash_event t2 "" "cd /w && xdg-open https://example.com"
  bash_event t3 "" "gh repo view --web"
  bash_event t4 "" "cd /w && open report.html"
  bash_event t5 "" "reopen=1; echo open the file; git log --oneline"
  bash_event t6 "" "grep -r 'open ' src"
  bash_event t7 "" "gh browse 12 --repo owner/sandbox"
  bash_event t8 "" "cd /w && gh browse"
  bash_event t9 "" "gh api repos/o/r/hooks --webhook-url https://x.invalid --website"
  bash_event t10 "" "gh pr view 3 --web; echo done"
  bash_event t11 "" "echo gh browsers are fine"
} > "$WORK/browser.jsonl"
run_check "$WORK/browser.jsonl"
assert_exit "browser: exit 0" 0
assert_field "browser: ^open, xdg-open, --web (x2, whole flag), && open, gh browse (x2) counted; 'echo open', 'reopen', quoted 'open ', --webhook-url, --website, 'gh browsers' not" browser 7
assert_field "browser: no init event gives an empty plugins list" plugins ""

# --- foreign Agent dispatches ----------------------------------------------
echo "foreign agents"
# agent_event ID PARENT SUBAGENT_TYPE: an Agent tool_use ("-" = no subagent_type)
agent_event() {
  jq -cn --arg id "$1" --arg p "$2" --arg t "$3" '
    {type:"assistant",
     message:{role:"assistant", content:[{type:"tool_use", id:$id, name:"Agent",
       input:({description:"d", prompt:"p"} + (if $t == "-" then {} else {subagent_type:$t} end))}]},
     parent_tool_use_id:(if $p == "" then null else $p end)}'
}
{
  agent_event a1 "" "fleet-board:implementor"
  agent_event a2 "" "fleet-board:reviewer"
  agent_event a3 "" "general-purpose"
  agent_event a4 "" "-"
  agent_event a5 "a1" "workflow-helpers:planner"
  agent_event a6 "" "fleet-boardx:implementor"
} > "$WORK/agents.jsonl"
run_check "$WORK/agents.jsonl"
assert_exit "agents: exit 0" 0
assert_field "agents: general-purpose, no subagent_type, a nested foreign type and a look-alike prefix counted; fleet-board: not" foreign_agent 4
assert_field "agents: an Agent call is not a Skill call" foreign_skill 0

# --- one command with two signals counts once per signal -------------------
echo "one command, two signals"
bash_event t1 "p1" "gh pr create --draft --fill && gh pr view --web && gh pr create --fill" > "$WORK/two.jsonl"
run_check "$WORK/two.jsonl"
assert_field "two signals: pr_create counted once per command" pr_create 1
assert_field "two signals: browser counted once per command" browser 1

# --- robustness: non-object lines and a truncated last line ----------------
echo "robustness"
{
  printf '%s\n' '"a JSON string, not an event"'
  sed -n 1p "$DERAILED"
  bash_event t1 "" "gh pr create --draft"
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"gh pr'
} > "$WORK/truncated.jsonl"
run_check "$WORK/truncated.jsonl"
assert_exit "truncated: exit 0" 0
assert_field "truncated: the complete events still counted" pr_create 1
assert_field "truncated: plugins still read" plugins "fleet-board,workflow-helpers,agents-md"

# --- several init events: the first one is reported ------------------------
echo "several init events"
{
  sed -n 1p "$CLEAN"
  sed -n 2p "$CLEAN"
  sed -n 1p "$DERAILED"
} > "$WORK/inits.jsonl"
run_check "$WORK/inits.jsonl"
assert_field "inits: plugins from the first init event" plugins "fleet-board,agents-md,telemetry"

# --- missing file ----------------------------------------------------------
echo "missing file"
run_check "$WORK/nope.jsonl" "$CLEAN"
assert_exit "missing file: exit 1" 1
assert_stderr_contains "missing file: named on stderr" "$WORK/nope.jsonl"
assert_stdout_contains "missing file: the other file is still scanned" "${CLEAN}${TAB}foreign_skill=0"

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
