#!/usr/bin/env bash
# needs-human-qa.sh - decides whether a card's PR needs human QA.
#
# Usage: needs-human-qa.sh [--labels <json-array>] <card-n> <pr-n>
#
# --labels: the card's label names as a JSON array of strings (as board-read.sh
# prints them), from a card read the caller already has; the card is then not
# read again.
#
# Prints true when the card carries the needs-human-qa label, or when a file
# the PR changes matches a human_qa_paths glob; prints false otherwise.
#
# Glob rule: matched with bash `case` after turning ** into *; a pattern that
# starts with **/ also matches with that prefix removed, so src/components/**
# matches src/components/a/b.tsx and **/*.test.* matches a.test.js.
#
# When gh lists fewer files than the PR changes (a very large PR), the answer
# is true with a warning: a file it did not list could need human QA.
#
# Exit codes:
#   0 - answer printed
#   1 - the card or the PR's files could not be read (nothing printed)
#   2 - usage error (including --labels that is not a JSON array of strings)

set -uo pipefail
unset CDPATH # a relative cd must not follow CDPATH (it would also echo the path)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

LABELS=""
if [ "${1:-}" = --labels ]; then
  [ $# -eq 4 ] || fb_die 2 "usage: needs-human-qa.sh [--labels <json-array>] <card-n> <pr-n>"
  LABELS="$(jq -c 'if type == "array" and all(.[]; type == "string") then . else error("not a list of names") end' <<<"$2" 2>/dev/null)" \
    || fb_die 2 "--labels must be a JSON array of strings"
  shift 2
fi
[ $# -eq 2 ] || fb_die 2 "usage: needs-human-qa.sh [--labels <json-array>] <card-n> <pr-n>"
fb_valid_number "$1" || fb_die 2 "card number must be numeric, got: $1"
fb_valid_number "$2" || fb_die 2 "PR number must be numeric, got: $2"
CARD="$1"
PR="$2"

fb_load_config

if [ -z "$LABELS" ]; then
  READ="$(bash "$FLEET_SCRIPTS/board-read.sh" "$CARD")" || fb_die 1 "cannot read card #$CARD"
  LABELS="$(jq -c '.labels // []' <<<"$READ" 2>/dev/null)" || fb_die 1 "cannot read the labels of card #$CARD"
fi
LABELED="$(jq -r 'index("needs-human-qa") != null' <<<"$LABELS" 2>/dev/null)" \
  || fb_die 1 "cannot read the labels of card #$CARD"
if [ "$LABELED" = true ]; then
  echo true
  exit 0
fi

PATTERNS="$(jq -r '.human_qa_paths[]' <<<"$FLEET_CFG")" || fb_die 1 "cannot read human_qa_paths"
if [ -z "$PATTERNS" ]; then
  echo false
  exit 0
fi

FILES_JSON="$(gh pr view "$PR" --repo "$FLEET_REPO" --json files,changedFiles)" \
  || fb_die 1 "cannot list the files of PR #$PR"
INFO="$(jq -r '
  if (.files | type) != "array" then error("no files") else . end
  | ((.changedFiles // 0) > (.files | length)), (.files[].path)' <<<"$FILES_JSON" 2>/dev/null)" \
  || fb_die 1 "cannot parse the files of PR #$PR"
TRUNCATED="$(printf '%s\n' "$INFO" | sed -n 1p)"
PATHS="$(printf '%s\n' "$INFO" | sed '1d')"

if [ "$TRUNCATED" = true ]; then
  printf 'fleet-board: warning: PR #%s changes more files than gh listed; treating it as needing human QA\n' "$PR" >&2
  echo true
  exit 0
fi

# matches <path> <pattern>
matches() {
  local path="$1" pat="${2//\*\*/*}"
  # shellcheck disable=SC2254 # the pattern is a glob on purpose
  case "$path" in $pat) return 0 ;; esac
  case "$2" in
    '**/'*)
      pat="${2#\*\*/}"
      pat="${pat//\*\*/*}"
      case "$path" in $pat) return 0 ;; esac
      ;;
  esac
  return 1
}

while IFS= read -r path; do
  [ -n "$path" ] || continue
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    if matches "$path" "$pat"; then
      echo true
      exit 0
    fi
  done <<<"$PATTERNS"
done <<<"$PATHS"

echo false
