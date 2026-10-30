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
  *) usage ;;
esac

fb_load_config

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

case "$CMD" in
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
