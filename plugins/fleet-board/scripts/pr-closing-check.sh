#!/usr/bin/env bash
# pr-closing-check.sh - refuses a PR whose merge would close a GitHub issue or PR.
#
# Usage: pr-closing-check.sh <pr> [--repo <owner/repo>]
#        pr-closing-check.sh --json <file|->   (gh pr view --json title,body,commits output)
#
# Card numbers on the local board are not GitHub numbers. GitHub closes the
# issue or PR a closing keyword names when the PR merges: from the PR body,
# and from every commit message that reaches the default branch (a squash
# merge copies the PR title and the commit messages there). So the merge-time
# check runs pr-body-check.sh over the PR title, the PR body and every commit
# message, whichever role or person wrote them. merge-reviewed.sh runs it
# before gh pr merge, and the gate runs it (--json) before a fleet PR's merge.
#
# The PR is read with gh pr view <pr> [--repo R] --json title,body,commits.
# gh reads at most 100 commits, so a list of 100 or more cannot be checked in
# full and is refused like an unreadable PR.
#
# Exit codes: 0 no closing reference; 1 at least one (a summary line, then
# one line per hit naming its part: title, body or commit <sha>, on stderr);
# 2 usage; 3 the PR could not be read, parsed or checked in full (never a pass).
set -uo pipefail
unset CDPATH

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { echo "usage: pr-closing-check.sh <pr> [--repo <owner/repo>] | --json <file|->" >&2; exit 2; }

[ $# -ge 1 ] || usage
if [ "$1" = --json ]; then
  [ $# -eq 2 ] || usage
  if [ "$2" = - ]; then
    json="$(cat)"
  else
    [ -f "$2" ] && [ -r "$2" ] || { echo "pr-closing-check: cannot read $2" >&2; exit 2; }
    json="$(cat "$2")"
  fi
  what="the PR"
else
  case "$1" in ''|*[!0-9]*) usage ;; esac
  pr="$1"; shift
  args=(pr view "$pr")
  if [ $# -gt 0 ]; then
    [ $# -eq 2 ] && [ "$1" = --repo ] && [ -n "$2" ] || usage
    args+=(--repo "$2")
  fi
  args+=(--json title,body,commits)
  json="$(gh "${args[@]}" </dev/null)" || { echo "pr-closing-check: cannot read PR #$pr" >&2; exit 3; }
  what="PR #$pr"
fi

# Exactly one JSON document.
json="$(jq -cs 'if length == 1 then .[0] else error("not one document") end' <<<"$json" 2>/dev/null)" \
  || { echo "pr-closing-check: cannot check $what in full (not one JSON reply)" >&2; exit 3; }

# GitHub cuts a long commit subject at about 70 characters: messageHeadline
# ends in "…" and messageBody opens with "…" and the rest of the line. The
# commit on main holds the whole line, so the halves are joined again.
MSG='def msg: if (.messageHeadline | endswith("…")) and (.messageBody | startswith("…"))
  then (.messageHeadline | .[0:length - 1]) + (.messageBody | .[1:])
  else .messageHeadline + "\n\n" + .messageBody end;
def commit_label: "commit \((.oid // "") | tostring | gsub("[^0-9a-fA-F]"; "") | .[0:7])";'

# Title, body, then each commit (headline, a blank line, the body), each part
# opening with a label line so a reference cannot run on from the part before.
text="$(jq -er "$MSG"'
  def str: type == "string";
  if type == "object" and (.title | str) and has("body") and (.body | str or . == null)
     and (.commits | type == "array") and (.commits | length) < 100
     and all(.commits[]; type == "object" and (.messageHeadline | str) and (.messageBody | str))
  then
    "PR title:", .title, "", "PR body:", (.body // ""),
    (.commits[] | "", commit_label + ":", msg)
  else error("unexpected shape") end' <<<"$json" 2>/dev/null)" \
  || { echo "pr-closing-check: cannot check $what in full (unreadable reply, or 100 or more commits)" >&2; exit 3; }

details="$(printf '%s\n' "$text" | bash "$HERE/pr-body-check.sh" - 2>&1 >/dev/null)"
case $? in
  0) exit 0 ;;
  1) ;;
  *) printf '%s\n' "$details" >&2; echo "pr-closing-check: cannot check $what" >&2; exit 3 ;;
esac
printf 'pr-closing-check: %s holds a GitHub closing keyword before an issue reference in its title, body or a commit message; card numbers are not GitHub numbers, so it is not merged\n' "$what" >&2
# Name the part each hit is in: check the parts one by one (only on a hit,
# so a clean PR costs one check). The label lines keep parts apart, so the
# parts' hits are the whole text's hits.
labels="$(jq -r "$MSG"'"title", "body", (.commits[] | commit_label)' <<<"$json")" || exit 3
i=0
while IFS= read -r label; do
  part="$(jq -r --argjson i "$i" "$MSG"'[.title, (.body // ""), (.commits[] | msg)][$i]' <<<"$json")" || exit 3
  printf '%s\n' "$part" | bash "$HERE/pr-body-check.sh" - 2>&1 >/dev/null | sed "s/^pr-body-check: /pr-closing-check: $label: /" >&2
  i=$((i + 1))
done <<<"$labels"
exit 1
