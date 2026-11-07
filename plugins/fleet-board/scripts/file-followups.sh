#!/usr/bin/env bash
# file-followups.sh - files a role report's follow-ups as Backlog cards.
#
# Usage: file-followups.sh <card-n> <pr> <parsed-report-json-file>
#
# The report file is parse-report.sh output; its out_of_scope items
# ({title, detail}) and bugs ({title, repro, expected, observed}) are filed.
#
#   0. The input is deduplicated by (kind, title), titles compared
#      case-insensitively. Items whose title is already in the card's note
#      (out_of_scope_created for out-of-scope items, bugs_filed for bugs) are
#      dropped: they were filed before.
#   1. Pass one searches the card files for every item before anything is
#      written (fl_find_title): an open card (any state but done and wont_do)
#      whose title equals the item's title, case-insensitively, matches; else
#      a closed card (done or wont_do) updated within RECENT_DAYS (30) does.
#      Any search failure exits 1 having filed nothing.
#   2. Pass two files each item:
#        match      (open or closed) board-comment.sh <existing> "Also seen while working #<card> (PR #<pr>).",
#                   then gh pr comment "<Known bug|Out of scope>, already tracked as #<existing>: <title>"
#        out of scope, no match
#                   board-create.sh "<title>" (detail + "Found while working #<card> (PR #<pr>).")
#                   then gh pr comment "Out of scope, tracked as #<new>: <title>"
#        bug, no match
#                   board-create.sh "<title>" (## Bug/Repro/Expected/Observed body) --label bug
#                   then gh pr comment "Bug found outside this card, filed as #<new>: <title>"
#      An item counts as filed once its create or its existing-card comment
#      succeeds. A failed PR comment only warns on stderr:
#        fleet-board: warning: PR comment failed for #<n>
#
# Follow-up cards carry an acceptance field drafted from the finding (a bug:
# its repro and expected result; an out-of-scope item: the first backticked
# command in its detail) and, when the detail says "depends on this card",
# blocked_by naming the spawning card. They are created in the
# followups.status column (default ready). The command is the first backticked span
# with a non-blank character, spans being paired single backticks (an even number of
# them, none adjacent). An out-of-scope item with no such span, or whose detail holds
# the words "no testable check", is filed in Backlog with a card comment saying why.
# A matching closed card suppresses the item like an open one, and the printed
# entry gains "matched": "open"|"closed" (existing entries only). The PR
# comments go to GitHub; nothing else does.
#
# Prints {"out_of_scope_created":[{title,number,existing}], "bugs_filed":[...]}.
#
# Exit codes:
#   0 - every item filed (or none to file); JSON printed
#   1 - nothing filed (the note, report, or a search failed; stdout empty), or
#       a create/existing-card comment failed partway through pass two
#       (stdout holds the JSON of the items filed so far)
#   2 - usage error

set -uo pipefail
unset CDPATH # a relative cd must not follow CDPATH (it would also echo the path)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

