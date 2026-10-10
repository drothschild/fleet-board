#!/usr/bin/env bash
#
# Plain-bash lint: no agent, skill or clean-room spec may name a file that
# Claude Code refuses to let a subagent write.
#
# Claude Code's Write tool refuses, for any subagent, a file whose base name
# matches ^(REPORT|SUMMARY|FINDINGS|ANALYSIS).*\.md$ (case-insensitive), with
# "Subagents should return findings as text, not write report files". Every
# fleet-board role runs as a subagent and writes its report, note-patch and
# comment files with Write, so a guidance file that names such a file (as an
# example or a rule) makes the refusal likely, and a refused report is never
# checked or reconciled.
#
# A guard-matching name counts only when no file of that base name exists in
# the repository: an existing file (the reporting skill's spec, reporting.md)
# is a reference an agent reads, not a file it is told to write.
#
# Usage: bash plugins/fleet-board/tests/test-write-names.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO="$(cd "$PLUGIN/../.." && pwd)"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

GUARD='(report|summary|findings|analysis)[A-Za-z0-9._-]*\.md'

# offending_names <root> <file>...: prints "<file>: <name>" for each
# guard-matching file name mentioned in the files that no file under <root>
# carries as its base name
offending_names() {
  local root="$1" f name
  shift
  for f in "$@"; do
    [ -f "$f" ] || continue
    grep -oiE "(^|[^A-Za-z0-9_])$GUARD" "$f" 2>/dev/null \
      | sed -E 's/^[^A-Za-z0-9_]//' | sort -u \
      | while IFS= read -r name; do
          [ -n "$name" ] || continue
          if [ -z "$(find "$root" -name "$name" -not -path '*/.git/*' -print -quit 2>/dev/null)" ]; then
            printf '%s: %s\n' "$f" "$name"
          fi
        done
  done
}

echo "Test: write names"
echo ""

# The lint can fail: an invented report name is flagged, a mention of an
# existing file is not
SELF="$(mktemp -d)"
trap 'rm -rf "$SELF"' EXIT
printf 'Write your report to report-12.md, then post it.\nSee FINDINGS_round2.MD too.\n' > "$SELF/bad.md"
printf 'Read reporting.md first.\n' > "$SELF/good.md"
: > "$SELF/reporting.md"
got="$(offending_names "$SELF" "$SELF/bad.md" "$SELF/good.md")"
case "$got" in
  *"bad.md: report-12.md"*) pass "self-test: an invented report-*.md name is flagged" ;;
  *) fail "self-test: an invented report-*.md name is flagged" "got: $got" ;;
esac
case "$got" in
  *"FINDINGS_round2.MD"*) pass "self-test: matching is case-insensitive" ;;
  *) fail "self-test: matching is case-insensitive" "got: $got" ;;
esac
case "$got" in
  *"good.md"*) fail "self-test: a mention of an existing file is not flagged" "got: $got" ;;
  *) pass "self-test: a mention of an existing file is not flagged" ;;
esac

# The real guidance: agents, skills, and the clean-room specs and briefs
FILES=""
for f in "$PLUGIN"/agents/*.md "$PLUGIN"/skills/*/SKILL.md "$PLUGIN"/skills/*/references/*.md \
         "$REPO"/docs/implementation-plans/*/specs/*.md "$REPO"/docs/implementation-plans/*/specs/briefs/*.md; do
  [ -f "$f" ] && FILES="$FILES
$f"
done
count="$(printf '%s\n' "$FILES" | grep -c . || true)"
if [ "$count" -gt 0 ]; then pass "found $count guidance files to scan"; else fail "found guidance files to scan" "none found"; fi

found=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  found="$found$(offending_names "$REPO" "$f")"
done <<EOF
$FILES
EOF
if [ -z "$found" ]; then
  pass "no guidance file names a file a subagent may not write"
else
  fail "no guidance file names a file a subagent may not write" "$found"
fi

echo ""
echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
