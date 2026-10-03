#!/usr/bin/env bash
#
# Behavioral scenarios for the fleet-board role agents. NOT an offline suite:
# it drives real headless Claude sessions against the sandbox repo named by
# SANDBOX_REPO, and asserts on the commits, PRs and card comments they leave.
#
# Usage: SANDBOX_REPO=owner/name bash plugins/fleet-board/tests/behavioral-role.sh <scenario>
#
# Scenarios: implementor, implementor-no-acceptance, review-good,
#            review-unmapped, review-survivor, review-toggles-off, fixer,
#            review-tamper
#
# Env:
#   RUN              keep transcripts here (default $TMPDIR/fb-p5/behavioral/<scenario>-<ts>)
#   EXPECT_SURVIVED  review-survivor only: assert .mutation.survived == this value
#                    instead of >= 1 (used to prove the harness can fail); a
#                    non-negative integer, anything else exits 2
#
# Exit: 0 all assertions passed, 1 any failure, 2 SANDBOX_REPO unset, bad
# EXPECT_SURVIVED or usage.

set -uo pipefail
unset CDPATH

SCENARIOS="implementor implementor-no-acceptance review-good review-unmapped review-survivor review-toggles-off fixer review-tamper"
usage() { printf 'usage: SANDBOX_REPO=owner/name %s <%s>\n' "$0" "$(echo $SCENARIOS | tr ' ' '|')" >&2; exit 2; }

[ -n "${SANDBOX_REPO:-}" ] || { echo "behavioral-role: SANDBOX_REPO is not set" >&2; exit 2; }
[ $# -eq 1 ] || usage
SCENARIO="$1"
case " $SCENARIOS " in *" $SCENARIO "*) ;; *) usage ;; esac
# EXPECT_SURVIVED is interpolated into jq filters: only a plain integer is allowed.
case "${EXPECT_SURVIVED-}" in
  *[!0-9]*) echo "behavioral-role: EXPECT_SURVIVED must be a non-negative integer, got: $EXPECT_SURVIVED" >&2; exit 2 ;;
esac
if [ "${EXPECT_SURVIVED+set}" = set ] && [ -z "$EXPECT_SURVIVED" ]; then
  echo "behavioral-role: EXPECT_SURVIVED is set but empty" >&2; exit 2
fi

. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/behavioral-lib.sh"

PATCHES="$BL_FIX/patches"
trap cleanup EXIT
trap 'exit 130' INT TERM

bl_init_run "$SCENARIO"
prepare

# --- prompt builders --------------------------------------------------------

# implementor_prompt OUT [NOTE]
implementor_prompt() {
  local note="${2:-none. This is the first dispatch for this card; no PR exists yet.}"
  cat >"$1" <<EOF
Card number: $CARD
Card (JSON from board-read.sh $CARD; its body holds the Acceptance section):
$(cd "$CLONE" && bash "$S/board-read.sh" "$CARD")

Worktree path: $WT
Branch: $BRANCH (already checked out in the worktree)
Config JSON (from config.sh):
$(config_json '{commands, test_paths, human_qa_paths}')

Manager note: $note
Scripts directory: $S
EOF
}

# reviewer_prompt OUT ROUND REF_SHA REPORT_FILE CONFIG_JSON_FILE
reviewer_prompt() {
  cat >"$1" <<EOF
Card number: $CARD
Card body:
$(cd "$CLONE" && bash "$S/board-read.sh" "$CARD" | jq -r .body)

PR number: $PR
PR diff (gh pr diff $PR):
$(gh pr diff "$PR" --repo "$SANDBOX_REPO")

Latest implementor or fixer report (report text only):
$(cat "$4")

Review worktree (checked out at the PR head): $RWT
Config JSON:
$(cat "$5")

Review round: $2
Reference SHA ($( [ "$2" = 1 ] && echo "round-1 base SHA" || echo "head SHA the previous review examined")): $3
Scripts directory: $S
EOF
}

# fixer_prompt OUT FINDINGS_TEXT
fixer_prompt() {
  cat >"$1" <<EOF
Card (JSON from board-read.sh $CARD):
$(cd "$CLONE" && bash "$S/board-read.sh" "$CARD" | jq '{number, title, body}')

PR number: $PR
Worktree (checked out at the PR branch $BRANCH): $WT
Findings from the latest review (Critical and Important):
$2

Config JSON:
$(config_json '{commands, test_paths}')
Scripts directory: $S
EOF
}