[ $# -eq 3 ] || fb_die 2 "usage: file-followups.sh <card-n> <pr> <parsed-report-json-file>"
fb_valid_number "$1" || fb_die 2 "card number must be numeric, got: $1"
fb_valid_number "$2" || fb_die 2 "PR number must be numeric, got: $2"
[ -f "$3" ] || fb_die 2 "file not found: $3"
CARD="$1"
PR="$2"
REPORT_FILE="$3"

fb_load_config
. "$FLEET_SCRIPTS/adapters/local/local-lib.sh"

BODY="" ACC=""
trap 'rm -f ${BODY:+"$BODY"} ${ACC:+"$ACC"}' EXIT

REPORT="$(jq -s -c 'if length == 1 and (.[0] | type) == "object" then .[0] else error("not one object") end' "$REPORT_FILE" 2>/dev/null)" \
  || fb_die 1 "$REPORT_FILE does not hold one JSON object"
NOTE="$(bash "$FLEET_SCRIPTS/note.sh" get "$CARD")" || fb_die 1 "cannot read the manager note of #$CARD; nothing filed"

# The items to file, one compact JSON object per line
ITEMS="$(jq -c -n --argjson r "$REPORT" --argjson n "$NOTE" '
  def lc: ascii_downcase;
  def str: type == "string";
  def titles($k): [($n[$k] // [])[] | objects | .title | strings | lc];
  titles("out_of_scope_created") as $oh
  | titles("bugs_filed") as $bh
  | ([($r.out_of_scope // [])[] | {kind: "oos", title, detail: (.detail // "")}]
     + [($r.bugs // [])[] | {kind: "bug", title, repro, expected, observed}])
  | if all(.[]; (.title | str) and .title != "" and ([.detail, .repro, .expected, .observed] | all(. == null or str)))
    then . else error("malformed item") end
  | reduce .[] as $i ([];
      if any(.[]; .kind == $i.kind and (.title | lc) == ($i.title | lc)) then . else . + [$i] end)
  | map((.title | lc) as $t
        | select(if .kind == "oos" then (any($oh[]; . == $t) | not) else (any($bh[]; . == $t) | not) end))
  | .[]' 2>/dev/null)" || fb_die 1 "$REPORT_FILE holds a malformed out_of_scope or bugs item; nothing filed"

# Pass one: every search, before any write
MATCHES=()
MATCHED_AS=()
RECENT_DAYS=30
STATUS="$(fb_cfg followups.status)"
[ -n "$STATUS" ] || STATUS=ready
while IFS= read -r item; do
  [ -n "$item" ] || continue
  title="$(jq -r .title <<<"$item")" || fb_die 1 "cannot read an item title; nothing filed"
  m="$(fl_find_title "$title" open)" || fb_die 1 "open-card search failed for: $title; nothing filed"
  how=open
  if [ "$m" = none ]; then
    m="$(fl_find_title "$title" closed "$RECENT_DAYS")" || fb_die 1 "closed-card search failed for: $title; nothing filed"
    how=closed
  fi
  MATCHES+=("$m")
  MATCHED_AS+=("$how")
done <<<"$ITEMS"

FILED_OOS='[]'
FILED_BUGS='[]'
emit() { jq -nc --argjson o "$FILED_OOS" --argjson b "$FILED_BUGS" '{out_of_scope_created: $o, bugs_filed: $b}'; }

# record <kind> <title> <number> <existing> [open|closed]: the last says which
# kind of existing card the item matched
record() {
  local e; e="$(jq -nc --arg t "$2" --argjson n "$3" --argjson x "$4" --arg m "${5:-}" \
    '{title: $t, number: $n, existing: $x} + (if $m == "" then {} else {matched: $m} end)')" || return 1
  if [ "$1" = bug ]; then FILED_BUGS="$(jq -c --argjson e "$e" '. + [$e]' <<<"$FILED_BUGS")"
  else FILED_OOS="$(jq -c --argjson e "$e" '. + [$e]' <<<"$FILED_OOS")"; fi
}

# stop <message>: print what was filed so far, then exit 1
stop() { emit; fb_die 1 "$1"; }

# local_comment <n> <text>: posts <text> on local card <n> through board-comment.sh
local_comment() {
  local f rc
  f="$(mktemp)" || return 1
  printf '%s\n' "$2" > "$f" && bash "$FLEET_SCRIPTS/board-comment.sh" "$1" "$f" </dev/null >/dev/null
  rc=$?
  rm -f "$f"
  return $rc
}

pr_comment() {
  gh pr comment "$PR" --repo "$FLEET_REPO" --body "$1" </dev/null >/dev/null \
    || printf 'fleet-board: warning: PR comment failed for #%s\n' "$2" >&2
}

# Pass two: file
i=0
while IFS= read -r item; do
  [ -n "$item" ] || continue
  m="${MATCHES[$i]}"
  how="${MATCHED_AS[$i]}"
  i=$((i + 1))
  kind="$(jq -r .kind <<<"$item")"
  title="$(jq -r .title <<<"$item")"
  if [ "$m" != none ]; then
    local_comment "$m" "Also seen while working #$CARD (PR #$PR)." \
      || stop "cannot comment on the existing card #$m for: $title"
    record "$kind" "$title" "$m" true "$how" || stop "cannot record #$m"
    if [ "$kind" = bug ]; then label="Known bug"; else label="Out of scope"; fi
    pr_comment "$label, already tracked as #$m: $title" "$m"
    continue
  fi
  BODY="$(mktemp)" || stop "cannot create a temp file"
  ACC="$(mktemp)" || stop "cannot create a temp file"
  if [ "$kind" = bug ]; then
    jq -r --arg c "$CARD" --arg p "$PR" '
      "## Bug\n\(.title)\n\n## Repro\n`\(.repro)`\n\n## Expected\n\(.expected)\n\n## Observed\n\(.observed)\n\nFound by fleet-board while working #\($c) (PR #\($p))."' \
      <<<"$item" > "$BODY" || stop "cannot write the card body for: $title"
    jq -r '"- `\(.repro)` gives the expected result: \(.expected)"' <<<"$item" > "$ACC" || stop "cannot write the card acceptance for: $title"
    created="$(bash "$FLEET_SCRIPTS/board-create.sh" "$title" "$BODY" --label bug --state "$STATUS" --acceptance-file "$ACC" </dev/null)" || stop "cannot create the card for: $title"
  else
    # Acceptance is drafted from the first backticked command in the detail;
    # without one there is no testable bullet, so the card goes to Backlog
    # The words "no testable check" mean Backlog even when the detail also backticks a path.
    # Spans pair up as in parse-report.sh: an even number of backticks, none adjacent, and the first span with a non-blank character is the command.
    cmd="$(jq -r 'if (.detail | ascii_downcase | test("(^|[^a-z])no testable check([^a-z]|$)")) or (.detail | contains("``")) then empty else (.detail | split("`")) as $p | if ($p | length) % 2 == 0 then empty else ([$p | to_entries[] | select(.key % 2 == 1) | .value | select(gsub("[\u00a0\u200b]"; "") | test("[^ \\t]"))] | first) // empty end end' <<<"$item" 2>/dev/null)"
    jq -r --arg c "$CARD" --arg p "$PR" '
      (if .detail == "" then "" else "\(.detail)\n\n" end)
      + "Found while working #\($c) (PR #\($p))."' \
      <<<"$item" > "$BODY" || stop "cannot write the card body for: $title"
    if [ -n "$cmd" ]; then
      jq -rn --arg cmd "$cmd" '"- `\($cmd)` gives the result the description above expects"' > "$ACC" \
        || stop "cannot write the card acceptance for: $title"
    else
      : > "$ACC"
    fi
    cargs=(--acceptance-file "$ACC")
    if jq -e '.detail | test("depends on this card"; "i")' <<<"$item" >/dev/null 2>&1; then cargs+=(--blocked-by "$CARD"); fi
    state="$STATUS"
    [ -n "$cmd" ] || state=backlog
    created="$(bash "$FLEET_SCRIPTS/board-create.sh" "$title" "$BODY" --state "$state" "${cargs[@]}" </dev/null)" || stop "cannot create the card for: $title"
  fi
  rm -f "$BODY" "$ACC"
  BODY="" ACC=""
  new="$(jq -r '.number' <<<"$created" 2>/dev/null)"
  fb_valid_number "$new" || stop "board-create.sh returned no card number for: $title"
  record "$kind" "$title" "$new" false || stop "cannot record #$new"
  if [ "$kind" = bug ]; then
    pr_comment "Bug found outside this card, filed as #$new: $title" "$new"
  else
    if [ -z "$cmd" ]; then
      if jq -e '.detail | ascii_downcase | test("(^|[^a-z])no testable check([^a-z]|$)")' <<<"$item" >/dev/null 2>&1; then
        backlog_msg="Filed in Backlog: the role stated that there is no testable check, so a person must write criteria and move it to Ready."
      else
        backlog_msg="Filed in Backlog: the finding gave no testable Acceptance bullet (no failing command and expected result), so a person must write criteria and move it to Ready."
      fi
      local_comment "$new" "$backlog_msg" \
        || printf 'fleet-board: warning: Backlog comment failed for #%s\n' "$new" >&2
    fi
    pr_comment "Out of scope, tracked as #$new: $title" "$new"
  fi
done <<<"$ITEMS"

emit
