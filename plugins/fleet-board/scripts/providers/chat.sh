#!/usr/bin/env bash
# chat.sh - OpenAI-compatible Chat Completions adapter.
#
# Usage:
#   chat.sh --base-url <url> --key-env <NAME|-> --model <id> --max-tokens <n> \
#           --max-tokens-param <max_tokens|max_completion_tokens> --timeout <s>
#   stdin: {"messages":[{"role":...,"content":...}, ...]}
#   stdout: {"text","finish_reason","input_tokens","output_tokens","model"}
#
# Command mode (--command <string> --model <id> --timeout <s>; no HTTP): the
# string runs with sh -c in the repo root, {model} replaced by --model, the
# prompt (message contents joined by a blank line) on stdin. Stdout is the
# reply, with null token counts; a non-zero exit, a timeout or an empty stdout
# exits 1. With --dir <path>, it runs in that directory and substitutes {dir}
# with the shell-quoted path. With --json-events, stdout is JSONL from
# `codex exec --json`: the reply is the text of the last agent_message item and
# the token counts come from the last turn.completed usage (null when absent).
#
# The key is read from the environment variable named by --key-env ('-' sends
# no Authorization header, for a loopback server). It reaches curl only through
# a mode-600 header file (-H @file) in a private temp dir that a trap removes;
# it never appears in argv, stdout or stderr. Provider text printed to stderr
# has the key replaced by [redacted] and is cut to 300 characters.
# Retries: HTTP 429 and 5xx only, 1 try + 2 retries, honouring Retry-After
# seconds (capped at 60) through ${FB_SLEEP:-sleep}. curl runs with -q first
# (no ~/.curlrc, which could add --trace or -k) and --max-filesize 20971520.
# usage.prompt_tokens and usage.completion_tokens must be non-negative
# integers, else the reply is refused ("provider: reply has no usage").
#
# Exit codes:
#   0 - reply printed
#   1 - HTTP or transport failure, or a reply without valid usage
#       (stderr: "provider: <reason>")
#   2 - usage error, or a --base-url with userinfo, a control character, or a
#       plain-http host that is not loopback ("provider: base_url ..."; no curl call)
#   3 - --key-env names an unset or empty variable, or one holding a control
#       character ("provider: <NAME> holds a control character"); no file is
#       written and no curl call is made

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

BASE_URL="" KEY_ENV="" MODEL="" MAX_TOKENS="" MAX_PARAM="" TIMEOUT="" COMMAND="" JSON_EVENTS=0
unset COMMAND_DIR
while [ $# -gt 0 ]; do
  if [ "$1" = --json-events ]; then JSON_EVENTS=1; shift; continue; fi
  [ $# -ge 2 ] || usage "missing value for $1"
  case "$1" in
    --base-url) BASE_URL="$2" ;;
    --key-env) KEY_ENV="$2" ;;
    --model) MODEL="$2" ;;
    --max-tokens) MAX_TOKENS="$2" ;;
    --max-tokens-param) MAX_PARAM="$2" ;;
    --timeout) TIMEOUT="$2" ;;
    --command) COMMAND="$2" ;;
    --dir) COMMAND_DIR="$2" ;;
    *) usage "unknown argument: $1" ;;
  esac
  shift 2
done
if [ -n "$COMMAND" ]; then
  if [ "${COMMAND_DIR+x}" ]; then
    [ -d "$COMMAND_DIR" ] || usage "--dir must name a directory"
  fi
  # Command mode: no HTTP; --base-url, --key-env, --max-tokens and --max-tokens-param are not used.
  [ -n "$MODEL" ] && [ -n "$TIMEOUT" ] || usage "--command needs --model and --timeout"
  [ -z "$BASE_URL" ] || usage "--command and --base-url are exclusive"
  case "$TIMEOUT" in *[!0-9]*) usage "--timeout must be an integer" ;; esac
  # {model} is substituted into a shell command line, so the model id is restricted
  printf '%s' "$MODEL" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._:/-]*$' || die "model id holds characters not allowed in a command provider" 2
  case "$COMMAND" in *[[:cntrl:]]*) die "command holds a control character" 2 ;; esac
