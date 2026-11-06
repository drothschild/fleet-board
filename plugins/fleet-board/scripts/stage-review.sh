#!/usr/bin/env bash
# stage-review.sh - run one provider-backed review stage on a card's PR.
#
# Usage: stage-review.sh <n> <pr> --stage <name> --round <r> [--prev-sha <sha>]
#          [--findings <json-file>] [--impl-report <file>]
#          [--card-file <f>] [--diff-file <f>] [--no-post]
#
# Builds the prompt from providers/stage-review-prompt.md (card, stage brief,
# round, previous Critical and Important findings, latest implementor or fixer
# report, PR diff), calls the stage's provider through providers/chat.sh, checks
# the reply with parse-report.sh --role stage-reviewer and re-asks the model once
# when the reply is rejected, then posts the report with board-comment.sh and
# appends the spend to ${FLEET_BOARD_LOG_DIR:-$HOME/.fleet-board}/provider-spend.jsonl.
# The card comes from board-read.sh and the diff from gh pr diff unless
# --card-file / --diff-file name them; --no-post checks the report and posts
# nothing. With both files and --no-post no gh call is made.
# --findings is a JSON array of {severity,text} (or an object with .findings).
#
# Prints {status: posted|checked, report_file, parsed, provider, model,
# input_tokens, output_tokens, cost_usd, attempts}. The price is the stage's
# price.input / price.output in USD per million tokens.
#
# Exit codes:
#   0 - posted (or checked, with --no-post)
#   1 - provider failure, empty or truncated reply, a reply holding the
#       manager-note marker, or a failed post; nothing posted by the script
#       before the failure
#   2 - usage error, unknown stage, or an agent stage
#   3 - the provider's key variable is unset (no call made)
#   6 - the reply was rejected twice (the second rejection is printed)
#   7 - the diff exceeds max_diff_bytes or has no text hunks (no call made)
#
# The ledger gets one line for every run that reached the provider and got a
# reply: exits 0, 1 after a reply, and 6.

set -uo pipefail
unset CDPATH

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/board-lib.sh"

die() {
  printf 'stage-review: %s\n' "$1" >&2
  exit "${2:-1}"
}

N="" PR="" STAGE="" ROUND="" PREV_SHA="" FINDINGS_FILE="" IMPL_FILE="" CARD_FILE="" DIFF_FILE="" NO_POST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-post) NO_POST=1; shift ;;
    --stage|--round|--prev-sha|--findings|--impl-report|--card-file|--diff-file)
      [ $# -ge 2 ] || die "missing value for $1" 2
      case "$1" in
        --stage) STAGE="$2" ;;
        --round) ROUND="$2" ;;
        --prev-sha) PREV_SHA="$2" ;;
        --findings) FINDINGS_FILE="$2" ;;
        --impl-report) IMPL_FILE="$2" ;;
        --card-file) CARD_FILE="$2" ;;
        --diff-file) DIFF_FILE="$2" ;;
      esac
      shift 2
      ;;
    -*) die "unknown argument: $1" 2 ;;
    *)
      if [ -z "$N" ]; then N="$1"
      elif [ -z "$PR" ]; then PR="$1"
      else die "unexpected argument: $1" 2
      fi
      shift
      ;;
  esac
done
USAGE="usage: stage-review.sh <n> <pr> --stage <name> --round <r> [--prev-sha <sha>] [--findings <file>] [--impl-report <file>] [--card-file <f>] [--diff-file <f>] [--no-post]"
[ -n "$N" ] && [ -n "$PR" ] && [ -n "$STAGE" ] && [ -n "$ROUND" ] || die "$USAGE" 2
fb_valid_number "$N" || die "card number must be numeric, got: $N" 2
fb_valid_number "$PR" || die "pr number must be numeric, got: $PR" 2
case "$ROUND" in ''|*[!0-9]*) die "--round must be an integer" 2 ;; esac
for f in "$FINDINGS_FILE" "$IMPL_FILE" "$CARD_FILE" "$DIFF_FILE"; do
  [ -z "$f" ] || [ -f "$f" ] || die "file not found: $f" 2
done

fb_load_config

STAGE_JSON="$(jq -c --arg s "$STAGE" '(.review.stages // [])[] | select(.name == $s)' <<<"$FLEET_CFG")"
[ -n "$STAGE_JSON" ] || die "unknown stage $STAGE" 2
PROVIDER="$(jq -r '.provider // empty' <<<"$STAGE_JSON")"
[ -n "$PROVIDER" ] || die "stage $STAGE is an agent stage" 2

