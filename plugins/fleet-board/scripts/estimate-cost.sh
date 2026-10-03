#!/usr/bin/env bash
# estimate-cost.sh - estimates the USD cost of token counts from prices.json.
#
# Usage:
#   estimate-cost.sh --model <alias|id> --input N --output N [--cache-write N] [--cache-read N]
#   estimate-cost.sh --model <alias|id> --tokens N
#   estimate-cost.sh --model-usage <json>
#
# Prints USD with 4 decimals. Prices are USD per million tokens, read from
# prices.json next to this script; an alias (opus, sonnet, ...) maps to an id.
#   --tokens N       a total-token-only count (what subagent results give),
#                    priced at the blended rate 0.8*input + 0.2*output
#   --model-usage J  a stream-json modelUsage object, {<model>: {inputTokens,
#                    outputTokens, cacheReadInputTokens,
#                    cacheCreationInputTokens, costUSD}}; an entry's costUSD is
#                    used when present, otherwise its tokens are priced
# The result is an estimate: prices.json is a snapshot, not a bill.
#
# Exit codes:
#   0 - cost printed
#   1 - unknown model (or prices.json unreadable)
#   2 - usage error (bad flag, missing or non-numeric count, invalid JSON)

set -uo pipefail
unset CDPATH # a relative cd must not follow CDPATH (it would also echo the path)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRICES="$HERE/prices.json"

USAGE="usage: estimate-cost.sh --model M (--input N --output N [--cache-write N] [--cache-read N] | --tokens N) | --model-usage <json>"
die() { printf 'estimate-cost: %s\n' "$2" >&2; exit "$1"; }
# cawk: awk in the C locale. Under a comma-decimal LC_NUMERIC (de_DE, say),
# macOS awk reads "0.5" as 0 and prints 1.5 as "1,5000"; the cost is always
# read and printed with a dot
cawk() { LC_ALL=C awk "$@"; }

MODEL="" INPUT="" OUTPUT="" CW="" CR="" TOKENS="" USAGE_JSON="" HAVE_USAGE=0
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || die 2 "$USAGE"
  case "$1" in
    --model) MODEL="$2" ;;
    --input) INPUT="$2" ;;
    --output) OUTPUT="$2" ;;
    --cache-write) CW="$2" ;;
    --cache-read) CR="$2" ;;
    --tokens) TOKENS="$2" ;;
    --model-usage) USAGE_JSON="$2"; HAVE_USAGE=1 ;;
    *) die 2 "$USAGE" ;;
  esac
  shift 2
done

count_ok() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

[ -r "$PRICES" ] || die 1 "cannot read $PRICES"

# rates <model>: prints "input output cache_write cache_read", or fails when unknown
rates() {
  jq -r --arg m "$1" '
    (.aliases[$m] // $m) as $id
    | .models[$id] // error("unknown")
    | "\(.input) \(.output) \(.cache_write) \(.cache_read)"' "$PRICES" 2>/dev/null
}

if [ "$HAVE_USAGE" = 1 ]; then
  [ -z "$MODEL$INPUT$OUTPUT$CW$CR$TOKENS" ] || die 2 "$USAGE"
  jq -e 'type == "object" and all(.[]; type == "object")' <<<"$USAGE_JSON" >/dev/null 2>&1 \
    || die 2 "--model-usage needs a JSON object of per-model objects"
  # One line per model: "c <costUSD>", "t <tokens and rates>", or "u <model>"
  LINES="$(jq -r --slurpfile p "$PRICES" '
    def n($k): (.[$k] // 0) as $v | if ($v | type) == "number" and $v >= 0 then $v else error("bad count \($k)") end;
    to_entries[]
    | .key as $m | .value as $u
    | if ($u.costUSD | type) == "number" then "c \($u.costUSD)"
      else ($p[0].models[$p[0].aliases[$m] // $m]) as $r
        | if $r == null then "u \($m)"
          else "t \($u | n("inputTokens")) \($u | n("outputTokens")) \($u | n("cacheCreationInputTokens")) \($u | n("cacheReadInputTokens")) \($r.input) \($r.output) \($r.cache_write) \($r.cache_read)"
          end
      end' <<<"$USAGE_JSON" 2>/dev/null)" || die 2 "--model-usage holds a non-numeric count"
  UNKNOWN="$(printf '%s\n' "$LINES" | awk '$1 == "u" { sub(/^u /, ""); print; exit }')"
  [ -z "$UNKNOWN" ] || die 1 "unknown model: $UNKNOWN"
  printf '%s\n' "$LINES" | cawk '
    $1 == "c" { s += $2 }
    $1 == "t" { s += ($2 * $6 + $3 * $7 + $4 * $8 + $5 * $9) / 1000000 }
    END { printf "%.4f\n", s }'
  exit 0
fi

[ -n "$MODEL" ] || die 2 "$USAGE"
if [ -n "$TOKENS" ]; then
  [ -z "$INPUT$OUTPUT$CW$CR" ] || die 2 "$USAGE"
  count_ok "$TOKENS" || die 2 "--tokens needs a non-negative integer, got: $TOKENS"
else
  [ -n "$INPUT" ] && [ -n "$OUTPUT" ] || die 2 "$USAGE"
  for v in "$INPUT" "$OUTPUT" "${CW:-0}" "${CR:-0}"; do
    count_ok "$v" || die 2 "token counts must be non-negative integers, got: $v"
  done
fi

R="$(rates "$MODEL")" || die 1 "unknown model: $MODEL"
[ -n "$R" ] || die 1 "unknown model: $MODEL"

if [ -n "$TOKENS" ]; then
  printf '%s\n' "$R" | cawk -v t="$TOKENS" '{ printf "%.4f\n", t * (0.8 * $1 + 0.2 * $2) / 1000000 }'
else
  printf '%s\n' "$R" | cawk -v i="$INPUT" -v o="$OUTPUT" -v w="${CW:-0}" -v r="${CR:-0}" \
    '{ printf "%.4f\n", (i * $1 + o * $2 + w * $3 + r * $4) / 1000000 }'
fi
