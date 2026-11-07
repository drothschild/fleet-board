#!/usr/bin/env bash
#
# Plain-bash tests for providers/chat.sh (offline: a fake curl on PATH).
# No framework, no dependencies beyond POSIX tools and jq.
#
# Usage: bash plugins/fleet-board/tests/test-providers.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CHAT="${SCRIPT_DIR}/../scripts/providers/chat.sh"
FIX="${SCRIPT_DIR}/../fixtures/providers"
FAKE_CURL="${SCRIPT_DIR}/fake-curl.sh"

PASS=0
FAIL=0
LAST_OUT=""
LAST_ERR=""
LAST_EXIT=0

if [ -x /bin/bash ]; then BASH_EXE="/bin/bash"; else BASH_EXE="bash"; fi

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}
assert_exit() {
  if [ "$LAST_EXIT" = "$2" ]; then pass "$1"; else fail "$1" "expected exit $2, got $LAST_EXIT (stderr: $LAST_ERR)"; fi
}
assert_contains() { # name haystack needle
  case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "expected to find '$3' in: '$2'" ;; esac
}
assert_lacks() { # name haystack needle
  case "$2" in *"$3"*) fail "$1" "did not expect '$3' in: '$2'" ;; *) pass "$1" ;; esac
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
ln -s "$FAKE_CURL" "$WORK/bin/curl"
cat > "$WORK/sleep.sh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$SLEEP_LOG"
EOF
chmod +x "$WORK/sleep.sh"
# jq shim: records every argv, then runs the real jq
REAL_JQ="$(command -v jq)"
{
  printf '%s\n' '#!/bin/sh'
  printf '%s\n' 'printf "%s\n" "$@" >> "$JQ_ARGV_LOG"'
  printf 'exec "%s" "$@"\n' "$REAL_JQ"
} > "$WORK/bin/jq"
chmod +x "$WORK/bin/jq"

export TEST_KEY=sk-test-123
REQ='{"messages":[{"role":"system","content":"be brief"},{"role":"user","content":"review this"}]}'

