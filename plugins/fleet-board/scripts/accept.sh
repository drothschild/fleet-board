#!/usr/bin/env bash
# accept.sh - a person records "I accepted this change" on a Blocked card.
#
# Usage: accept.sh <n>
#
# After a person has looked at what blocked a card (an unreviewed merge of
# main, a test edit a fixer may not touch) and accepted it, one write to the
# manager note (a single note.sh merge) makes the plan stop flagging what was
# approved:
#   action_failures    -> 0, last_action_error -> null
#   last_review.sha    -> the PR's current head (the reviewed-sha baseline)
#   accepted           -> {"login": <authenticated gh login>, "at": <UTC>, "sha": <head>}
# tick-plan.sh honors an accepted entry only when its login is the
# authenticated one (the note itself is only trusted from that login).
#
# Exit codes:
#   0 - the note was written
#   1 - the card is not Blocked, the note names no PR, the PR head cannot be
#       read, or the note could not be written; the note is unchanged (the
#       one write is the last step)
#   2 - usage error

set -uo pipefail
unset CDPATH # a relative cd must not follow CDPATH (it would also echo the path)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

[ $# -eq 1 ] || fb_die 2 "usage: accept.sh <n>"
N="$1"
fb_valid_number "$N" || fb_die 2 "card number must be numeric, got: $N"

fb_load_config

TMP=""
trap '[ -n "$TMP" ] && rm -f "$TMP"' EXIT

ME="$(fb_login)" || exit 1
CARD="$(bash "$FLEET_SCRIPTS/board-read.sh" "$N")" || fb_die 1 "cannot read card #$N"
STATE="$(jq -r '.state // empty' <<<"$CARD" 2>/dev/null)" || fb_die 1 "cannot parse card #$N"
[ "$STATE" = blocked ] || fb_die 1 "card #$N is not Blocked (state: ${STATE:-none}); nothing accepted"

# The PR number from the note's json block (note.sh merge validates the note)
PR="$(jq -r '.manager_note // empty' <<<"$CARD" | awk '
    $0 == "```json" && !found { found = 1; on = 1; next }
    on && $0 == "```" { exit }
    on { print }' | jq -r '.pr // empty' 2>/dev/null)"
fb_valid_number "$PR" || fb_die 1 "the manager note on #$N names no PR; nothing accepted"

OUT="$(gh pr view "$PR" --repo "$FLEET_REPO" --json headRefOid)" || fb_die 1 "cannot read the PR head of #$PR; nothing accepted"
HEAD_SHA="$(jq -r '.headRefOid // empty' <<<"$OUT" 2>/dev/null)"
case "$HEAD_SHA" in
  ''|*[!0-9a-f]*) fb_die 1 "cannot read the PR head of #$PR (unexpected response); nothing accepted" ;;
esac

TMP="$(mktemp)" || fb_die 1 "cannot create a temp file"
jq -n --arg sha "$HEAD_SHA" --arg me "$ME" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{action_failures: 0, last_action_error: null, last_review: {sha: $sha},
    accepted: {login: $me, at: $at, sha: $sha}}' > "$TMP" || fb_die 1 "cannot build the patch"

bash "$FLEET_SCRIPTS/note.sh" merge "$N" "$TMP" || fb_die 1 "cannot write the manager note on #$N"
printf 'fleet-board: #%s: accepted at %s by %s; failure count reset, review baseline moved\n' "$N" "$HEAD_SHA" "$ME"