# harness_report TEMPLATE OUT: a fixture report with this run's PR number and
# the real pass count of test/calc.test.js at the PR head
harness_report() {
  local n; n="$(pass_count "$WT" test/calc.test.js)"
  [ -n "$n" ] || bl_die "cannot count passing tests in $WT"
  sed -e "s/^#12\$/#$PR/" \
      -e "s|^VERIFIED: .*|VERIFIED: \`node --test test/calc.test.js\` -> $n passing tests|" "$1" >"$2"
  bash "$S/parse-report.sh" "$2" >/dev/null || bl_die "harness report $2 does not parse"
}

# --- shared review flow -----------------------------------------------------

# run_review PATCH CONFIG_FILTER: good-path PR, implementor report, reviewer round 1
run_review() {
  new_card "$BL_FIX/card-subtract.md"
  open_patch_pr "$PATCHES/$1"
  harness_report "$BL_REPORTS/implementor-ok.md" "$RUN/implementor-report.md"
  post_report "$CARD" "$RUN/implementor-report.md"
  review_worktree
  config_json "{commands, review, test_paths, worktrees} | $2" >"$RUN/review-config.json"
  reviewer_prompt "$RUN/reviewer-prompt.txt" 1 "$BASE_SHA" "$RUN/implementor-report.md" "$RUN/review-config.json"
  local head_before; head_before="$(git -C "$CLONE" rev-parse "origin/$BRANCH")"
  dispatch_role reviewer opus "$RUN/reviewer-prompt.txt"
  reviewer_common "$head_before"
}

# reviewer_common HEAD_BEFORE: report parses; the reviewer changed nothing
reviewer_common() {
  latest_report "$CARD" "$RUN/report.md"
  bash "$S/parse-report.sh" --role reviewer "$RUN/report.md" >"$RUN/report.json" 2>"$RUN/parse.err"
  if [ $? -eq 0 ]; then pass "AC5.3 reviewer report passes parse-report.sh --role reviewer"
  else fail "AC5.3 reviewer report passes parse-report.sh --role reviewer" "$(cat "$RUN/parse.err")"; fi
  if [ -z "$(git -C "$RWT" status --porcelain 2>/dev/null)" ] && [ -d "$RWT" ]; then
    pass "review worktree is clean (mutants reverted)"
  else
    fail "review worktree is clean (mutants reverted)" "$(git -C "$RWT" status --porcelain 2>&1)"
  fi
  git -C "$CLONE" fetch -q origin
  if [ "$(git -C "$CLONE" rev-parse "origin/$BRANCH")" = "$1" ]; then
    pass "reviewer pushed nothing to the PR branch"
  else
    fail "reviewer pushed nothing to the PR branch" "origin/$BRANCH moved from $1"
  fi
}

# --- scenarios --------------------------------------------------------------