# setup <replies-line>...  (fresh state per case)
setup() {
  rm -rf "$WORK/case"
  mkdir -p "$WORK/case/tmp"
  : > "$WORK/case/curl.log"
  : > "$WORK/case/sleep.log"
  : > "$WORK/case/replies"
  : > "$WORK/case/jq.log"
  local r
  for r in "$@"; do printf '%s\n' "$r" >> "$WORK/case/replies"; done
  cp "$FIX"/*.json "$FIX"/*.err "$WORK/case/"
}

# chat [args...]  (stdin: $REQ unless CHAT_IN is set)
chat() {
  local in="${CHAT_IN-$REQ}"
  printf '%s' "$in" | env PATH="$WORK/bin:$PATH" \
    FAKE_CURL_LOG="$WORK/case/curl.log" FAKE_CURL_REPLIES="$WORK/case/replies" \
    TMPDIR="$WORK/case/tmp" JQ_ARGV_LOG="$WORK/case/jq.log" FB_SLEEP="$WORK/sleep.sh" SLEEP_LOG="$WORK/case/sleep.log" \
    "$BASH_EXE" "$CHAT" "$@" > "$WORK/case/out" 2> "$WORK/case/err"
  LAST_EXIT=$?
  LAST_OUT="$(cat "$WORK/case/out")"
  LAST_ERR="$(cat "$WORK/case/err")"
}

BASE=(--base-url https://api.example.test/v1 --model gpt-test --max-tokens 800 --max-tokens-param max_completion_tokens --timeout 30)

calls() { grep -c '^CALL ' "$WORK/case/curl.log"; }
curl_log() { cat "$WORK/case/curl.log"; }
tmp_left() { ls -A "$WORK/case/tmp" | wc -l | tr -d ' '; }

echo "Test: providers/chat.sh"
echo ""

# ok_reply_is_normalized
setup "200 ok.json"

chat "${BASE[@]}" --key-env TEST_KEY
assert_exit "ok_reply_is_normalized: exit 0" 0
assert_eq "ok_reply_is_normalized: exactly the five keys" \
  "$(printf '%s' "$LAST_OUT" | jq -c 'keys')" '["finish_reason","input_tokens","model","output_tokens","text"]'
assert_eq "ok_reply_is_normalized: values" \
  "$(printf '%s' "$LAST_OUT" | jq -c '[.text,.finish_reason,.input_tokens,.output_tokens,.model]')" \
  '["Status: clean","stop",1234,56,"gpt-test-2026"]'
assert_contains "ok_reply_is_normalized: url" "$(curl_log)" "ARG https://api.example.test/v1/chat/completions"

# request body shape
assert_contains "request body carries messages and model" "$(curl_log)" 'DATA {"model":"gpt-test"'

# key_never_in_argv
setup "200 ok.json"
chat "${BASE[@]}" --key-env TEST_KEY
argv_lines="$(grep '^ARG ' "$WORK/case/curl.log")"
assert_lacks "key_never_in_argv: no argv element holds the key" "$argv_lines" "sk-test-123"
assert_eq "key_never_in_argv: header goes through -H @file" "$(printf "%s\n" "$argv_lines" | grep -c "^ARG @.*/auth$")" "1"
assert_contains "key_never_in_argv: header file holds the bearer line" "$(curl_log)" "DATA Authorization: Bearer sk-test-123"
hdr_mode="$(grep '^MODE ' "$WORK/case/curl.log" | head -1 | awk '{print $3}')"
assert_eq "key_never_in_argv: header file mode is 600" "$hdr_mode" "600"

# temp_files_removed
setup "200 ok.json"
chat "${BASE[@]}" --key-env TEST_KEY
assert_eq "temp_files_removed: after exit 0" "$(tmp_left)" "0"
setup "500 500.json" "500 500.json" "500 500.json"
chat "${BASE[@]}" --key-env TEST_KEY
assert_exit "temp_files_removed: failing run exits 1" 1
assert_eq "temp_files_removed: after exit 1" "$(tmp_left)" "0"

# error_body_echoing_key_is_redacted
setup "401 401-echoing-key.json"
chat "${BASE[@]}" --key-env TEST_KEY
assert_exit "error_body_echoing_key_is_redacted: exit 1" 1
assert_contains "error_body_echoing_key_is_redacted: stderr says [redacted]" "$LAST_ERR" "[redacted]"
assert_lacks "error_body_echoing_key_is_redacted: stderr lacks the key" "$LAST_ERR" "sk-test-123"
assert_contains "error_body_echoing_key_is_redacted: prefix" "$LAST_ERR" "provider: HTTP 401"
assert_eq "error_body_echoing_key_is_redacted: no retry on 401" "$(calls)" "1"

# stderr truncated to 300 characters of provider text
setup "400 long.json"
printf '{"error":{"message":"%s"}}\n' "$(printf 'x%.0s' $(seq 1 600))" > "$WORK/case/long.json"
chat "${BASE[@]}" --key-env TEST_KEY
assert_exit "long error body: exit 1" 1
if [ "${#LAST_ERR}" -le 330 ]; then pass "long error body: stderr truncated"; else fail "long error body: stderr truncated" "length ${#LAST_ERR}"; fi

# retries_429_then_succeeds
setup "429 429.json 2" "200 ok.json"
chat "${BASE[@]}" --key-env TEST_KEY
assert_exit "retries_429_then_succeeds: exit 0" 0
assert_eq "retries_429_then_succeeds: two calls" "$(calls)" "2"
assert_eq "retries_429_then_succeeds: Retry-After honoured" "$(head -1 "$WORK/case/sleep.log")" "2"

# retry_cap
setup "500 500.json" "500 500.json" "500 500.json" "200 ok.json"
chat "${BASE[@]}" --key-env TEST_KEY
assert_exit "retry_cap: exit 1" 1
assert_eq "retry_cap: three calls" "$(calls)" "3"
assert_contains "retry_cap: message" "$LAST_ERR" "provider: HTTP 500 after 3 attempts"

# retry_after_capped_at_60
setup "429 429.json 900" "200 ok.json"
chat "${BASE[@]}" --key-env TEST_KEY
assert_exit "retry_after_capped_at_60: exit 0" 0
assert_eq "retry_after_capped_at_60: sleep 60" "$(head -1 "$WORK/case/sleep.log")" "60"

# missing_key_env_makes_no_call
setup "200 ok.json"
chat "${BASE[@]}" --key-env NOPE_KEY_UNSET_XYZ
assert_exit "missing_key_env_makes_no_call: exit 3" 3
assert_contains "missing_key_env_makes_no_call: stderr" "$LAST_ERR" "provider: NOPE_KEY_UNSET_XYZ is not set"
assert_eq "missing_key_env_makes_no_call: no curl call" "$(calls)" "0"
EMPTY_KEY="" chat "${BASE[@]}" --key-env EMPTY_KEY
assert_exit "missing_key_env_makes_no_call: empty value exits 3" 3

# loopback_without_key
setup "200 ok.json"
chat --base-url http://localhost:11434/v1 --model m --max-tokens 10 --max-tokens-param max_tokens --timeout 30 --key-env -
assert_exit "loopback_without_key: exit 0" 0
assert_lacks "loopback_without_key: no Authorization header" "$(curl_log)" "Authorization"
assert_eq "loopback_without_key: no header file" "$(curl_log | grep -c "^ARG @.*/auth$")" "0"

# base_url backstop: userinfo and non-loopback http never reach curl
for u in 'http://localhost:@evil.example/v1' 'http://127.0.0.1:1@evil.example/v1' 'http://[::1]:x@evil.example/v1' 'http://localhost:123@example.com/v1' 'https://user@api.example.test/v1'; do
  setup "200 ok.json"
  chat --base-url "$u" --model m --max-tokens 10 --max-tokens-param max_tokens --timeout 30 --key-env TEST_KEY
  assert_exit "base_url_userinfo $u: exit 2" 2
  assert_eq "base_url_userinfo $u: stderr" "$LAST_ERR" "provider: base_url must not contain userinfo"
  assert_eq "base_url_userinfo $u: no curl call" "$(calls)" "0"
done
for u in 'http://llm.example.test/v1' 'http://localhost.evil.example/v1' 'http://localhost:abc/v1'; do
  setup "200 ok.json"
  chat --base-url "$u" --model m --max-tokens 10 --max-tokens-param max_tokens --timeout 30 --key-env TEST_KEY
  assert_exit "base_url_not_loopback $u: exit 2" 2
  assert_eq "base_url_not_loopback $u: stderr" "$LAST_ERR" "provider: base_url must start with https:// or a loopback http:// address"
  assert_eq "base_url_not_loopback $u: no curl call" "$(calls)" "0"
done
# grep is line-based: a newline must not let a loopback first line vouch for the rest
setup "200 ok.json"
chat --base-url "$(printf 'http://localhost\nevil.example')" --model m --max-tokens 10 --max-tokens-param max_tokens --timeout 30 --key-env -
assert_exit "base_url_control_char: exit 2" 2
assert_eq "base_url_control_char: no curl call" "$(calls)" "0"
for u in 'http://localhost:11434/v1' 'http://[::1]:8080/' 'http://127.0.0.1/v1'; do
  setup "200 ok.json"
  chat --base-url "$u" --model m --max-tokens 10 --max-tokens-param max_tokens --timeout 30 --key-env -
  assert_exit "base_url_loopback $u: accepted" 0
done

# max_tokens_param_used
setup "200 ok.json"
chat "${BASE[@]}" --key-env TEST_KEY
data_line="$(grep '^DATA {' "$WORK/case/curl.log" | head -1 | sed 's/^DATA //')"
assert_eq "max_tokens_param_used: max_completion_tokens set" "$(printf '%s' "$data_line" | jq -c '.max_completion_tokens')" "800"
assert_eq "max_tokens_param_used: max_tokens absent" "$(printf '%s' "$data_line" | jq -c 'has("max_tokens")')" "false"
setup "200 ok.json"
chat --base-url https://api.example.test/v1 --model m --max-tokens 321 --max-tokens-param max_tokens --timeout 30 --key-env TEST_KEY
data_line="$(grep '^DATA {' "$WORK/case/curl.log" | head -1 | sed 's/^DATA //')"
assert_eq "max_tokens_param_used: max_tokens set" "$(printf '%s' "$data_line" | jq -c '.max_tokens')" "321"
assert_eq "max_tokens_param_used: max_completion_tokens absent" "$(printf '%s' "$data_line" | jq -c 'has("max_completion_tokens")')" "false"

# stdout_never_holds_key
setup "401 401-echoing-key.json"
chat "${BASE[@]}" --key-env TEST_KEY
assert_lacks "stdout_never_holds_key: failing run" "$LAST_OUT" "sk-test-123"
setup "200 ok.json"
chat "${BASE[@]}" --key-env TEST_KEY
assert_lacks "stdout_never_holds_key: ok run" "$LAST_OUT" "sk-test-123"

# truncated and empty replies are normalized, not rejected here
setup "200 length.json"
chat "${BASE[@]}" --key-env TEST_KEY
assert_eq "length reply: finish_reason passed through" "$(printf '%s' "$LAST_OUT" | jq -r .finish_reason)" "length"
setup "200 empty-content.json"
chat "${BASE[@]}" --key-env TEST_KEY
assert_eq "empty reply: empty text passed through" "$(printf '%s' "$LAST_OUT" | jq -r .text)" ""

# usage errors
setup "200 ok.json"
chat --model m
assert_exit "usage: missing flags exit 2" 2
CHAT_IN='not json' chat "${BASE[@]}" --key-env TEST_KEY
assert_exit "usage: bad stdin exit 2" 2
assert_eq "usage: bad stdin makes no call" "$(calls)" "0"
chat "${BASE[@]}" --key-env 'bad name'
assert_exit "usage: bad key-env name exit 2" 2

# key_never_in_jq_argv: no jq invocation, on any path, sees the key in argv
setup "401 401-echoing-key.json"
chat "${BASE[@]}" --key-env TEST_KEY
assert_exit "key_never_in_jq_argv: 401 path exit 1" 1
assert_contains "key_never_in_jq_argv: shim saw jq calls" "$(cat "$WORK/case/jq.log")" "--arg"
assert_lacks "key_never_in_jq_argv: 401 path" "$(cat "$WORK/case/jq.log")" "sk-test-123"
setup "200 ok.json"
chat "${BASE[@]}" --key-env TEST_KEY
assert_lacks "key_never_in_jq_argv: ok path" "$(cat "$WORK/case/jq.log")" "sk-test-123"

# reply_without_usage_is_a_failure
setup "200 no-usage.json"
chat "${BASE[@]}" --key-env TEST_KEY
assert_exit "reply_without_usage_is_a_failure: exit 1" 1
assert_eq "reply_without_usage_is_a_failure: stderr" "$LAST_ERR" "provider: reply has no usage"
assert_eq "reply_without_usage_is_a_failure: nothing on stdout" "$LAST_OUT" ""
assert_eq "reply_without_usage_is_a_failure: temp removed" "$(tmp_left)" "0"

# usage counts must be non-negative integers (a fraction would abort the
# caller's $((...)); a negative one would lower the recorded spend)
for f in usage-fraction usage-negative usage-string; do
  setup "200 $f.json"
  chat "${BASE[@]}" --key-env TEST_KEY
  assert_exit "$f: exit 1" 1
  assert_eq "$f: stderr" "$LAST_ERR" "provider: reply has no usage"
  assert_eq "$f: nothing on stdout" "$LAST_OUT" ""
done

# key_with_control_character: refused before any file is written (no header injection)
for k in "$(printf 'sk-a\r\nX-Evil: 1')" "$(printf 'sk-a\nb')" "$(printf 'sk-a\tb')"; do
  setup "200 ok.json"
  CTRL_KEY="$k" chat "${BASE[@]}" --key-env CTRL_KEY
  assert_exit "key_with_control_character: exit 3" 3
  assert_eq "key_with_control_character: stderr" "$LAST_ERR" "provider: CTRL_KEY holds a control character"
  assert_eq "key_with_control_character: no curl call" "$(calls)" "0"
  assert_eq "key_with_control_character: no temp dir" "$(tmp_left)" "0"
done

# curl_ignores_curlrc_and_caps_size: -q first, --max-filesize set
setup "200 ok.json"
chat "${BASE[@]}" --key-env TEST_KEY
assert_eq "curl -q is the first argument" "$(grep '^ARG ' "$WORK/case/curl.log" | head -1)" "ARG -q"
assert_contains "curl --max-filesize 20971520" "$(curl_log)" "$(printf 'ARG --max-filesize\nARG 20971520')"
setup "200 ok.json"
chat --base-url http://localhost:11434/v1 --model m --max-tokens 10 --max-tokens-param max_tokens --timeout 30 --key-env -
assert_eq "curl -q first (no key)" "$(grep '^ARG ' "$WORK/case/curl.log" | head -1)" "ARG -q"
assert_contains "curl --max-filesize (no key)" "$(curl_log)" "$(printf 'ARG --max-filesize\nARG 20971520')"

# transport_failure: not retried, one stderr line, key redacted
setup "exit 28 curl-timeout.err" "200 ok.json"
chat "${BASE[@]}" --key-env TEST_KEY
assert_exit "transport_failure: exit 1" 1
assert_eq "transport_failure: one call, no retry" "$(calls)" "1"
assert_eq "transport_failure: one stderr line" "$(printf '%s\n' "$LAST_ERR" | wc -l | tr -d ' ')" "1"
case "$LAST_ERR" in "provider: curl failed (exit 28)"*) pass "transport_failure: prefix" ;; *) fail "transport_failure: prefix" "$LAST_ERR" ;; esac
assert_contains "transport_failure: redacted" "$LAST_ERR" "[redacted]"
assert_lacks "transport_failure: key absent" "$LAST_ERR" "sk-test-123"
assert_eq "transport_failure: temp removed" "$(tmp_left)" "0"
assert_eq "transport_failure: nothing on stdout" "$LAST_OUT" ""

