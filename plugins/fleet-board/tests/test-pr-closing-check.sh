#!/usr/bin/env bash
#
# Plain-bash tests for scripts/pr-closing-check.sh: the merge-time check that a
# PR's title, body and every commit message hold no GitHub closing keyword
# before an issue reference (pr-body-check.sh over all three). A squash merge
# copies the title and the commit messages onto the default branch, and GitHub
# reads closing keywords in the PR body, so all three can close an unrelated
# issue or PR whose number matches a local card's.
# gh is a stub on PATH that prints $FAKE_PR_JSON and logs its arguments.
#
# Usage: bash plugins/fleet-board/tests/test-pr-closing-check.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CHECK="$SCRIPT_DIR/../scripts/pr-closing-check.sh"

PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  not ok %s\n' "$1"; printf '       %s\n' "$2"; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
[ "${FAKE_GH_RC:-0}" = 0 ] || exit "$FAKE_GH_RC"
cat "$FAKE_PR_JSON"
GH
chmod +x "$TMP/bin/gh"
export FAKE_GH_LOG="$TMP/gh.log" FAKE_PR_JSON="$TMP/pr.json"
PATH="$TMP/bin:$PATH"; export PATH

# pr_json TITLE BODY [HEADLINE BODY]...: the gh pr view --json title,body,commits shape
pr_json() {
  local title="$1" body="$2"; shift 2
  local commits='[]'
  while [ $# -ge 2 ]; do
    commits="$(jq -c --arg h "$1" --arg b "$2" '. + [{oid: "abcdef1234567890", messageHeadline: $h, messageBody: $b}]' <<<"$commits")"
    shift 2
  done
  jq -n --arg t "$title" --arg b "$body" --argjson c "$commits" '{title: $t, body: $b, commits: $c}' > "$FAKE_PR_JSON"
}

# run ARGS...: RC, ERR
run() {
  : > "$FAKE_GH_LOG"
  ERR="$(/bin/bash "$CHECK" "$@" 2>&1 >/dev/null)"
  RC=$?
}
expect() { # expect LABEL RC [ERR-SUBSTRING]
  if [ "$RC" = "$2" ] && { [ -z "${3:-}" ] || case "$ERR" in *"$3"*) true ;; *) false ;; esac; }; then pass "$1"
  else fail "$1" "rc=$RC (want $2) err=$ERR"; fi
}

echo "pr-closing-check.sh"

pr_json "Add subtract" "Local board card 253" "feat: subtract" "Local board card 253"
run 34 --repo acme/toy
expect "a clean PR passes" 0
if grep -qx 'pr view 34 --repo acme/toy --json title,body,commits' "$FAKE_GH_LOG"; then pass "reads title, body and commits of the named PR in the named repo"
else fail "reads title, body and commits of the named PR in the named repo" "$(cat "$FAKE_GH_LOG")"; fi
run 34
expect "no --repo: gh resolves the repo" 0
if grep -qx 'pr view 34 --json title,body,commits' "$FAKE_GH_LOG"; then pass "no --repo: no repo flag"
else fail "no --repo: no repo flag" "$(cat "$FAKE_GH_LOG")"; fi

pr_json "Closes #253 add subtract" "Local board card 253"
run 34 --repo acme/toy
expect "a closing keyword in the title is refused" 1 "PR #34"
expect "the refusal names the title" 1 "title"

pr_json "Add subtract" "$(printf 'Summary\n\nCloses #253')"
run 34 --repo acme/toy
expect "a closing keyword in the body is refused" 1 "Closes #253"

pr_json "Add subtract" "Local board card 253" "feat: subtract" "" "fix: fixes #12 for real" ""
run 34 --repo acme/toy
expect "a closing keyword in a commit headline is refused" 1 "commit abcdef1"

pr_json "Add subtract" "Local board card 253" "feat: subtract" "$(printf 'Longer text.\n\nResolves: owner/repo#4')"
run 34 --repo acme/toy
expect "a closing keyword in a commit body is refused" 1 "Resolves: owner/repo#4"

