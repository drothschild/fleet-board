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
#   1. Pass one searches for every item before anything is written:
#        gh issue list --state open --search "<terms> in:title"
#      where <terms> is the title with each character outside [A-Za-z0-9 _-]
#      turned into a space. A returned row matches when its title equals the
#      item's title, case-insensitively. Any search failure exits 1 having
#      filed nothing.
#   2. Pass two files each item:
#        match      gh issue comment <existing> "Also seen while working #<card> (PR #<pr>).",
#                   then gh pr comment "<Known bug|Out of scope>, already tracked as #<existing>: <title>"
#        out of scope, no match
#                   board-create.sh "<title>" (detail + "Found while working #<card> (PR #<pr>).")
#                   then gh pr comment "Out of scope, tracked as #<new>: <title>"
#        bug, no match
#                   board-create.sh "<title>" (## Bug/Repro/Expected/Observed body) --label bug
#                   then gh pr comment "Bug found outside this card, filed as #<new>: <title>"
#      An item counts as filed once its create or its existing-issue comment
#      succeeds. A failed PR comment only warns on stderr:
#        fleet-board: warning: PR comment failed for #<n>
#
# Prints {"out_of_scope_created":[{title,number,existing}], "bugs_filed":[...]}.
#
# Exit codes:
#   0 - every item filed (or none to file); JSON printed
#   1 - nothing filed (the note, report, or a search failed; stdout empty), or
#       a create/existing-issue comment failed partway through pass two
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

BODY=""
trap 'rm -f ${BODY:+"$BODY"}' EXIT

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
while IFS= read -r item; do
  [ -n "$item" ] || continue
  title="$(jq -r .title <<<"$item")" || fb_die 1 "cannot read an item title; nothing filed"
  terms="$(jq -r '.title | gsub("[^A-Za-z0-9 _-]"; " ")' <<<"$item")" || fb_die 1 "cannot build search terms; nothing filed"
  rows="$(gh issue list --repo "$FLEET_REPO" --state open --search "$terms in:title" --json number,title --limit 50 </dev/null)" \
    || fb_die 1 "open-issue search failed for: $title; nothing filed"
  m="$(jq -r --arg t "$title" '
    if type != "array" then error("not a list") else . end
    | [.[] | select((.title | type) == "string" and (.title | ascii_downcase) == ($t | ascii_downcase))]
    | .[0].number // "none"' <<<"$rows" 2>/dev/null)" || fb_die 1 "unexpected open-issue search result for: $title; nothing filed"
  [ "$m" = none ] || fb_valid_number "$m" || fb_die 1 "unexpected open-issue search result for: $title; nothing filed"
  MATCHES+=("$m")
done <<<"$ITEMS"

FILED_OOS='[]'
FILED_BUGS='[]'
emit() { jq -nc --argjson o "$FILED_OOS" --argjson b "$FILED_BUGS" '{out_of_scope_created: $o, bugs_filed: $b}'; }

# record <kind> <title> <number> <existing>
record() {
  local e; e="$(jq -nc --arg t "$2" --argjson n "$3" --argjson x "$4" '{title: $t, number: $n, existing: $x}')" || return 1
  if [ "$1" = bug ]; then FILED_BUGS="$(jq -c --argjson e "$e" '. + [$e]' <<<"$FILED_BUGS")"
  else FILED_OOS="$(jq -c --argjson e "$e" '. + [$e]' <<<"$FILED_OOS")"; fi
}

# stop <message>: print what was filed so far, then exit 1
stop() { emit; fb_die 1 "$1"; }

pr_comment() {
  gh pr comment "$PR" --repo "$FLEET_REPO" --body "$1" </dev/null >/dev/null \
    || printf 'fleet-board: warning: PR comment failed for #%s\n' "$2" >&2
}

# Pass two: file
i=0
while IFS= read -r item; do
  [ -n "$item" ] || continue
  m="${MATCHES[$i]}"
  i=$((i + 1))
  kind="$(jq -r .kind <<<"$item")"
  title="$(jq -r .title <<<"$item")"
  if [ "$m" != none ]; then
    gh issue comment "$m" --repo "$FLEET_REPO" --body "Also seen while working #$CARD (PR #$PR)." </dev/null >/dev/null \
      || stop "cannot comment on the existing issue #$m for: $title"
    record "$kind" "$title" "$m" true || stop "cannot record #$m"
    if [ "$kind" = bug ]; then label="Known bug"; else label="Out of scope"; fi
    pr_comment "$label, already tracked as #$m: $title" "$m"
    continue
  fi
  BODY="$(mktemp)" || stop "cannot create a temp file"
  if [ "$kind" = bug ]; then
    jq -r --arg c "$CARD" --arg p "$PR" '
      "## Bug\n\(.title)\n\n## Repro\n`\(.repro)`\n\n## Expected\n\(.expected)\n\n## Observed\n\(.observed)\n\nFound by fleet-board while working #\($c) (PR #\($p))."' \
      <<<"$item" > "$BODY" || stop "cannot write the card body for: $title"
    created="$(bash "$FLEET_SCRIPTS/board-create.sh" "$title" "$BODY" --label bug </dev/null)" || stop "cannot create the card for: $title"
  else
    jq -r --arg c "$CARD" --arg p "$PR" '
      (if .detail == "" then "" else "\(.detail)\n\n" end) + "Found while working #\($c) (PR #\($p))."' \
      <<<"$item" > "$BODY" || stop "cannot write the card body for: $title"
    created="$(bash "$FLEET_SCRIPTS/board-create.sh" "$title" "$BODY" </dev/null)" || stop "cannot create the card for: $title"
  fi
  rm -f "$BODY"
  BODY=""
  new="$(jq -r '.number' <<<"$created" 2>/dev/null)"
  fb_valid_number "$new" || stop "board-create.sh returned no card number for: $title"
  record "$kind" "$title" "$new" false || stop "cannot record #$new"
  if [ "$kind" = bug ]; then
    pr_comment "Bug found outside this card, filed as #$new: $title" "$new"
  else
    pr_comment "Out of scope, tracked as #$new: $title" "$new"
  fi
done <<<"$ITEMS"

emit
