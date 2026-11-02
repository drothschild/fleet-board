#!/usr/bin/env bash
# after-merge.sh - a card's "## After merge" section: the commands the manager
# runs once the card's PR has merged.
#
# Usage:
#   after-merge.sh parse <body-file>
#   after-merge.sh run <body-file>
#
# parse prints {"commands": [..]}: one command per "-" or "*" bullet of the
# "## After merge" section (heading in any case, ending at the next heading).
# Other lines are ignored.
#
# run parses the same section and runs the commands in order, in the current
# directory. A command runs only when it starts with one of the prefixes in
# after_merge.allow of .fleet-board.yml (a whole-word prefix; a missing key
# allows nothing), and only when it holds none of ; & | ` $ < > or a newline,
# so an allowed prefix cannot chain another command. It stops at the first
# command that is refused or exits non-zero. It prints
#   {"outcome": "done"|"blocked", "results": [{command, status, exit}],
#    "note": [one line per command, for the card's note], "comment": text}
# status is ok, failed (exit holds the status) or refused (exit is null).
# comment is empty when the outcome is done. Exit 0 when printed.
#
# Exit codes:
#   0 - printed
#   1 - the config could not be loaded
#   2 - usage error

set -uo pipefail
unset CDPATH
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { echo "usage: after-merge.sh parse <body-file> | run <body-file>" >&2; exit 2; }

[ $# -eq 2 ] || usage
case "$1" in parse|run) ;; *) usage ;; esac
[ -f "$2" ] || { echo "file not found: $2" >&2; exit 2; }

commands_json() {
  LC_ALL=C awk '
    { sub(/\r$/, "") }
    /^#+[ \t]/ || /^#+$/ {
      h = tolower($0); gsub(/[ \t]+$/, "", h)
      on = (h ~ /^##[ \t]+after[ \t]+merge$/)
      next
    }
    !on { next }
    /^[-*][ \t]+/ {
      c = $0; sub(/^[-*][ \t]+/, "", c); sub(/[ \t]+$/, "", c)
      if (c != "") print c
    }
  ' "$1" | jq -R -s -c 'split("\n") | map(select(length > 0)) | {commands: .}'
}

if [ "$1" = parse ]; then
  commands_json "$2"
  exit 0
fi

ALLOW="$(bash "$HERE/config.sh" after_merge.allow)" || { echo "after-merge: cannot load config" >&2; exit 1; }
[ -n "$ALLOW" ] || ALLOW='[]'
CMDS="$(commands_json "$2" | jq -c '.commands')"

RESULTS='[]'
BLOCK=""
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  entry=""
  # the first allowlist prefix that matches whole words
  matched="$(jq -r --arg c "$cmd" '[.[] | select(. as $p | ($c == $p) or ($c | startswith($p + " ")))] | first // empty' <<<"$ALLOW")"
  case "$cmd" in
    *[\;\&\|\`\$\<\>]*) matched="" ;;
  esac
  if [ -z "$matched" ]; then
    RESULTS="$(jq -c --arg c "$cmd" '. + [{command: $c, status: "refused", exit: null}]' <<<"$RESULTS")"
    BLOCK="After merge: \`$cmd\` was not run: no after_merge.allow entry in .fleet-board.yml is a prefix of it (and it must hold no shell control characters). Add an entry such as \`$(printf '%s' "$cmd" | cut -d' ' -f1-2)\` to after_merge.allow."
    break
  fi
  bash -c "$cmd" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    RESULTS="$(jq -c --arg c "$cmd" '. + [{command: $c, status: "ok", exit: 0}]' <<<"$RESULTS")"
  else
    RESULTS="$(jq -c --arg c "$cmd" --argjson rc "$rc" '. + [{command: $c, status: "failed", exit: $rc}]' <<<"$RESULTS")"
    BLOCK="After merge: \`$cmd\` failed with exit $rc."
    break
  fi
done < <(jq -r '.[]' <<<"$CMDS")

jq -c --arg block "$BLOCK" '
  {outcome: (if $block == "" then "done" else "blocked" end),
   results: .,
   note: [.[] | "\(.command) -> " + (if .status == "refused" then "refused (not allowlisted)" else "exit \(.exit)" end)],
   comment: $block}' <<<"$RESULTS"
