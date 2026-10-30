#!/usr/bin/env bash
# status.sh - prints the board, one section per state.
#
# Usage: status.sh [--all]
#
# Sections, in order: ready, in_progress, in_review, human_qa, blocked; with
# --all also backlog, done and wont_do. Each section is the state name on
# its own line, then one line per card:
#   #<n> <title> · round <r> · PR #<pr> · <implementor>/<reviewer>
# with the values from the card's manager note and "—" for a missing one
# ("PR —" when there is no PR). An empty section prints "(none)". A card
# whose note cannot be read prints "#<n> <title> · note unreadable".
# A ready card with an Acceptance section and unmet dependencies (deps.sh)
# ends its line with " · waits for <ref> (<state or column>)[, ...]", the
# reason tick-plan.sh plans wait with; if they cannot be looked up, with
# " · dependencies unreadable" (exit 1).
# When any ready card waits, a dependency graph follows the sections, built
# from the same lookups (no extra listing calls):
#   dependency graph
#   blocker <ref>          one section per blocker, then its waiting cards
#     #<n>                 (refs in another repo keep their owner/repo prefix)
#   critical path: <ref> -> ... -> <ref>   the longest chain of unmet deps
#   can start now: #<n>, ...               ready cards with no unmet dep
# A board with no waiting card prints no graph.
#
# Exit codes:
#   0 - board printed
#   1 - a column could not be listed, or a card's note could not be read
#   2 - usage error

set -uo pipefail
unset CDPATH # a relative cd must not follow CDPATH (it would also echo the path)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

STATES="ready in_progress in_review human_qa blocked"
case "$#:${1:-}" in
  0:) ;;
  1:--all) STATES="$STATES backlog done wont_do" ;;
  *) fb_die 2 "usage: status.sh [--all]" ;;
esac

fb_load_config

DEPS_FILE="$(mktemp)" || fb_die 1 "cannot create a temp file"
EDGES_FILE="$(mktemp)" || fb_die 1 "cannot create a temp file"
START_FILE="$(mktemp)" || fb_die 1 "cannot create a temp file"
trap 'rm -f "$DEPS_FILE" "$EDGES_FILE" "$START_FILE"' EXIT

# waits_for <n>: prints the waiting reason of a ready card ("waits for ..."),
# nothing when it has no unmet dependency; fails when they cannot be looked up
waits_for() {
  local card body refs out
  card="$(bash "$FLEET_SCRIPTS/board-read.sh" "$1" </dev/null)" || return 1
  body="$(jq -r '.body // ""' <<<"$card" 2>/dev/null)" || return 1
  fb_has_acceptance "$body" || return 0
  printf '%s\n' "$body" > "$DEPS_FILE" || return 1
  grep -Eiq '^##[[:space:]]+depends[[:space:]]+on[[:space:]]*$' "$DEPS_FILE"
  case $? in 0) ;; 1) return 0 ;; *) return 1 ;; esac
  refs="$(bash "$FLEET_SCRIPTS/deps.sh" parse "$DEPS_FILE" | jq -c .refs)" || return 1
  [ "$refs" != '[]' ] || return 0
  out="$(bash "$FLEET_SCRIPTS/deps.sh" check "$1" "$refs" 2>/dev/null)" || return 1
  jq -c --arg c "$1" --arg r "$FLEET_REPO" \
    'select((.unmet | length) > 0) | {card: ("#" + $c), blockers: [.unmet[].ref | if startswith($r + "#") then sub("^.*#"; "#") else . end]}' \
    <<<"$out" >> "$EDGES_FILE" 2>/dev/null
  jq -r 'if (.unmet | length) == 0 then empty
         else "waits for \([.unmet[] | "\(.ref) (\(.status | gsub("[[:cntrl:]]"; " ")))"] | join(", "))" end' <<<"$out"
}

RC=0
for st in $STATES; do
  LIST="$(bash "$FLEET_SCRIPTS/board-list.sh" "$st")" || fb_die 1 "cannot list the $st column"
  ROWS="$(jq -c 'if type == "array" then .[] | {number, title} else error("not a list") end' <<<"$LIST" 2>/dev/null)" \
    || fb_die 1 "cannot parse the $st column"
  printf '%s\n' "$st"
  if [ -z "$ROWS" ]; then
    printf '  (none)\n'
    continue
  fi
  while IFS= read -r row; do
    n="$(jq -r .number <<<"$row")"
    title="$(jq -r '.title // "" | gsub("[[:cntrl:]]"; " ")' <<<"$row")"
    fb_valid_number "$n" || fb_die 1 "the $st column lists a non-numeric card: $n"
    if ! note="$(bash "$FLEET_SCRIPTS/note.sh" get "$n" </dev/null)"; then
      printf '  #%s %s · note unreadable\n' "$n" "$title"
      RC=1
      continue
    fi
    suffix=""
    if [ "$st" = ready ]; then
      if wf="$(waits_for "$n")"; then
        if [ -z "$wf" ]; then printf '#%s\n' "$n" >> "$START_FILE"; else suffix=" · $wf"; fi
      else
        suffix=" · dependencies unreadable"; RC=1
      fi
    fi
    jq -r --arg n "$n" --arg t "$title" --arg sfx "$suffix" '
      def v: if . == null then "—" else tostring | gsub("[[:cntrl:]]"; " ") end;
      def m($k): if type == "object" then .[$k] | v else "—" end;
      "  #\($n) \($t) · round \(.round | v) · PR \(if .pr == null then "—" else "#\(.pr)" end) · \(.models | m("implementor"))/\(.models | m("reviewer"))\($sfx)"' \
      <<<"$note" || { printf '  #%s %s · note unreadable\n' "$n" "$title"; RC=1; }
  done <<<"$ROWS"
done

if [ -s "$EDGES_FILE" ]; then
  jq -rs --arg starts "$(paste -sd, "$START_FILE")" '
    . as $e
    | ($e | map(.card)) as $waiting
    | def nxt($n): [$e[] | select(.blockers | index($n)) | .card];
      def longest($n; $seen):
        [nxt($n)[] | . as $x | select($seen | index($x) | not) | longest($x; $seen + [$x])] as $subs
        | if ($subs | length) == 0 then [$n]
          else [$n] + ($subs | max_by(length)) end;
    ([$e[].blockers[]] | unique) as $blockers
    | "dependency graph",
      ($blockers[] as $b | "blocker \($b)", (nxt($b)[] | "  \(.)")),
      ([$blockers[] | . as $x | select($waiting | index($x) | not) | longest($x; [$x])] | max_by(length)) as $cp
      | "critical path: \(if $cp == null then "(none)" else ($cp | join(" -> ")) end)",
      "can start now: \(if $starts == "" then "(none)" else ($starts | split(",") | join(", ")) end)"' "$EDGES_FILE" || RC=1
fi
exit "$RC"