else
  [ ! "${COMMAND_DIR+x}" ] || usage "--dir requires --command"
  [ -n "$BASE_URL" ] && [ -n "$KEY_ENV" ] && [ -n "$MODEL" ] && [ -n "$MAX_TOKENS" ] \
    && [ -n "$MAX_PARAM" ] && [ -n "$TIMEOUT" ] || usage "all of --base-url --key-env --model --max-tokens --max-tokens-param --timeout are required"
  case "$MAX_TOKENS" in *[!0-9]*) usage "--max-tokens must be an integer" ;; esac
  case "$TIMEOUT" in *[!0-9]*) usage "--timeout must be an integer" ;; esac
  case "$MAX_PARAM" in max_tokens|max_completion_tokens) ;; *) usage "--max-tokens-param must be max_tokens or max_completion_tokens" ;; esac
  # Backstop for config.sh's base_url rule: no userinfo in the authority, and a
  # plain-http host must itself be loopback (optional numeric port). grep is
  # line-based, so a control character is refused first.
  case "$BASE_URL" in *[[:cntrl:]]*) die "base_url holds a control character" 2 ;; esac
  printf '%s' "$BASE_URL" | grep -Eq '^[A-Za-z][A-Za-z0-9+.-]*://[^/?#]*@' \
    && die "base_url must not contain userinfo" 2
  printf '%s' "$BASE_URL" | grep -Eq '^(https://[^/?#]|http://(localhost|127\.0\.0\.1|\[::1\])(:[0-9]+)?(/|$))' \
    || die "base_url must start with https:// or a loopback http:// address" 2
  if [ "$KEY_ENV" != "-" ]; then
    printf '%s' "$KEY_ENV" | grep -Eq '^[A-Z_][A-Z0-9_]*$' || usage "--key-env must match ^[A-Z_][A-Z0-9_]*$ or be -"
  fi