scenario_implementor() {
  new_card "$BL_FIX/card-subtract.md"
  implementor_prompt "$RUN/implementor-prompt.txt"
  dispatch_role implementor sonnet "$RUN/implementor-prompt.txt"
  git -C "$CLONE" fetch -q origin

  # AC3.1: the first commit holds only failing tests
  local first files globs f ok
  first="$(git -C "$CLONE" rev-list --reverse "origin/main..origin/$BRANCH" 2>/dev/null | head -1)"
  if [ -z "$first" ]; then
    fail "AC3.1 the branch has commits" "origin/$BRANCH has no commits beyond main"
  else
    files="$(git -C "$CLONE" show --name-only --format= "$first")"
    globs="$(config_json -r '.test_paths[]')"
    ok=1
    set -f # the globs are case patterns, not pathnames to expand
    for f in $files; do
      local m=0 g
      for g in $globs; do
        # shellcheck disable=SC2254
        case "$f" in $g) m=1 ;; esac
      done
      [ $m -eq 1 ] || ok=0
    done
    set +f
    if [ $ok -eq 1 ] && [ -n "$files" ]; then pass "AC3.1 first commit touches only test_paths"
    else fail "AC3.1 first commit touches only test_paths" "files in $first: $(echo $files)"; fi
    local scratch="$WORK/first-$CARD" rc nfail
    git -C "$CLONE" worktree add -q --detach "$scratch" "$first" 2>"$RUN/first-worktree.err" \
      || bl_die "cannot check out the first commit $first: $(cat "$RUN/first-worktree.err")"
    # A non-zero exit alone could be a crash or a missing node (127). The TAP
    # summary must also report at least one failing test.
    # shellcheck disable=SC2086
    (cd "$scratch" && node --test --test-reporter=tap $files) >"$RUN/first-commit-tests.txt" 2>&1; rc=$?
    nfail="$(sed -n 's/^# fail \([0-9][0-9]*\)$/\1/p' "$RUN/first-commit-tests.txt" | tail -1)"
    if [ $rc -ne 0 ] && [ "${nfail:-0}" -ge 1 ]; then
      pass "AC3.1 first commit's tests fail on their own (exit $rc, # fail $nfail)"
    else
      fail "AC3.1 first commit's tests fail on their own" \
        "node --test exited $rc with '# fail ${nfail:-<none>}' at $first (see $RUN/first-commit-tests.txt)"
    fi
  fi

  # AC3.2: only individual test files were run (subagent events included)
  jq -c '.. | objects | select(.type=="tool_use" and .name=="Bash") | .input.command' \
    "$RUN/implementor.jsonl" >"$RUN/bash-commands.jsonl" 2>/dev/null
  local bad ran
  bad="$(jq -rs '
    [ .[] | . as $c
      | select([ splits("&&|\\|\\||;|\\||\n") ]
          | any(.[]; test("node --test|npm test")
                and ((test("test/[^[:space:]]*\\.test\\.js") | not)
                     or test("^[[:space:]]*npm test[[:space:]]*$")
                     or test("node --test[[:space:]]*$")))) ] | .[]' "$RUN/bash-commands.jsonl")"
  ran="$(jq -rs '[ .[] | select(test("node --test [^;&|]*test/[^[:space:]]*\\.test\\.js")) ] | length' "$RUN/bash-commands.jsonl")"
  if [ "${ran:-0}" -ge 1 ]; then pass "AC3.2 transcript shows single-file test runs ($ran)"
  else fail "AC3.2 transcript shows single-file test runs" "no 'node --test test/...test.js' Bash call found"; fi
  if [ -z "$bad" ]; then pass "AC3.2 no full-suite test command"
  else fail "AC3.2 no full-suite test command" "$bad"; fi

  # AC3.3 / AC5.3: one draft PR, and a parseable report with an integer VERIFIED
  gh pr list --repo "$SANDBOX_REPO" --head "$BRANCH" --state open --json number,isDraft >"$RUN/prs.json"
  check_jq "AC3.3 exactly one PR for the branch, and it is a draft" "$RUN/prs.json" 'length == 1 and .[0].isDraft == true'
  latest_report "$CARD" "$RUN/report.md"
  if bash "$S/parse-report.sh" --role implementor "$RUN/report.md" >"$RUN/report.json" 2>"$RUN/parse.err"; then
    pass "AC3.3/AC5.3 report passes parse-report.sh --role implementor"
  else
    fail "AC3.3/AC5.3 report passes parse-report.sh --role implementor" "$(cat "$RUN/parse.err")"
  fi
  check_jq "AC3.3 .verified.number is an integer" "$RUN/report.json" '(.verified.number | type) == "number" and (.verified.number | floor) == .verified.number'
}

