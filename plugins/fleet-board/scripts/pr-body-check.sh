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
# "<owner>/<repo>#<digits>", "GH-<digits>" or a github.com issues or pull URL,
# also when markdown marks (* _ ` < [) wrap the keyword or the reference.
# Commit messages can be checked the same way, since a squash merge copies
# them onto the default branch: git log --format=%B <range> | pr-body-check.sh -
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

# Markdown emphasis or code marks (* _ ` < [) may wrap the keyword or the reference.
KW='(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved)'
REF='(([[:alnum:]_.-]+/[[:alnum:]_.-]+)?#[0-9]+|gh-[0-9]+|https?://(www\.)?github\.com/[^/[:space:]]+/[^/[:space:]]+/(issues|pull)/[0-9]+)'
WRAP='[*_`<[]*'
PAT="(^|[^[:alnum:]_])${WRAP}${KW}${WRAP}[[:space:]]*:?[[:space:]]*${WRAP}${REF}"

hits="$(printf '%s\n' "$body" | LC_ALL=C grep -inE "$PAT")"
rc=$?
# grep exits 1 for no match; anything above that is a failure, never a pass.
[ "$rc" -gt 1 ] && { echo "pr-body-check: grep failed (exit $rc)" >&2; exit 2; }
[ -z "$hits" ] && exit 0
printf '%s\n' "$hits" | while IFS= read -r hit; do
  printf 'pr-body-check: closing keyword before an issue reference on line %s; name the card as "Local board card <n>": %s\n' \
    "${hit%%:*}" "${hit#*:}" >&2
done
exit 1