# ---- command mode (codex): a program on PATH instead of an HTTP call ----
FAKE_CODEX_DIR="$WORK/codexbin"
mkdir -p "$FAKE_CODEX_DIR"
cat > "$FAKE_CODEX_DIR/codex" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$FAKE_CODEX_ARGV"
cat > "$FAKE_CODEX_STDIN"
pwd -P > "$FAKE_CODEX_CWD"
if [ -n "${FAKE_CODEX_ERR:-}" ]; then printf '%s\n' "$FAKE_CODEX_ERR" >&2; fi
[ -z "${FAKE_CODEX_OUT:-}" ] || printf '%s' "$FAKE_CODEX_OUT"
exit "${FAKE_CODEX_EXIT:-0}"
EOF
chmod +x "$FAKE_CODEX_DIR/codex"
cat > "$FAKE_CODEX_DIR/slow" <<'EOF'
#!/bin/sh
sleep 5
printf 'late'
EOF
chmod +x "$FAKE_CODEX_DIR/slow"
CODEX_CMD='codex exec --skip-git-repo-check -s read-only -m {model}'
# codex_chat [chat.sh args...]: env FAKE_CODEX_OUT/ERR/EXIT steer the fake
codex_chat() {
  : > "$WORK/case/codex.argv"; : > "$WORK/case/codex.stdin"; : > "$WORK/case/codex.cwd"
  printf '%s' "$REQ" | env PATH="$FAKE_CODEX_DIR:$WORK/bin:$PATH" \
    FAKE_CODEX_ARGV="$WORK/case/codex.argv" FAKE_CODEX_STDIN="$WORK/case/codex.stdin" FAKE_CODEX_CWD="$WORK/case/codex.cwd" \
    FAKE_CODEX_OUT="${FAKE_CODEX_OUT-}" FAKE_CODEX_ERR="${FAKE_CODEX_ERR-}" FAKE_CODEX_EXIT="${FAKE_CODEX_EXIT-0}" \
    "$BASH_EXE" "$CHAT" --command "$CODEX_CMD" --model gpt-6-astra --timeout 30 "$@" > "$WORK/case/out" 2> "$WORK/case/err"
  LAST_EXIT=$?
  LAST_OUT="$(cat "$WORK/case/out")"
  LAST_ERR="$(cat "$WORK/case/err")"
}

