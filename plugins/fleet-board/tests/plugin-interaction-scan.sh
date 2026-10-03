#!/usr/bin/env bash
#
# plugin-interaction-scan.sh FILE...
#
# Scans Claude Code stream-json transcripts (claude -p --output-format
# stream-json --verbose) for signs that another plugin, a hook's injected text
# or the user's CLAUDE.md pulled a role session off its spec. For each FILE it
# prints one tab-separated line:
#
#   <file>  foreign_skill=<n>  foreign_agent=<n>  ask_user=<n>  pr_create=<n>  browser=<n>  plugins=<a,b,...>
#
#   foreign_skill  Skill tool_use calls whose input.skill does not start with
#                  "fleet-board:"
#   foreign_agent  Agent tool_use calls whose input.subagent_type does not
#                  start with "fleet-board:" (a missing subagent_type is the
#                  general-purpose agent, so it counts)
#   ask_user       AskUserQuestion tool_use calls
#   pr_create      Bash tool_use commands containing "gh pr create"
#   browser        Bash tool_use commands with "--web" as a whole flag
#                  (preceded by start or whitespace, followed by end,
#                  whitespace or ; & |, so --webhook-url and --website do not
#                  count), "xdg-open", or "open " / "gh browse" at the start of
#                  the command or after ; & | or a newline
#   plugins        plugin names from the first system/init event, in order
#
# Counts include subagent events: those arrive in the parent's stream as their
# own lines carrying parent_tool_use_id, and every event is searched with "..".
# Each command counts at most once per signal. Lines that are not JSON objects
# (or a truncated last line from a killed run) are skipped.
#
# Exit: 0 when every file was scanned, 1 when a file was missing or unreadable
# (the others are still scanned), 2 on usage error.
#
# Portable: bash 3.2, jq.

set -uo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: plugin-interaction-scan.sh FILE..." >&2
  exit 2
fi

# shellcheck disable=SC2016
FILTER='
  [ inputs | fromjson? | objects ] as $events
  | [ $events[] | .. | objects | select(.type == "tool_use") ] as $uses
  | [ $uses[] | select(.name == "Bash") | (.input.command // "") | strings ] as $cmds
  | ( [ $events[] | select(.type == "system" and .subtype == "init") ][0].plugins // [] ) as $plugins
  | [ $file,
      "foreign_skill=\([ $uses[] | select(.name == "Skill")
                          | select(((.input.skill // "") | tostring | startswith("fleet-board:")) | not) ] | length)",
      "foreign_agent=\([ $uses[] | select(.name == "Agent")
                          | select(((.input.subagent_type // "") | tostring | startswith("fleet-board:")) | not) ] | length)",
      "ask_user=\([ $uses[] | select(.name == "AskUserQuestion") ] | length)",
      "pr_create=\([ $cmds[] | select(contains("gh pr create")) ] | length)",
      "browser=\([ $cmds[] | select(test("(^|[ \t\n])--web($|[ \t\n;&|])") or contains("xdg-open")
                                     or test("(^|[;&|\n])[ \t]*open ")
                                     or test("(^|[;&|\n])[ \t]*gh[ \t]+browse($|[ \t\n;&|])")) ] | length)",
      "plugins=\([ $plugins[] | if type == "object" then .name else . end | strings ] | join(","))"
    ]
  | join("\t")
'

rc=0
for f in "$@"; do
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then
    printf 'plugin-interaction-scan: cannot read %s\n' "$f" >&2
    rc=1
    continue
  fi
  if ! jq -nrR --arg file "$f" "$FILTER" <"$f"; then
    printf 'plugin-interaction-scan: jq failed on %s\n' "$f" >&2
    rc=1
  fi
done
exit "$rc"
