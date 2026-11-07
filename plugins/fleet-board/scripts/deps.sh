#!/usr/bin/env bash
# deps.sh - the card dependency gate: reads a card's dependencies and looks
# each one up in the local card store.
#
# Usage:
#   deps.sh parse <body-file>
#   deps.sh parse-card <read-file>
#   deps.sh check <card-n> <refs-json>
#
# parse prints {"refs": [{"repo","number","ref"}], "warnings": [..]} for the
# card body in <body-file>. The section is a "## Depends on" heading (any
# case) and runs to the next heading. Each bullet ("-" or "*") holds one
# dependency: "#22" (a card on this board) or "owner/repo#22". Blank lines
# are ignored; any other line in the section is ignored too, with the warning
# "unrecognized dependency line: <line>" (tick-plan.sh prefixes the card).
# A ref repeated in the section counts once. "ref" is always "owner/repo#n".
#
# parse-card prints the same shape for a board-read.sh result in <read-file>:
# the refs are the card's "blocked_by" numbers in board.repo (the body is
# ignored, warnings are empty; a card without the field has no refs).
#
# check prints {"unmet": [{"ref","status"}], "warnings": [..]} for the refs
# (parse's list) that card <card-n> depends on. Each ref in board.repo is read
# from the local store: met when that card is done; unmet otherwise, with
# status its state. A wont_do card also warns "#<card-n> depends on <ref>,
# which was closed as not planned". A ref in another repo is outside this
# board: it is not looked up, counts as met, and warns "#<card-n> depends on
# <ref>, which is outside this board; not checked". A card that cannot be read
# prints
#   deps-lookup-failed: local card #<n>
# on stderr and exits 1, with nothing on stdout.
#
# check also follows "blocked_by" through the store from <card-n>: when the
# card is in a dependency cycle, each of its refs on the cycle is unmet with
# status "in a dependency cycle" (even a done one), and the warnings gain
# "#<n> is in a dependency cycle: #a, #b".
#
# Exit codes:
#   0 - printed
#   1 - a lookup failed, or the config could not be loaded (check)
#   2 - usage error

set -uo pipefail
unset CDPATH # a relative cd must not follow CDPATH (it would also echo the path)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

usage() { fb_die 2 "usage: deps.sh parse <body-file> | parse-card <read-file> | check <card-n> <refs-json>"; }

[ $# -ge 1 ] || usage
CMD="$1"
case "$CMD" in
  parse)
    [ $# -eq 2 ] || usage
    [ -f "$2" ] || fb_die 2 "file not found: $2"
    ;;
  parse-card)
    [ $# -eq 2 ] || usage
    [ -f "$2" ] || fb_die 2 "file not found: $2"
    ;;
  check)
    [ $# -eq 3 ] || usage
    fb_valid_number "$2" || fb_die 2 "card number must be numeric, got: $2"
    jq -e 'type == "array"' <<<"$3" >/dev/null 2>&1 || fb_die 2 "refs must be a JSON array, got: $3"
    ;;
  *) usage ;;
esac

fb_load_config
. "$FLEET_SCRIPTS/adapters/local/local-lib.sh"

# parse_body <file>: one "R<TAB>token" line per bullet that is a dependency and
# one "W<TAB>line" per other nonblank line of the section
parse_body() {
  LC_ALL=C awk '
    { sub(/\r$/, "") }
    /^#+[ \t]/ || /^#+$/ {
      h = tolower($0); gsub(/[ \t]+$/, "", h)
      on = (h ~ /^##[ \t]+depends[ \t]+on$/)
      next
    }
    !on { next }
    { line = $0; sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line) }
    line == "" { next }
    line ~ /^[-*][ \t]+(#[0-9]+|[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+#[0-9]+)$/ {
      tok = line; sub(/^[-*][ \t]+/, "", tok); print "R\t" tok; next
    }
    { print "W\t" line }
  ' "$1"
}

# lookup_failed <command>: names the failed lookup on stderr and exits 1
lookup_failed() { printf 'deps-lookup-failed: %s\n' "$1" >&2; exit 1; }

# check_ref <repo> <number>: prints {"met": bool, "status": s, "not_planned": bool, "outside": bool}
check_ref() {
  local repo="$1" num="$2" state status="" met=false np=false card
  if [ "$(printf '%s' "$repo" | tr 'A-Z' 'a-z')" != "$(printf '%s' "$FLEET_REPO" | tr 'A-Z' 'a-z')" ]; then
    jq -cn '{met: true, status: "", not_planned: false, outside: true}'
    return 0
  fi
  card="$(fl_read_card "$num" 2>/dev/null)" || lookup_failed "local card #$num"
  state="$(jq -r '.state // ""' <<<"$card" 2>/dev/null)" || lookup_failed "local card #$num"
  case "$state" in
    done) met=true ;;
    wont_do) np=true; status=wont_do ;;
    *) status="$state" ;;
  esac
  jq -cn --argjson met "$met" --arg status "$status" --argjson np "$np" '{met: $met, status: $status, not_planned: $np, outside: false}'
}

