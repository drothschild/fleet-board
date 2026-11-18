#!/usr/bin/env bash
# premise-settle.sh - a premise proposal, and the owner's decision on it.
#
# Usage:
#   premise-settle.sh propose <n> <json-file>
#   premise-settle.sh approve <n>
#   premise-settle.sh confirm <n>
#   premise-settle.sh reject <n>
#
# A card's `proposal` field is null, or
#   {kind: "rewrite", scope, acceptance: [..], summary, head: <40-hex>, at}
#   {kind: "close", evidence: [{item, command, output}, ..], head, at}
# propose stores the file's proposal (adding `at`); it is the supervisor's only use of this script.
# approve (a Blocked card with a rewrite proposal): replaces the body's ## Scope section and the
#   acceptance with the proposal's, keeps blocked_by, clears the proposal, moves the card to ready and
#   stamps it by approve with the proposal's head.
# confirm (a Blocked card with a close proposal): adds the label fleet:closed-as-built, clears the
#   proposal and moves the card to done.
# reject: clears the proposal and leaves the state.
# confirm and reject append {card, decision, at} to <board.dir>/premise-decisions.jsonl.
# Only a person runs approve, confirm and reject (gate rule G4).
#
# Exit codes: 0 done; 1 the card is not Blocked, has no proposal of that kind
# (card #<n> has no <rewrite|close> proposal to <approve|confirm>), or the proposed Scope names no
# repository path; 2 usage or a malformed proposal file; 3 the card cannot be read.
set -uo pipefail
unset CDPATH
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

USAGE="usage: premise-settle.sh propose <n> <json-file> | approve <n> | confirm <n> | reject <n>"
[ $# -ge 2 ] || fb_die 2 "$USAGE"
VERB="$1"; N="$2"; shift 2
fb_valid_number "$N" || fb_die 2 "card number must be numeric, got: $N"
case "$VERB" in
  propose) [ $# -eq 1 ] || fb_die 2 "$USAGE"; FILE="$1" ;;
  approve|confirm|reject) [ $# -eq 0 ] || fb_die 2 "$USAGE" ;;
  *) fb_die 2 "$USAGE" ;;
esac

fb_load_config
. "$FB_SCRIPTS/adapters/local/local-lib.sh"
fl_require_store
[ -f "$(fl_card_file "$N")" ] || fb_die 3 "card #$N not found in $(fl_cards_dir)"

if [ "$VERB" = propose ]; then
  [ -f "$FILE" ] || fb_die 2 "cannot read the proposal file: $FILE"
  PROP="$(jq -c --arg now "$(fl_now)" '
    def str: type == "string" and length > 0;
    if type != "object" then error("not an object")
    elif (.head | type) != "string" or (.head | test("^[0-9a-f]{40}$") | not) then error("head must be 40 hex characters")
    elif .kind == "rewrite" then
      if (.scope | str | not) then error("scope must be a non-empty string")
      elif ((.acceptance | type) != "array" or (.acceptance | length) == 0 or (.acceptance | all(str) | not)) then error("acceptance must be a non-empty list of strings")
      elif (.summary | type) != "string" then error("summary must be a string")
      else {kind, scope, acceptance, summary, head, at: $now} end
    elif .kind == "close" then
      if ((.evidence | type) != "array" or (.evidence | length) == 0
          or (.evidence | all(type == "object" and (.item | type) == "number" and .item >= 1 and .item == (.item | floor)
                              and (.command | type) == "string" and (.output | type) == "string") | not))
      then error("evidence must be a non-empty list of {item, command, output}")
      else {kind, evidence: [.evidence[] | {item, command, output}], head, at: $now} end
    else error("kind must be rewrite or close") end' "$FILE" 2>&1)" \
    || fb_die 2 "malformed proposal: $(printf '%s' "$PROP" | head -n 1 | sed 's/^jq: error[^:]*: //')"
fi

fb_lock "$N"
TMP="$(mktemp)" || fb_die 1 "cannot create a temporary file"
trap 'rm -f "$TMP"; fb_lock_release "$FB_LOCK"' EXIT
CARD="$(fl_read_card "$N")" || exit 3
NOW="$(fl_now)"

# need_proposal <kind> <verb>: the card is Blocked and holds a proposal of that kind
need_proposal() {
  jq -e --arg k "$1" '.state == "blocked" and (.proposal | type) == "object" and .proposal.kind == $k' <<<"$CARD" >/dev/null 2>&1 \
    || { printf 'card #%s has no %s proposal to %s\n' "$N" "$1" "$2" >&2; exit 1; }
}

case "$VERB" in
  propose)
    jq --argjson p "$PROP" '.proposal = $p' <<<"$CARD" > "$TMP" || fb_die 1 "cannot update card #$N"
    fl_write_card "$N" "$TMP" || exit 1 ;;
  approve)
    need_proposal rewrite approve
    SCOPE="$(jq -r '.proposal.scope' <<<"$CARD")"
    fb_card_has_scope_paths "$(printf '## Scope\n%s\n' "$SCOPE")" \
      || { printf 'card #%s: the proposed Scope names no repository path\n' "$N" >&2; exit 1; }
    BODY="$(fl_replace_scope "$(jq -r '.body // ""' <<<"$CARD")" "$SCOPE")" || fb_die 1 "cannot rewrite the Scope of card #$N"
    jq --arg body "$BODY" --arg now "$NOW" '
      .body = $body | .acceptance = .proposal.acceptance
      | .premise = {sha: .proposal.head, at: $now, by: "approve"}
      | .proposal = null | .state = "ready" | .updated_at = $now' <<<"$CARD" > "$TMP" || fb_die 1 "cannot update card #$N"
    fl_write_card "$N" "$TMP" || exit 1 ;;
  confirm)
    need_proposal close confirm
    jq --arg now "$NOW" '
      .labels = (((.labels // []) | map(select(. != "fleet:closed-as-built"))) + ["fleet:closed-as-built"])
      | .proposal = null | .state = "done" | .updated_at = $now' <<<"$CARD" > "$TMP" || fb_die 1 "cannot update card #$N"
    fl_write_card "$N" "$TMP" || exit 1
    fl_premise_decision "$N" confirmed ;;
  reject)
    jq --arg now "$NOW" '.proposal = null | .updated_at = $now' <<<"$CARD" > "$TMP" || fb_die 1 "cannot update card #$N"
    fl_write_card "$N" "$TMP" || exit 1
    fl_premise_decision "$N" rejected ;;
esac