MODEL="$(jq -r .model <<<"$STAGE_JSON")"
TIMEOUT="$(jq -r .timeout <<<"$STAGE_JSON")"
MAX_OUT="$(jq -r .max_output_tokens <<<"$STAGE_JSON")"
MAX_DIFF="$(jq -r .max_diff_bytes <<<"$STAGE_JSON")"
PRICE_IN="$(jq -r .price.input <<<"$STAGE_JSON")"
PRICE_OUT="$(jq -r .price.output <<<"$STAGE_JSON")"
BASE_URL="$(jq -r --arg p "$PROVIDER" '.providers[$p].base_url' <<<"$FLEET_CFG")"
KEY_ENV="$(jq -r --arg p "$PROVIDER" '.providers[$p].api_key_env // "-"' <<<"$FLEET_CFG")"
MAX_PARAM="$(jq -r --arg p "$PROVIDER" '.providers[$p].max_tokens_param' <<<"$FLEET_CFG")"

if [ "$KEY_ENV" != "-" ] && [ -z "${!KEY_ENV:-}" ]; then
  die "$KEY_ENV is not set (provider $PROVIDER, stage $STAGE)" 3
fi

LOG_DIR="${FLEET_BOARD_LOG_DIR:-$HOME/.fleet-board}"
mkdir -p "$LOG_DIR/stage-reports"
LOG_DIR="$(cd "$LOG_DIR" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Inputs: card body and diff
if [ -n "$CARD_FILE" ]; then
  cp "$CARD_FILE" "$TMP/card"
else
  bash "$HERE/board-read.sh" "$N" | jq -r '.body // ""' > "$TMP/card" || die "cannot read card #$N" 1
fi
if [ -n "$DIFF_FILE" ]; then
  cp "$DIFF_FILE" "$TMP/diff"
else
  gh pr diff "$PR" --repo "$FLEET_REPO" > "$TMP/diff" || die "cannot read the diff of PR #$PR" 1
fi
DIFF_BYTES="$(wc -c < "$TMP/diff" | tr -d ' ')"
if [ "$DIFF_BYTES" -gt "$MAX_DIFF" ]; then
  die "diff $DIFF_BYTES bytes exceeds max_diff_bytes $MAX_DIFF" 7
fi
grep -q '^@@' "$TMP/diff" || die "diff has no text hunks" 7

if [ -n "$IMPL_FILE" ]; then cp "$IMPL_FILE" "$TMP/impl"; else printf '(none)' > "$TMP/impl"; fi
jq -r '.brief // "(none)"' <<<"$STAGE_JSON" > "$TMP/brief"
FINDINGS_TEXT="(none)"
if [ "$ROUND" -ge 2 ] && [ -n "$FINDINGS_FILE" ]; then
  FINDINGS_TEXT="$(jq -r '(if type == "array" then . else (.findings // []) end)
    | map(select(.severity == "Critical" or .severity == "Important") | "- [\(.severity)] \(.text)")
    | if length == 0 then "(none)" else join("\n") end' "$FINDINGS_FILE")" || die "cannot read findings file $FINDINGS_FILE" 2
fi
printf '%s' "$FINDINGS_TEXT" > "$TMP/findings"

# Fill the template in one pass: placeholders in inserted text stay literal.
jq -n --rawfile tpl "$HERE/providers/stage-review-prompt.md" \
  --rawfile card "$TMP/card" --rawfile diff "$TMP/diff" --rawfile impl "$TMP/impl" \
  --rawfile brief "$TMP/brief" --rawfile findings "$TMP/findings" \
  --arg stage "$STAGE" --arg round "$ROUND" --arg prev "${PREV_SHA:-none}" '
  {STAGE: $stage, ROUND: $round, PREV_SHA: $prev, CARD: $card, DIFF: $diff, IMPL_REPORT: $impl,
   BRIEF: $brief, FINDINGS: $findings} as $v
  | ($tpl | split("\n---USER---\n")) as $parts
  | [ {role: "system", content: $parts[0]}, {role: "user", content: $parts[1]} ]
  | map(.content |= gsub("\\{\\{(?<k>[A-Z_]+)\\}\\}"; $v[.k]))' > "$TMP/messages.json" \
  || die "cannot build the prompt" 1

IN_TOTAL=0
OUT_TOTAL=0
ATTEMPTS=0
REPLIED=0
RESP_MODEL="$MODEL"

