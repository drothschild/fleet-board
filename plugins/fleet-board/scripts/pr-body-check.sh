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
# also when markdown marks (* _ ` ~ < [) or HTML tags wrap the keyword, the
# colon or the reference.
# GitHub documents only "KEYWORD #N" and "KEYWORD OWNER/REPO#N", with an
# optional colon, in any case. The rest is caught anyway, since a false
# positive costs a reword and a miss closes an unrelated issue: GH-<digits>,
# URLs (also without a scheme), a no-break space (U+00A0 or U+202F) for the
# space, and a keyword ending one line with the reference opening the next.
# Commit messages can be checked the same way, since a squash merge copies
# them onto the default branch: git log --format=%B <range> | pr-body-check.sh -
# (pr-closing-check.sh does this for a PR's title, body and commits at merge.)
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

# A no-break space reads as a space.
body="$(printf '%s\n' "$body" | LC_ALL=C sed $'s/\xc2\xa0/ /g; s/\xe2\x80\xaf/ /g')" \
  || { echo "pr-body-check: sed failed" >&2; exit 2; }

# Markdown emphasis, strikethrough or code marks (* _ ` ~ < [) and HTML tags
# may wrap the keyword, the colon or the reference.
KW='(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved)'
REF='(([[:alnum:]_.-]+/[[:alnum:]_.-]+)?#[0-9]+|gh-[0-9]+|(https?://)?(www\.)?github\.com/[^/[:space:]]+/[^/[:space:]]+/(issues|pull)/[0-9]+)'
WRAP='([*_`~<[]|<[^>]*>)*'
GAP="[[:space:]]*${WRAP}:?${WRAP}[[:space:]]*"
J=$'\001' # joins a line to the next one
PAT="(^|[^[:alnum:]_])${WRAP}${KW}${WRAP}${GAP}${WRAP}${REF}"
SPLIT="(^|[^[:alnum:]_])${WRAP}${KW}${WRAP}${GAP}${J}${GAP}${WRAP}${REF}"

# run_grep PATTERN: the matching lines, numbered; exit 2 when grep fails
run_grep() {
  LC_ALL=C grep -inE "$1"
  rc=$?
  # grep exits 1 for no match; anything above that is a failure, never a pass.
  [ "$rc" -gt 1 ] && { echo "pr-body-check: grep failed (exit $rc)" >&2; return 2; }
  return 0
}

hits="$(printf '%s\n' "$body" | run_grep "$PAT")" || exit 2
# each line joined to the next by $J, numbered by the first: a split hit
pairs="$(printf '%s\n' "$body" | LC_ALL=C awk 'NR > 1 { printf "%s\001%s\n", prev, $0 } { prev = $0 }')" \
  || { echo "pr-body-check: awk failed" >&2; exit 2; }
split="$(printf '%s\n' "$pairs" | run_grep "$SPLIT")" || exit 2
[ -z "$hits" ] && [ -z "$split" ] && exit 0
MSG='pr-body-check: closing keyword before an issue reference on %s; name the card as "Local board card <n>": %s\n'
[ -z "$hits" ] || printf '%s\n' "$hits" | while IFS= read -r hit; do
  printf "$MSG" "line ${hit%%:*}" "${hit#*:}" >&2
done
[ -z "$split" ] || printf '%s\n' "$split" | while IFS= read -r hit; do
  n="${hit%%:*}"
  printf "$MSG" "lines $n-$((n + 1))" "$(printf '%s' "${hit#*:}" | tr '\001' ' ')" >&2
done
exit 1