pr_json "Add subtract" "Local board card 253" "feat: subtract fixes" "#12 is unrelated"
run 34 --repo acme/toy
expect "a headline and its body are separate paragraphs (no split hit across them)" 0

pr_json "Add subtract" "$(printf 'The fix closes\n#253')"
run 34 --repo acme/toy
expect "a split hit in the body is refused" 1

# GitHub cuts a long subject at about 70 characters: messageHeadline ends in
# "…" and messageBody opens with "…" and the rest of the line. The squash
# commit carries the whole line, so the two halves are joined before the check.
pr_json "Add subtract" "Local board card 1" "feat: a long subject that goes on and on and on, Closes…" "… #253 more"
run 34
expect "a keyword before the cut and its reference after it is refused" 1 "Closes #253"
pr_json "Add subtract" "Local board card 1" "feat: a long subject that goes on and on and on and on, Clo…" "…ses #253"
run 34
expect "a keyword cut in two is refused" 1 "Closes #253"
pr_json "Add subtract" "Local board card 1" "feat: ends with an ellipsis…" "Body names card 253."
run 34
expect "a headline ending in an ellipsis with an ordinary body passes" 0

# Malformed input never breaks the report or the check.
jq -n '{title: "t", body: "b", commits: [{oid: "a/b&c\\x", messageHeadline: "Fixes #1", messageBody: ""}]}' > "$FAKE_PR_JSON"; run 34
expect "an oid with sed metacharacters still names the commit hit" 1 "commit a: "
{ jq -n '{title: "t", body: "b", commits: []}'; jq -n '{title: "t", body: "b", commits: []}'; } > "$FAKE_PR_JSON"; run 34
expect "two JSON documents exit 3" 3

# Fails closed: never a pass when the PR cannot be read in full.
FAKE_GH_RC=1 run 34 --repo acme/toy
expect "gh failure exits 3" 3
printf 'not json\n' > "$FAKE_PR_JSON"; run 34
expect "unparsable reply exits 3" 3
jq -n '{title: "t", commits: []}' > "$FAKE_PR_JSON"; run 34
expect "a reply without body exits 3" 3
jq -n '{title: "t", body: "b"}' > "$FAKE_PR_JSON"; run 34
expect "a reply without commits exits 3" 3
jq -n '{title: "t", body: "b", commits: [{oid: "a", messageHeadline: "h"}]}' > "$FAKE_PR_JSON"; run 34
expect "a commit without messageBody exits 3" 3
jq -n '{title: "t", body: "b", commits: [range(100) | {oid: "a", messageHeadline: "h", messageBody: ""}]}' > "$FAKE_PR_JSON"; run 34
expect "100 commits (gh may have truncated the list) exits 3" 3
jq -n '{title: "t", body: null, commits: []}' > "$FAKE_PR_JSON"; run 34
expect "a null body (no description) passes" 0

# --json reads gh's JSON from a file or stdin and makes no gh call.
pr_json "t" "Fixes #1"
run --json "$FAKE_PR_JSON"
expect "--json <file>: refused" 1
if [ ! -s "$FAKE_GH_LOG" ]; then pass "--json: no gh call"; else fail "--json: no gh call" "$(cat "$FAKE_GH_LOG")"; fi
ERR="$(/bin/bash "$CHECK" --json - < "$FAKE_PR_JSON" 2>&1 >/dev/null)"; RC=$?
expect "--json -: reads stdin" 1
pr_json "t" "Local board card 1"
ERR="$(/bin/bash "$CHECK" --json - < "$FAKE_PR_JSON" 2>&1 >/dev/null)"; RC=$?
expect "--json -: clean passes" 0

# Usage.
run; expect "no argument exits 2" 2
run abc; expect "a non-numeric PR exits 2" 2
run 34 --repo; expect "--repo without a value exits 2" 2
run 34 --bogus x; expect "an unknown flag exits 2" 2
run --json "$TMP/missing"; expect "--json with a missing file exits 2" 2

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