fi
REQ_IN="$(cat)"
if [ -n "$COMMAND" ]; then
  PROMPT="$(printf '%s' "$REQ_IN" | jq -r 'if (.messages | type) == "array" then [.messages[] | (if .role == "assistant" then "Your previous reply:\n" else "" end) + (.content | if type == "string" then . else tojson end)] | join("\n\n") else error("no messages") end' 2>/dev/null)" \
    || usage 'stdin must be {"messages":[...]}'
  umask 077
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  # A compound command can leave a shell between this adapter and the provider.
  # Put the provider and watchdog in separate process groups for cancellation.
  set -m
  cpid="" wpid=""
  trap 'if [ -n "$wpid" ]; then kill -KILL -- "-$wpid" 2>/dev/null || true; fi
        if [ -n "$cpid" ]; then kill -KILL -- "-$cpid" 2>/dev/null || true; fi
        exit 130' INT TERM
  RUN="${COMMAND//\{model\}/$MODEL}"
  if [ "${COMMAND_DIR+x}" ]; then
    # Preserve an absolute argument even when the caller supplied a relative path.
    case "$COMMAND_DIR" in /*) ;; *) COMMAND_DIR="$PWD/$COMMAND_DIR" ;; esac
    QUOTED_DIR="$(jq -nr --arg dir "$COMMAND_DIR" '$dir | @sh')"
    RUN="${RUN//\{dir\}/$QUOTED_DIR}"
  else
    COMMAND_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  fi
  printf '%s' "$PROMPT" > "$TMP/prompt.txt"
  ( cd "$COMMAND_DIR" && exec sh -c "$RUN" ) < "$TMP/prompt.txt" > "$TMP/out.txt" 2> "$TMP/err.txt" &
  cpid=$!
  ( sleep "$TIMEOUT"; : > "$TMP/timedout"; kill -KILL -- "-$cpid" 2>/dev/null ) > /dev/null 2>&1 &
  wpid=$!
  rc=0
  wait "$cpid" 2>/dev/null || rc=$?
  cpid=""
  kill -KILL -- "-$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  wpid=""
  if [ -e "$TMP/timedout" ]; then
    die "command timed out after ${TIMEOUT}s" 1
  fi
  if [ "$rc" -ne 0 ]; then
    die "command failed (exit $rc): $(t="$(tr '\n\r' '  ' < "$TMP/err.txt")"; printf '%s' "${t:0:300}")" 1
  fi
  if [ "$JSON_EVENTS" -eq 1 ]; then
    jq -R 'fromjson? | objects' "$TMP/out.txt" | jq -s . > "$TMP/events.json" || die "unreadable codex events" 1
    jq -j '[.[] | select(.type == "item.completed" and .item.type == "agent_message" and (.item.text | type) == "string")] | if length == 0 then "" else .[-1].item.text end' "$TMP/events.json" > "$TMP/text.txt"
    grep -q '[^[:space:]]' "$TMP/text.txt" || die "empty reply" 1
    jq -cn --rawfile t "$TMP/text.txt" --arg m "$MODEL" --slurpfile ev "$TMP/events.json" '
      def count($k): ([$ev[0][] | select(.type == "turn.completed") | .usage[$k]?] | last)
        | if type == "number" and . >= 0 and floor == . then . else null end;
      {text: $t, finish_reason: "stop", input_tokens: count("input_tokens"), output_tokens: count("output_tokens"), model: $m}'
    exit 0
  fi
  grep -q '[^[:space:]]' "$TMP/out.txt" || die "empty reply" 1
  jq -cn --rawfile t "$TMP/out.txt" --arg m "$MODEL" \
    '{text: $t, finish_reason: "stop", input_tokens: null, output_tokens: null, model: $m}'
  exit 0
fi

REQUEST="$(printf '%s' "$REQ_IN" | jq -ce --arg m "$MODEL" --arg p "$MAX_PARAM" --argjson n "$MAX_TOKENS" \
  'if (.messages | type) == "array" then {model: $m, messages: .messages, ($p): $n} else error("no messages") end' 2>/dev/null)" \
  || usage 'stdin must be {"messages":[...]}'

KEY=""
if [ "$KEY_ENV" != "-" ]; then
  KEY="${!KEY_ENV:-}"
  [ -n "$KEY" ] || die "$KEY_ENV is not set" 3
  # A CR or LF in the key would end the Authorization line and inject headers
  case "$KEY" in *[[:cntrl:]]*) die "$KEY_ENV holds a control character" 3 ;; esac
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
    esc="$(printf '%s' "$KEY" | jq -Rr @json)"
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
    code="$(curl -q -sS --max-time "$TIMEOUT" --max-filesize 20971520 -w '%{http_code}' -D "$TMP/resp.hdr" -o "$TMP/resp.json" \
      -H "@$TMP/auth" -H 'Content-Type: application/json' --data-binary "@$TMP/body.json" "$URL" 2> "$TMP/curl.err")" || rc=$?
  else
    code="$(curl -q -sS --max-time "$TIMEOUT" --max-filesize 20971520 -w '%{http_code}' -D "$TMP/resp.hdr" -o "$TMP/resp.json" \
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
      input_tokens: (.usage.prompt_tokens | if type == "number" and . >= 0 and floor == . then . else error("no usage") end),
      output_tokens: (.usage.completion_tokens | if type == "number" and . >= 0 and floor == . then . else error("no usage") end),
      model: (.model // $m) }
  else error("no choices") end' "$TMP/resp.json" > "$TMP/norm.json" 2> "$TMP/norm.err" \
  || {
    case "$(cat "$TMP/norm.err")" in
      *"no usage"*) die "reply has no usage" 1 ;;
      *) die "unparseable reply: $(redact "$(cat "$TMP/resp.json")")" 1 ;;
    esac
  }
cat "$TMP/norm.json"
