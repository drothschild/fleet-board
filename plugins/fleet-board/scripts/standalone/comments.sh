#!/usr/bin/env bash
# Read official reports through the configured board adapter.
set -uo pipefail
[ "$#" -eq 1 ] || { echo 'usage: comments.sh CARD' >&2; exit 2; }
SCRIPTS="$(cd "$(dirname "$0")/.." && pwd)"
card="$(bash "$SCRIPTS/board-read.sh" "$1")" || exit 1
jq -ec '.comments | if type == "array" and all(.[]; (.author | type == "string") and (.body | type == "string")) then . else error("invalid board comments") end' <<<"$card"
