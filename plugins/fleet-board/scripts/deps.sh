#!/usr/bin/env bash
# deps.sh - the card dependency gate: reads a card's "## Depends on" section
# and looks each dependency up.
#
# Usage:
#   deps.sh parse <body-file>
#   deps.sh check <card-n> <refs-json>
#
# parse prints {"refs": [{"repo","number","ref"}], "warnings": [..]} for the
# card body in <body-file>. The section is a "## Depends on" heading (any
# case) and runs to the next heading. Each bullet ("-" or "*") holds one
# dependency: "#22" (an issue in board.repo) or "owner/repo#22". Blank lines
# are ignored; any other line in the section is ignored too, with the warning
# "unrecognized dependency line: <line>" (tick-plan.sh prefixes the card).
# A ref repeated in the section counts once. "ref" is always "owner/repo#n".
#
# check prints {"unmet": [{"ref","status"}], "warnings": [..]} for the refs
# (parse's list) that card <card-n> depends on. Per dependency it runs
#   gh issue view <n> --repo <owner/repo> --json state,stateReason
# and, on the Projects backend, for a dependency (in any repo) that is not
# closed as completed or as not planned, the issue's Status on this board's
# project (fp_item_for). On the labels backend only the issue state counts.
# A dependency is met when its issue is closed as completed, or
# its Status is the done column. It is unmet otherwise, with status the
# Status column name when it has one, else "open", "closed as not planned",
# "closed as <reason>" or "closed". Closed as not planned, or Status Won't Do,
# also warns "#<card-n> depends on <ref>, which was closed as not planned".
# A lookup that fails (or answers something unexpected) prints
#   deps-lookup-failed: <command>
# on stderr and exits 1, with nothing on stdout.
#
# Exit codes:
#   0 - printed
#   1 - a lookup failed, or the config could not be loaded (check)
#   2 - usage error

set -uo pipefail
unset CDPATH # a relative cd must not follow CDPATH (it would also echo the path)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

usage() { fb_die 2 "usage: deps.sh parse <body-file> | check <card-n> <refs-json>"; }

[ $# -ge 1 ] || usage
CMD="$1"
case "$CMD" in
  parse)
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
. "$FLEET_SCRIPTS/adapters/github-projects/common.sh"

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

# check_ref <repo> <number>: prints {"met": bool, "status": s, "not_planned": bool}
check_ref() {
  local repo="$1" num="$2" cmd out state reason item pstatus status="" met=false np=false
  cmd="gh issue view $num --repo $repo --json state,stateReason"
  out="$(gh issue view "$num" --repo "$repo" --json state,stateReason)" || lookup_failed "$cmd"
  state="$(jq -r 'if (.state == "OPEN" or .state == "CLOSED") then .state else error("unexpected") end' <<<"$out" 2>/dev/null)" \
    || lookup_failed "$cmd (unexpected response)"
  reason="$(jq -r '.stateReason // ""' <<<"$out" 2>/dev/null)" || lookup_failed "$cmd (unexpected response)"
  if [ "$state" = CLOSED ] && [ "$reason" = COMPLETED ]; then
    met=true
  elif [ "$state" = CLOSED ] && [ "$reason" = NOT_PLANNED ]; then
    np=true; status="closed as not planned"
  else
    if [ "$state" = OPEN ]; then status=open
    elif [ -n "$reason" ]; then status="closed as $(printf '%s' "$reason" | tr 'A-Z_' 'a-z ')"
    else status=closed; fi
    if [ "$(fb_cfg board.backend)" = github-projects ]; then
      item="$(fp_item_for "$num" "$repo" 2>/dev/null)" || lookup_failed "gh api graphql (project items of $repo#$num)"
      pstatus="${item#*$'\t'}"
      if [ -n "$item" ] && [ -n "$pstatus" ]; then
        if [ "$pstatus" = "$(fb_state_name done)" ]; then met=true
        elif [ "$pstatus" = "$(fb_state_name wont_do)" ]; then np=true; status="$pstatus"
        else status="$pstatus"; fi
      fi
    fi
  fi
  jq -cn --argjson met "$met" --arg status "$status" --argjson np "$np" '{met: $met, status: $status, not_planned: $np}'
}

case "$CMD" in
  check)
    RESULTS=""
    while IFS=$'\t' read -r repo num ref; do
      [ -n "$repo" ] || continue
      fb_valid_number "$num" || fb_die 2 "bad ref number: $num"
      r="$(check_ref "$repo" "$num")" || exit $?
      RESULTS="$RESULTS$(jq -c --arg ref "$ref" '. + {ref: $ref}' <<<"$r")"$'\n'
    done < <(jq -r '.[] | [.repo, (.number | tostring), .ref] | @tsv' <<<"$3")
    printf '%s' "$RESULTS" | jq -s -c --argjson n "$2" '
      {unmet: [.[] | select(.met | not) | {ref, status}],
       warnings: [.[] | select(.not_planned) | "#\($n) depends on \(.ref), which was closed as not planned"]}'
    ;;
  parse)
    ROWS="$(parse_body "$2")" || fb_die 1 "cannot read $2"
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
    ;;
esac