# command_reply_is_normalized
setup "200 ok.json"
FAKE_CODEX_OUT='Status: clean' FAKE_CODEX_ERR='' FAKE_CODEX_EXIT=0
codex_chat
assert_exit "command_reply_is_normalized: exit 0" 0
assert_eq "command_reply_is_normalized: json" "$LAST_OUT" \
  '{"text":"Status: clean","finish_reason":"stop","input_tokens":null,"output_tokens":null,"model":"gpt-6-astra"}'
assert_contains "command_reply_is_normalized: -m model in argv" "$(cat "$WORK/case/codex.argv")" "$(printf -- '-m\ngpt-6-astra')"
assert_eq "command_reply_is_normalized: stdin is system then user" "$(cat "$WORK/case/codex.stdin")" "$(printf 'be brief\n\nreview this')"
assert_eq "command_reply_is_normalized: no curl call" "$(calls)" "0"
assert_eq "command_reply_is_normalized: cwd is the repo root" "$(cat "$WORK/case/codex.cwd")" "$(cd "$SCRIPT_DIR/../../.." && pwd -P)"

# command_failure_exits_1_with_stderr
FAKE_CODEX_OUT='partial' FAKE_CODEX_ERR='codex: not logged in' FAKE_CODEX_EXIT=1
codex_chat
assert_exit "command_failure: exit 1" 1
assert_contains "command_failure: stderr text" "$LAST_ERR" "codex: not logged in"
assert_eq "command_failure: nothing on stdout" "$LAST_OUT" ""

