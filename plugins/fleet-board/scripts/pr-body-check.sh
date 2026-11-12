#!/usr/bin/env bash
# pr-body-check.sh - refuses a fleet PR body that would close a GitHub issue or PR.
#
# Usage: pr-body-check.sh <file>     (a PR body; "-" reads stdin)
#
# Card numbers on the local board are not GitHub issue numbers, so a line like
# "Closes #253" in a fleet PR body closes whatever GitHub issue or PR has
# number 253 when the PR merges. A fleet PR names its card with a non-closing
# line such as "Local board card 253".
#
# Rejected, in any case, with or without a colon: close, closes, closed, fix,
# fixes, fixed, resolve, resolves, resolved, followed by "#<digits>",
# "<owner>/<repo>#<digits>" or a github.com issues or pull URL.
#
# Exit codes: 0 no closing reference; 1 at least one (each offending line on
# stderr, prefixed "pr-body-check: "); 2 usage or an unreadable file.
set -uo pipefail

[ $# -eq 1 ] || { echo "usage: pr-body-check.sh <file|->" >&2; exit 2; }
if [ "$1" = "-" ]; then
  body="$(cat)"
else
  [ -f "$1" ] && [ -r "$1" ] || { echo "pr-body-check: cannot read $1" >&2; exit 2; }
  body="$(cat "$1")"
fi

KW='(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved)'
REF='(([[:alnum:]_.-]+/[[:alnum:]_.-]+)?#[0-9]+|https?://(www\.)?github\.com/[^/[:space:]]+/[^/[:space:]]+/(issues|pull)/[0-9]+)'
PAT="(^|[^[:alnum:]_])${KW}:?[[:space:]]*${REF}"

hits="$(printf '%s\n' "$body" | LC_ALL=C grep -inE "$PAT")"
[ -z "$hits" ] && exit 0
printf '%s\n' "$hits" | while IFS= read -r line; do
  printf 'pr-body-check: closing keyword before an issue reference (line %s); name the card as "Local board card <n>"\n' "$line" >&2
done
exit 1