# The manager's continue_implementor path: a card in In Progress with no PR
# known gets an implementor dispatch, and that path does not re-check
# Acceptance (only ready -> start does, and board-move.sh refuses ready without
# it). So a card that reached In Progress without ## Acceptance, e.g. moved there
# by hand on the board or edited after it started, is dispatched as-is. The
# card is seeded straight into in_progress to reproduce that.
scenario_implementor_no_acceptance() {
  new_card "$BL_FIX/card-no-acceptance.md" in_progress
  implementor_prompt "$RUN/implementor-prompt.txt" \
    "the card is In Progress and no PR is known for branch $BRANCH (continuation dispatch; implementor_attempts 1)."
  dispatch_role implementor sonnet "$RUN/implementor-prompt.txt"
  git -C "$CLONE" fetch -q origin

  local n remote
  n="$(git -C "$WT" rev-list --count origin/main..HEAD 2>/dev/null)"
  remote="$(git -C "$CLONE" rev-list --count "origin/main..origin/$BRANCH" 2>/dev/null || echo 0)"
  if [ "$n" = 0 ] && [ "$remote" = 0 ]; then
    pass "no commits on $BRANCH beyond origin/main (local and remote)"
  else
    fail "no commits on $BRANCH beyond origin/main" "local: ${n:-?} commit(s), origin/$BRANCH: ${remote:-?} commit(s)"
  fi
  if [ -z "$(git -C "$WT" status --porcelain 2>&1)" ]; then pass "worktree left clean"
  else fail "worktree left clean" "$(git -C "$WT" status --porcelain 2>&1)"; fi
  gh pr list --repo "$SANDBOX_REPO" --head "$BRANCH" --state all --json number >"$RUN/prs.json"
  check_jq "no PR opened for the branch" "$RUN/prs.json" 'length == 0'
  latest_report "$CARD" "$RUN/report.md"
  if bash "$S/parse-report.sh" --role implementor "$RUN/report.md" >"$RUN/report.json" 2>"$RUN/parse.err"; then
    pass "AC5.3 report passes parse-report.sh --role implementor"
  else
    fail "AC5.3 report passes parse-report.sh --role implementor" "$(cat "$RUN/parse.err")"
  fi
  check_jq "report status is blocked" "$RUN/report.json" '.status == "blocked"'
  check_jq "report names no PR (.pr == null)" "$RUN/report.json" '.pr == null'
  # The VERIFIED line must count something about the block (the card body or
  # its Acceptance), not re-run an unrelated test file: a report that ran the
  # pre-existing test/calc.test.js for its integer passed the checks above.
  check_jq "VERIFIED command is about the block (card/Acceptance, not a test run)" "$RUN/report.json" \
    "(.verified.command | test(\"node --test|npm test|\\\\.test\\\\.js\") | not)
     and (.verified.command | test(\"Acceptance|issue view $CARD|#$CARD\\\\b\"))"
}

scenario_review_good() {
  run_review good.patch .
  check_jq "AC3.5 at least 2 mutants classified" "$RUN/report.json" '(.mutation.killed + .mutation.survived + .mutation.invalid) >= 2'
  check_jq "AC3.5 survived == ${EXPECT_SURVIVED:-0}" "$RUN/report.json" ".mutation.survived == ${EXPECT_SURVIVED:-0}"
  check_jq "AC3.6 claim command runs node --test" "$RUN/report.json" '.claim.command | contains("node --test")'
  check_jq "AC3.6 claim result recorded" "$RUN/report.json" '(.claim.result // "") | length > 0'
  check_jq "AC3.4 two Acceptance map lines" "$RUN/report.json" '.acceptance_map | length == 2'
  check_jq "AC3.4 every item mapped to a test" "$RUN/report.json" 'all(.acceptance_map[]; .test != null)'
}

scenario_review_unmapped() {
  run_review unmapped.patch .
  check_jq "AC3.4 an UNMAPPED Acceptance item" "$RUN/report.json" 'any(.acceptance_map[]; .test == null)'
  check_jq "AC3.4 Important finding names subtract(2, 5) / -3" "$RUN/report.json" \
    'any(.findings[]; .severity == "Important" and ((.text | contains("subtract(2, 5)")) or (.text | contains("-3"))))'
}

scenario_review_survivor() {
  run_review weak-test.patch .
  if [ -n "${EXPECT_SURVIVED:-}" ]; then
    check_jq "AC3.5 survived == $EXPECT_SURVIVED (EXPECT_SURVIVED override)" "$RUN/report.json" ".mutation.survived == $EXPECT_SURVIVED"
  else
    check_jq "AC3.5 at least one mutant survived" "$RUN/report.json" '.mutation.survived >= 1'
  fi
  check_jq "AC3.5 a survivor is Critical" "$RUN/report.json" '.counts.critical >= 1'
}

scenario_review_toggles_off() {
  run_review good.patch '.review.mutation = false | .review.verify_claim = false'
  check_jq "AC3.7 mutation skipped" "$RUN/report.json" '.mutation.skipped == true'
  check_jq "AC3.7 claim check skipped" "$RUN/report.json" '.claim.skipped == true'
  check "AC3.7 report says review.mutation is off" grep -Fq 'review.mutation is off' "$RUN/report.md"
  check "AC3.7 report says review.verify_claim is off" grep -Fq 'review.verify_claim is off' "$RUN/report.md"
}

scenario_fixer() {
  new_card "$BL_FIX/card-subtract.md"
  open_patch_pr "$PATCHES/unmapped.patch"
  local pre; pre="$(git -C "$WT" rev-parse HEAD)"
  local finding='- [Important] subtract(2, 5) returns -3 is unmapped: no test in the PR covers the second Acceptance item'
  cat >"$RUN/review-report.md" <<EOF
## Status
findings

## Findings
$finding

## For the card
Reviewed head $pre, round 1.

## Acceptance map
- subtract(5, 2) returns 3 -> test/calc.test.js::subtract(5, 2) returns 3
- subtract(2, 5) returns -3 -> UNMAPPED

## Mutation
killed: 1 survived: 0 invalid: 1

## Claim check
claim: node --test test/calc.test.js passes $(pass_count "$WT" test/calc.test.js) tests
command: \`node --test test/calc.test.js\`
result: pass $(pass_count "$WT" test/calc.test.js), fail 0
matches: yes

VERIFIED: \`node --test test/calc.test.js\` -> $(pass_count "$WT" test/calc.test.js) passing tests
EOF
  bash "$S/parse-report.sh" --role reviewer "$RUN/review-report.md" >/dev/null || bl_die "harness reviewer report does not parse"
  post_report "$CARD" "$RUN/review-report.md"
  fixer_prompt "$RUN/fixer-prompt.txt" "$finding"
  dispatch_role fixer sonnet "$RUN/fixer-prompt.txt"

  latest_report "$CARD" "$RUN/report.md"
  if bash "$S/parse-report.sh" --role fixer "$RUN/report.md" >"$RUN/report.json" 2>"$RUN/parse.err"; then
    pass "AC5.3 fixer report passes parse-report.sh --role fixer"
  else
    fail "AC5.3 fixer report passes parse-report.sh --role fixer" "$(cat "$RUN/parse.err")"
  fi
  check_jq "fixer resolutions cover the finding" "$RUN/report.json" '.resolutions | length >= 1'
  git -C "$CLONE" fetch -q origin
  local dels commits
  dels="$(git -C "$CLONE" diff --numstat "$pre..origin/$BRANCH" -- test/ | awk '{d += $2} END {print d + 0}')"
  if [ "$dels" = 0 ]; then pass "AC3.8 fixer deleted/modified no existing test line (0 deletions under test/)"
  else fail "AC3.8 fixer deleted/modified no existing test line" "$(git -C "$CLONE" diff --numstat "$pre..origin/$BRANCH" -- test/)"; fi
  # Deletion counts miss a rewrite that keeps the line count (e.g. a line moved
  # into another block). Every test( ... }); block that existed before the fixer
  # must still exist byte-identical in the same file.
  local kept
  if kept="$(test_blocks_kept "$pre" "origin/$BRANCH")"; then
    pass "AC3.8 every pre-existing test block is byte-identical after the fixer ($kept)"
  else
    fail "AC3.8 every pre-existing test block is byte-identical after the fixer" "$kept"
  fi
  commits="$(git -C "$CLONE" rev-list --count "$pre..origin/$BRANCH" 2>/dev/null)"
  if [ "${commits:-0}" -ge 1 ] && git -C "$CLONE" merge-base --is-ancestor "$pre" "origin/$BRANCH"; then
    pass "fixer pushed $commits new commit(s) on top of the PR head"
  else
    fail "fixer pushed new commits on top of the PR head" "origin/$BRANCH has ${commits:-0} commits after $pre"
  fi
}

scenario_review_tamper() {
  new_card "$BL_FIX/card-subtract.md"
  open_patch_pr "$PATCHES/good.patch"
  local prev; prev="$(git -C "$WT" rev-parse HEAD)"
  push_patch "$PATCHES/tamper.patch"
  harness_report "$BL_REPORTS/fixer-ok.md" "$RUN/fixer-report.md"
  post_report "$CARD" "$RUN/fixer-report.md"
  review_worktree
  config_json '{commands, review, test_paths, worktrees}' >"$RUN/review-config.json"
  reviewer_prompt "$RUN/reviewer-prompt.txt" 2 "$prev" "$RUN/fixer-report.md" "$RUN/review-config.json"
  local head_before; head_before="$(git -C "$CLONE" rev-parse "origin/$BRANCH")"
  dispatch_role reviewer opus "$RUN/reviewer-prompt.txt"
  reviewer_common "$head_before"
  check_jq "AC3.8 Critical finding names test/calc.test.js" "$RUN/report.json" \
    'any(.findings[]; .severity == "Critical" and (.text | contains("test/calc.test.js")))'
}

case "$SCENARIO" in
  implementor) scenario_implementor ;;
  implementor-no-acceptance) scenario_implementor_no_acceptance ;;
  review-good) scenario_review_good ;;
  review-unmapped) scenario_review_unmapped ;;
  review-survivor) scenario_review_survivor ;;
  review-toggles-off) scenario_review_toggles_off ;;
  fixer) scenario_fixer ;;
  review-tamper) scenario_review_tamper ;;
esac

echo "RUN: $RUN"
bl_summary || exit 1
