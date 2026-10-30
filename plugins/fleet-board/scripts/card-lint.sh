#!/usr/bin/env bash
# card-lint.sh - checks a card's body before any agent runs on it.
#
# Usage: card-lint.sh <number>
#        card-lint.sh --body-file <file>     (lint a body already read; used by tick-plan.sh)
#
# Prints one line per violation, "<rule>: <detail>", and exits 1; prints
# nothing and exits 0 for a card that passes. Rules:
#   no-heading    no "## Acceptance" heading. When the body has "**Acceptance**"
#                 or "Acceptance:" the detail starts with "found " and names it.
#   no-bullets    the heading is there but no "- " bullet is under it.
#   manual-check  an Acceptance bullet holds a phrase that marks a check no
#                 agent can run (on device, on a device, verify on, by hand,
#                 Human QA, simulator, any case); it belongs under "## Human QA".
#                 The detail is the bullet's text.
#
# Exit codes: 0 pass, 1 lint failed, 2 usage error, 3 the card could not be read.

set -uo pipefail
unset CDPATH
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

BODY=""
if [ $# -eq 2 ] && [ "$1" = "--body-file" ]; then
  [ -r "$2" ] || fb_die 2 "cannot read file: $2"
  BODY="$(cat "$2")"
elif [ $# -eq 1 ]; then
  fb_valid_number "$1" || fb_die 2 "card number must be numeric, got: $1"
  fb_load_config
  READ="$(bash "$FLEET_SCRIPTS/board-read.sh" "$1")" || fb_die 3 "cannot read card #$1"
  BODY="$(jq -r '.body // ""' <<<"$READ" 2>/dev/null)" || fb_die 3 "cannot parse card #$1"
else
  fb_die 2 "usage: card-lint.sh <number> | card-lint.sh --body-file <file>"
fi

FOUND=0

if ! fb_has_acceptance "$BODY"; then
  hint="$(grep -Eio -m1 '^[[:space:]]*(\*\*Acceptance[^*]*\*\*|Acceptance:)' <<<"$BODY" | sed 's/^[[:space:]]*//')"
  if [ -n "$hint" ]; then
    echo "no-heading: found \"$hint\" instead of a \"## Acceptance\" heading"
  else
    echo "no-heading: no \"## Acceptance\" heading"
  fi
  exit 1
fi

# The lines under the Acceptance heading, up to the next "## " heading
SECTION="$(awk '
  /^##[ \t]+Acceptance([ \t].*)?$/ { in_s = 1; next }
  /^##[ \t]/ { in_s = 0 }
  in_s { print }
' <<<"$BODY")"

BULLETS="$(grep -E '^- ' <<<"$SECTION" || true)"
if [ -z "$BULLETS" ]; then
  echo "no-bullets: the Acceptance section has no \"- \" bullet"
  exit 1
fi

while IFS= read -r line; do
  if grep -Eiq 'on (a )?device|verify on|by hand|human qa|simulator' <<<"$line"; then
    printf 'manual-check: %s\n' "${line#- }"
    FOUND=1
  fi
done <<<"$BULLETS"

[ "$FOUND" -eq 0 ] || exit 1
exit 0
