#!/usr/bin/env bash
# chat.sh - OpenAI-compatible Chat Completions adapter.
#
# Usage:
#   chat.sh --base-url <url> --key-env <NAME|-> --model <id> --max-tokens <n> \
#           --max-tokens-param <max_tokens|max_completion_tokens> --timeout <s>
#   stdin: {"messages":[{"role":...,"content":...}, ...]}
#   stdout: {"text","finish_reason","input_tokens","output_tokens","model"}
#
# The key is read from the environment variable named by --key-env ('-' sends
# no Authorization header, for a loopback server). It reaches curl only through
# a mode-600 header file (-H @file) in a private temp dir that a trap removes;
# it never appears in argv, stdout or stderr. Provider text printed to stderr
# has the key replaced by [redacted] and is cut to 300 characters.
# Retries: HTTP 429 and 5xx only, 1 try + 2 retries, honouring Retry-After
# seconds (capped at 60) through ${FB_SLEEP:-sleep}.
#
# Exit codes:
#   0 - reply printed
#   1 - HTTP or transport failure (stderr: "provider: <reason>")
#   2 - usage error
#   3 - --key-env names an unset or empty variable (no curl call)

set -eu
unset CDPATH

die() {
  printf 'provider: %s\n' "$1" >&2
  exit "${2:-1}"
}

usage() {
  printf 'chat.sh: %s\n' "$1" >&2
  exit 2
}

BASE_URL="" KEY_ENV="" MODEL="" MAX_TOKENS="" MAX_PARAM="" TIMEOUT=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage "missing value for $1"
  case "$1" in
    --base-url) BASE_URL="$2" ;;
    --key-env) KEY_ENV="$2" ;;
    --model) MODEL="$2" ;;
    --max-tokens) MAX_TOKENS="$2" ;;
    --max-tokens-param) MAX_PARAM="$2" ;;
    --timeout) TIMEOUT="$2" ;;
    *) usage "unknown argument: $1" ;;
  esac
  shift 2
done
[ -n "$BASE_URL" ] && [ -n "$KEY_ENV" ] && [ -n "$MODEL" ] && [ -n "$MAX_TOKENS" ] \
  && [ -n "$MAX_PARAM" ] && [ -n "$TIMEOUT" ] || usage "all of --base-url --key-env --model --max-tokens --max-tokens-param --timeout are required"
case "$MAX_TOKENS" in *[!0-9]*) usage "--max-tokens must be an integer" ;; esac
case "$TIMEOUT" in *[!0-9]*) usage "--timeout must be an integer" ;; esac
case "$MAX_PARAM" in max_tokens|max_completion_tokens) ;; *) usage "--max-tokens-param must be max_tokens or max_completion_tokens" ;; esac
if [ "$KEY_ENV" != "-" ]; then
  printf '%s' "$KEY_ENV" | grep -Eq '^[A-Z_][A-Z0-9_]*$' || usage "--key-env must match ^[A-Z_][A-Z0-9_]*$ or be -"
fi

REQ_IN="$(cat)"
REQUEST="$(printf '%s' "$REQ_IN" | jq -ce --arg m "$MODEL" --arg p "$MAX_PARAM" --argjson n "$MAX_TOKENS" \
  'if (.messages | type) == "array" then {model: $m, messages: .messages, ($p): $n} else error("no messages") end' 2>/dev/null)" \
  || usage 'stdin must be {"messages":[...]}'

KEY=""
if [ "$KEY_ENV" != "-" ]; then
  KEY="${!KEY_ENV:-}"
  [ -n "$KEY" ] || die "$KEY_ENV is not set" 3
fi

umask 077
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT TERM

# redact <text>: key -> [redacted] (fixed string, raw and JSON-escaped forms),
# newlines folded to spaces, cut to 300 characters.
redact() {
  local t="$1" esc
  t="$(printf '%s' "$t" | tr '\n\r' '  ')"
  if [ -n "$KEY" ]; then
    esc="$(jq -nr --arg k "$KEY" '$k | @json')"
    esc="${esc#\"}"
    esc="${esc%\"}"
    t="${t//"$KEY"/[redacted]}"
    t="${t//"$esc"/[redacted]}"
  fi
  printf '%s' "${t:0:300}"
}

printf '%s' "$REQUEST" > "$TMP/body.json"
HDR_ARGS=""
if [ -n "$KEY" ]; then
  printf 'Authorization: Bearer %s\n' "$KEY" > "$TMP/auth"
  chmod 600 "$TMP/auth"
  HDR_ARGS="auth"
fi
URL="${BASE_URL%/}/chat/completions"

attempt=0
while :; do
  attempt=$((attempt + 1))
  rc=0
  if [ -n "$HDR_ARGS" ]; then
    code="$(curl -sS --max-time "$TIMEOUT" -w '%{http_code}' -D "$TMP/resp.hdr" -o "$TMP/resp.json" \
      -H "@$TMP/auth" -H 'Content-Type: application/json' --data-binary "@$TMP/body.json" "$URL" 2> "$TMP/curl.err")" || rc=$?
  else
    code="$(curl -sS --max-time "$TIMEOUT" -w '%{http_code}' -D "$TMP/resp.hdr" -o "$TMP/resp.json" \
      -H 'Content-Type: application/json' --data-binary "@$TMP/body.json" "$URL" 2> "$TMP/curl.err")" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    die "curl failed (exit $rc): $(redact "$(cat "$TMP/curl.err")")" 1
  fi

  case "$code" in
    2??) break ;;
    429|5??)
      if [ "$attempt" -ge 3 ]; then
        die "HTTP $code after $attempt attempts" 1
      fi
      wait_s="$attempt"
      ra="$(grep -i '^retry-after:' "$TMP/resp.hdr" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r ' || true)"
      case "$ra" in
        ''|*[!0-9]*) ;;
        *) wait_s="$ra" ;;
      esac
      [ "$wait_s" -le 60 ] || wait_s=60
      ${FB_SLEEP:-sleep} "$wait_s"
      ;;
    *)
      msg="$(jq -r '.error.message? // .error? // empty | if type == "string" then . else tojson end' "$TMP/resp.json" 2>/dev/null || true)"
      [ -n "$msg" ] || msg="$(cat "$TMP/resp.json")"
      die "HTTP $code: $(redact "$msg")" 1
      ;;
  esac
done

jq -ce --arg m "$MODEL" '
  if (.choices | type) == "array" and (.choices | length) > 0 then
    { text: (.choices[0].message.content // "" | if type == "string" then . else tojson end),
      finish_reason: (.choices[0].finish_reason // ""),
      input_tokens: (.usage.prompt_tokens // 0),
      output_tokens: (.usage.completion_tokens // 0),
      model: (.model // $m) }
  else error("no choices") end' "$TMP/resp.json" 2> /dev/null \
  || die "unparseable reply: $(redact "$(cat "$TMP/resp.json")")" 1