# local_cycle_members <n>: the card numbers (one per line, sorted) of the
# dependency cycle through local card <n> via blocked_by; nothing when <n> is on
# no cycle. One jq call reads every card's blocked_by, one awk walks the edges
# forward and backward from <n>; the members are the cards in both walks.
local_cycle_members() {
  local dir; dir="$(fl_cards_dir)"
  set -- "$1" "$dir"/*.json
  [ -e "$2" ] || return 0
  local n="$1"; shift
  jq -r 'select(type == "object" and (.number | type) == "number")
         | .number as $c | ((.blocked_by // []) | arrays)[] | select(type == "number") | "\($c) \(.)"' "$@" 2>/dev/null \
    | LC_ALL=C awk -v s="$n" '
        { out[$1] = out[$1] " " $2; inn[$2] = inn[$2] " " $1 }
        function walk(adj, seen,   q, h, t, k, m, i) {
          h = 1; t = 0
          m = split(adj[s], k, " "); for (i = 1; i <= m; i++) if (!(k[i] in seen)) { seen[k[i]] = 1; q[++t] = k[i] }
          while (h <= t) {
            m = split(adj[q[h++]], k, " ")
            for (i = 1; i <= m; i++) if (!(k[i] in seen)) { seen[k[i]] = 1; q[++t] = k[i] }
          }
        }
        END {
          walk(out, f); walk(inn, r)
          if (!(s in f)) exit
          for (x in f) if (x in r) print x
        }' | sort -n
}

emit_parse() {
  ROWS="$(parse_body "$1")" || fb_die 1 "cannot read $1"
  printf '%s\n' "$ROWS" | jq -R -s -c --arg repo "$FLEET_REPO" '
    def clean: gsub("[[:cntrl:]]"; " ");
    [split("\n")[] | select(length > 0) | split("\t") | {k: .[0], v: (.[1:] | join("\t"))}] as $rows
    | {refs: ([$rows[] | select(.k == "R") | .v
               | (if startswith("#") then $repo + . else . end)
               | capture("\\A(?<repo>.*)#(?<n>[0-9]+)\\z")
               | {repo, number: (.n | tonumber), ref: "\(.repo)#\(.n | tonumber)"}]
              | reduce .[] as $r ([]; if any(.[]; .ref | ascii_downcase == ($r.ref | ascii_downcase)) then . else . + [$r] end)),
       warnings: [$rows[] | select(.k == "W") | "unrecognized dependency line: \(.v | clean)"]}' \
    || fb_die 1 "cannot build the dependency list"
}

case "$CMD" in
  check)
    RESULTS=""
    CYC_MEMBERS="$(local_cycle_members "$2")"
    while IFS=$'\t' read -r repo num ref; do
      [ -n "$repo" ] || continue
      fb_valid_number "$num" || fb_die 2 "bad ref number: $num"
      r="$(check_ref "$repo" "$num")" || exit $?
      RESULTS="$RESULTS$(jq -c --arg ref "$ref" '. + {ref: $ref}' <<<"$r")"$'\n'
    done < <(jq -r '.[] | [.repo, (.number | tostring), .ref] | @tsv' <<<"$3")
    CYC_JSON="$(printf '%s\n' "$CYC_MEMBERS" | jq -R -s -c '[split("\n")[] | select(length > 0) | tonumber]')" || CYC_JSON='[]'
    printf '%s' "$RESULTS" | jq -s -c --argjson n "$2" --argjson cyc "$CYC_JSON" --arg repo "$(printf '%s' "$FLEET_REPO" | tr 'A-Z' 'a-z')" '
      def oncycle: (.ref | ascii_downcase) as $r
        | any($cyc[]; $r == ($repo + "#" + tostring));
      {unmet: ([.[] | select((.met | not) and (oncycle | not)) | {ref, status}]
               + [.[] | select(oncycle) | {ref, status: "in a dependency cycle"}]),
       warnings: ([.[] | select(.not_planned) | "#\($n) depends on \(.ref), which was closed as not planned"]
                  + [.[] | select(.outside) | "#\($n) depends on \(.ref), which is outside this board; not checked"]
                  + (if ($cyc | length) > 0 then ["#\($n) is in a dependency cycle: \($cyc | map("#" + tostring) | join(", "))"] else [] end))}'
    ;;
  parse)
    emit_parse "$2"
    ;;
  parse-card)
    jq -c --arg repo "$FLEET_REPO" '
      {refs: [(.blocked_by // [])[] | {repo: $repo, number: ., ref: "\($repo)#\(.)"}], warnings: []}' "$2" \
      || fb_die 1 "cannot build the dependency list"
    ;;
esac