write_ledger() {
  [ "$REPLIED" -eq 1 ] || return 0
  local cost run
  cost="$(LC_ALL=C awk -v i="$IN_TOTAL" -v o="$OUT_TOTAL" -v pi="$PRICE_IN" -v po="$PRICE_OUT" 'BEGIN { printf "%.6f", (i * pi + o * po) / 1000000 }')"
  COST="$cost"
  run="${FLEET_BOARD_RUN_ID:-}"
  jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg run "$run" --arg repo "$FLEET_REPO" \
    --argjson card "$N" --arg stage "$STAGE" --arg provider "$PROVIDER" --arg model "$RESP_MODEL" \
    --argjson i "$IN_TOTAL" --argjson o "$OUT_TOTAL" --argjson cost "$cost" \
    '{ts: $ts, run_id: (if $run == "" then null else $run end), repo: $repo, card: $card, stage: $stage,
      provider: $provider, model: $model, input_tokens: $i, output_tokens: $o, cost_usd: $cost}' \
    >> "$LOG_DIR/provider-spend.jsonl"
}

fail_after_reply() { # message code
  write_ledger
  die "$1" "${2:-1}"
}

REPORT_FILE="$LOG_DIR/stage-reports/card-$N-$STAGE-round$ROUND.md"
COST=0
MESSAGES="$(cat "$TMP/messages.json")"
PARSED=""

while :; do
  ATTEMPTS=$((ATTEMPTS + 1))
  rc=0
  printf '%s' "$(jq -c '{messages: .}' <<<"$MESSAGES")" | bash "$HERE/providers/chat.sh" \
    --base-url "$BASE_URL" --key-env "$KEY_ENV" --model "$MODEL" --max-tokens "$MAX_OUT" \
    --max-tokens-param "$MAX_PARAM" --timeout "$TIMEOUT" > "$TMP/reply.json" 2> "$TMP/chat.err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    cat "$TMP/chat.err" >&2
    write_ledger
    case "$rc" in 3) exit 3 ;; *) exit 1 ;; esac
  fi
  REPLIED=1
  IN_TOTAL=$((IN_TOTAL + $(jq -r .input_tokens "$TMP/reply.json")))
  OUT_TOTAL=$((OUT_TOTAL + $(jq -r .output_tokens "$TMP/reply.json")))
  RESP_MODEL="$(jq -r .model "$TMP/reply.json")"
  jq -j .text "$TMP/reply.json" > "$TMP/reply.txt"

  if [ "$(jq -r .finish_reason "$TMP/reply.json")" = "length" ]; then
    fail_after_reply "reply truncated at max_output_tokens $MAX_OUT" 1
  fi
  if ! grep -q '[^[:space:]]' "$TMP/reply.txt"; then
    fail_after_reply "empty reply" 1
  fi
  if grep -qF -- "$FB_MARKER" "$TMP/reply.txt"; then
    fail_after_reply "reply contains the manager-note marker" 1
  fi

  cp "$TMP/reply.txt" "$REPORT_FILE"
  if PARSED="$(bash "$HERE/parse-report.sh" --role stage-reviewer "$REPORT_FILE" 2> "$TMP/parse.err")"; then
    break
  fi
  if [ "$ATTEMPTS" -ge 2 ]; then
    cat "$TMP/parse.err" >&2
    write_ledger
    exit 6
  fi
  MESSAGES="$(jq -c --rawfile reply "$TMP/reply.txt" --rawfile err "$TMP/parse.err" \
    '. + [{role: "assistant", content: $reply},
          {role: "user", content: ("Your report was rejected by the checker:\n" + $err + "\nReply with the corrected full report only.")}]' <<<"$MESSAGES")"
done

write_ledger

STATUS=checked
if [ "$NO_POST" -eq 0 ]; then
  bash "$HERE/board-comment.sh" "$N" "$REPORT_FILE" >&2 || die "cannot post the report on #$N" 1
  STATUS=posted
fi

jq -cn --arg status "$STATUS" --arg file "$REPORT_FILE" --argjson parsed "$PARSED" --arg provider "$PROVIDER" \
  --arg model "$RESP_MODEL" --argjson i "$IN_TOTAL" --argjson o "$OUT_TOTAL" --argjson cost "$COST" \
  --argjson attempts "$ATTEMPTS" \
  '{status: $status, report_file: $file, parsed: $parsed, provider: $provider, model: $model,
    input_tokens: $i, output_tokens: $o, cost_usd: $cost, attempts: $attempts}'
