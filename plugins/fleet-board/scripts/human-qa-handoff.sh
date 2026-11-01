#!/usr/bin/env bash
# human-qa-handoff.sh - posts the Human QA hand-off comment on a card.
#
# Usage: human-qa-handoff.sh [--qa-summary <file>] <card-n> <pr-n>
#
# The comment is headed "What to check in Human QA" and holds:
#   - the card's ## Acceptance section as a blockquote;
#   - a checklist of the pre-merge steps a person must do, from the PR's state
#     (draft, conflicting, no checks) and each bullet of the card's
#     ## Human QA section. No steps means no checklist at all;
#   - the contents of --qa-summary <file>, when given (the qa_build summary);
#   - the sentence saying no agent moves the card out of Human QA.
#
# Posted once per hand-off: when the card already has a comment with the
# heading line, nothing is posted.
#
# Exit codes:
#   0 - comment posted, or one was already there
#   1 - the card, the PR or the comment could not be read or posted
#   2 - usage error

set -uo pipefail
unset CDPATH # a relative cd must not follow CDPATH (it would also echo the path)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

USAGE="usage: human-qa-handoff.sh [--qa-summary <file>] <card-n> <pr-n>"
SUMMARY_FILE=""
if [ "${1:-}" = --qa-summary ]; then
  [ $# -eq 4 ] || fb_die 2 "$USAGE"
  SUMMARY_FILE="$2"
  [ -f "$SUMMARY_FILE" ] || fb_die 2 "file not found: $SUMMARY_FILE"
  shift 2
fi
[ $# -eq 2 ] || fb_die 2 "$USAGE"
fb_valid_number "$1" || fb_die 2 "card number must be numeric, got: $1"
fb_valid_number "$2" || fb_die 2 "PR number must be numeric, got: $2"
CARD="$1"
PR="$2"

HEADING="What to check in Human QA"
SENTENCE="No agent moves this card out of Human QA; move it to Done yourself once it is merged and checked."

fb_load_config

READ="$(bash "$FLEET_SCRIPTS/board-read.sh" "$CARD")" || fb_die 1 "cannot read card #$CARD"

ALREADY="$(jq -r --arg h "$HEADING" \
  '[.comments[]? | select(.body | split("\n") | map(gsub("^#+ *"; "")) | index($h))] | length' <<<"$READ")" \
  || fb_die 1 "cannot read the comments of card #$CARD"
if [ "$ALREADY" != 0 ]; then
  exit 0
fi

PRJSON="$(gh pr view "$PR" --repo "$FLEET_REPO" --json isDraft,mergeable,statusCheckRollup)" \
  || fb_die 1 "cannot read PR #$PR"
FACTS="$(jq -r '
  (if .isDraft == true then "draft" else empty end),
  (if .mergeable == "CONFLICTING" then "conflicting" else empty end),
  (if (.statusCheckRollup | type) == "array" and (.statusCheckRollup | length) == 0 then "nochecks" else empty end)' \
  <<<"$PRJSON")" || fb_die 1 "cannot parse PR #$PR"

BODY="$(jq -r '.body // ""' <<<"$READ")" || fb_die 1 "cannot read the body of card #$CARD"

# section <heading text>: the lines under "## <heading>" up to the next "## "
section() {
  printf '%s\n' "$BODY" | tr -d '\r' | awk -v h="## $1" '
    $0 == h { on = 1; next }
    /^## / { on = 0 }
    on { print }'
}

ACCEPTANCE="$(section Acceptance)"
QA_ITEMS="$(section "Human QA" | sed -n 's/^- \(.*\)$/\1/p')"

STEPS=""
add_step() { STEPS="${STEPS}- [ ] $1"$'\n'; }
CI_NOTE=""
for fact in $FACTS; do
  case "$fact" in
    draft) add_step "Mark the PR ready for review (it is still a draft)." ;;
    conflicting) add_step "Resolve the merge conflict on the PR." ;;
    nochecks) CI_NOTE="No CI ran on the PR, so nothing has checked it automatically." ;;
  esac
done
if [ -n "$QA_ITEMS" ]; then
  while IFS= read -r item; do
    add_step "$item"
  done <<<"$QA_ITEMS"
fi

OUT="$(mktemp)" || fb_die 1 "cannot create a temp file"
trap 'rm -f "$OUT"' EXIT
{
  printf '## %s\n\n' "$HEADING"
  if [ -n "$ACCEPTANCE" ]; then
    printf '> ## Acceptance\n'
    printf '%s\n' "$ACCEPTANCE" | sed 's/^/> /'
    printf '\n'
  fi
  if [ -n "$STEPS" ]; then
    printf 'Before merging:\n\n%s\n' "$STEPS"
  fi
  if [ -n "$CI_NOTE" ]; then
    printf '%s\n\n' "$CI_NOTE"
  fi
  if [ -n "$SUMMARY_FILE" ]; then
    cat "$SUMMARY_FILE"
    printf '\n'
  fi
  printf '%s\n' "$SENTENCE"
} > "$OUT"

bash "$FLEET_SCRIPTS/board-comment.sh" "$CARD" "$OUT" || fb_die 1 "cannot post the hand-off comment on card #$CARD"