# command_empty_reply_exits_1
FAKE_CODEX_OUT='' FAKE_CODEX_ERR='' FAKE_CODEX_EXIT=0
codex_chat
assert_exit "command_empty: exit 1" 1
assert_contains "command_empty: message" "$LAST_ERR" "empty reply"

# command_timeout_applies
CODEX_CMD='slow'
FAKE_CODEX_OUT='' FAKE_CODEX_ERR='' FAKE_CODEX_EXIT=0
codex_chat --timeout 1
CODEX_CMD='codex exec --skip-git-repo-check -s read-only -m {model}'
assert_exit "command_timeout: exit 1" 1
assert_contains "command_timeout: message" "$LAST_ERR" "timed out"

review_dir="$WORK/review"
quoted_dir="$WORK/a b'c"
mkdir -p "$review_dir" "$quoted_dir"
CODEX_CMD='codex {dir}'
FAKE_CODEX_OUT='review'
codex_chat --dir "$review_dir"
assert_eq "--dir sets cwd" "$(cat "$WORK/case/codex.cwd")" "$(cd "$review_dir" && pwd -P)"
assert_eq "--dir substitutes the path" "$(cat "$WORK/case/codex.argv")" "$review_dir"
codex_chat --dir "$quoted_dir"
assert_eq "--dir preserves spaces and quotes" "$(cat "$WORK/case/codex.argv")" "$quoted_dir"
chat "${BASE[@]}" --key-env TEST_KEY --dir "$review_dir"
assert_exit "--dir without --command exits 2" 2
codex_chat --dir "$WORK/missing"
assert_exit "--dir with a missing directory exits 2" 2

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
