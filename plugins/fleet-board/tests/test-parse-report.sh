#!/usr/bin/env bash
#
# Plain-bash tests for parse-report.sh (the role report validator).
# No framework, no dependencies beyond POSIX tools and jq.
#
# Usage: bash plugins/fleet-board/tests/test-parse-report.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/../scripts/parse-report.sh"
REPORTS="${SCRIPT_DIR}/../fixtures/reports"

PASS=0
FAIL=0
LAST_OUT=""
LAST_ERR=""
LAST_EXIT=0

# Choose a bash executable for consistent invocation.
# Prefer /bin/bash if available (standard on macOS/BSD), else use bash from PATH.
if [ -x /bin/bash ]; then
  BASH_EXE="/bin/bash"
else
  BASH_EXE="bash"
fi

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

assert_exit() {
  if [ "$LAST_EXIT" = "$2" ]; then pass "$1"; else fail "$1" "expected exit $2, got $LAST_EXIT (stderr: $LAST_ERR)"; fi
}

assert_stdout_exact() {
  if [ "$LAST_OUT" = "$2" ]; then pass "$1"; else fail "$1" "expected stdout: '$2', got: '$LAST_OUT'"; fi
}

assert_stderr_contains() {
  case "$LAST_ERR" in
    *"$2"*) pass "$1" ;;
    *) fail "$1" "expected to find '$2' in stderr, got: '$LAST_ERR'" ;;
  esac
}

assert_stderr_not_contains() {
  case "$LAST_ERR" in
    *"$2"*) fail "$1" "did not expect '$2' in stderr" ;;
    *) pass "$1" ;;
  esac
}

# One whole line of stderr equals $2 exactly
assert_stderr_line() {
  if printf '%s\n' "$LAST_ERR" | grep -Fxq -- "$2"; then
    pass "$1"
  else
    fail "$1" "expected a stderr line exactly '$2', got: '$LAST_ERR'"
  fi
}

# jq filter $2 is true for stdout. Empty or non-JSON stdout fails.
assert_jq() {
  if [ -n "$LAST_OUT" ] && printf '%s' "$LAST_OUT" | jq -e "$2" > /dev/null 2>&1; then
    pass "$1"
  else
    fail "$1" "expected jq '$2' to hold for stdout: '$LAST_OUT'"
  fi
}

# jq -c filter $2 on stdout prints exactly $3
assert_jq_exact() {
  local got
  got="$(printf '%s' "$LAST_OUT" | jq -c "$2" 2>/dev/null)"
  if [ -n "$LAST_OUT" ] && [ "$got" = "$3" ]; then
    pass "$1"
  else
    fail "$1" "expected jq '$2' to print '$3', got: '$got'"
  fi
}

run_check() {
  local script="$1"
  shift
  local tmpout tmperr
  tmpout="$(mktemp)"
  tmperr="$(mktemp)"
  "$BASH_EXE" "$script" "$@" > "$tmpout" 2> "$tmperr"
  LAST_EXIT=$?
  LAST_OUT="$(cat "$tmpout")"
  LAST_ERR="$(cat "$tmperr")"
  rm -f "$tmpout" "$tmperr"
}

run_parse() { run_check "$SCRIPT" "$@"; }

echo "parse-report.sh"

# --- implementor-ok --------------------------------------------------------
echo "implementor-ok"
run_parse "$REPORTS/implementor-ok.md"
assert_exit "implementor-ok: exit 0" 0
assert_jq "implementor-ok: .verified.number is an integer" '(.verified.number | type) == "number" and .verified.number == (.verified.number | floor)'
assert_jq_exact "implementor-ok: .verified.number is 3" '.verified.number' '3'
assert_jq_exact "implementor-ok: .verified.command has its backticks stripped" '.verified.command' '"node --test test/calc.test.js"'
assert_jq_exact "implementor-ok: .verified.line is the whole line" '.verified.line' '"VERIFIED: `node --test test/calc.test.js` -> 3 passing tests"'
assert_jq "implementor-ok: .pr is a number" '(.pr | type) == "number"'
assert_jq_exact "implementor-ok: .pr is 12" '.pr' '12'
assert_jq "implementor-ok: .counts.critical == 0" '.counts.critical == 0'
assert_jq_exact "implementor-ok: .status is done" '.status' '"done"'
assert_jq_exact "implementor-ok: - none gives no findings" '.findings' '[]'
assert_jq "implementor-ok: .blocked_by == null" '.blocked_by == null'
assert_jq "implementor-ok: .for_the_card holds the card text" '.for_the_card | contains("Added subtract(a, b) to src/calc.js")'
assert_jq_exact "implementor-ok: reviewer and fixer fields are null" '[.acceptance_map, .mutation, .claim, .resolutions]' '[null,null,null,null]'
assert_jq_exact "implementor-ok: no out-of-scope items or bugs" '[.out_of_scope, .bugs]' '[[],[]]'

run_parse --role implementor "$REPORTS/implementor-ok.md"
assert_exit "implementor-ok --role implementor: exit 0" 0

# --- reviewer-ok -----------------------------------------------------------
echo "reviewer-ok"
run_parse --role reviewer "$REPORTS/reviewer-ok.md"
assert_exit "reviewer-ok --role reviewer: exit 0" 0
assert_jq "reviewer-ok: .mutation.killed, .survived and .invalid are numbers" '[.mutation.killed, .mutation.survived, .mutation.invalid] | map(type) == ["number","number","number"]'
assert_jq_exact "reviewer-ok: mutation counts are 2 0 1" '[.mutation.killed, .mutation.survived, .mutation.invalid]' '[2,0,1]'
assert_jq "reviewer-ok: .claim.command is non-empty" '(.claim.command | type) == "string" and (.claim.command | length) > 0'
assert_jq_exact "reviewer-ok: .claim.command has its backticks stripped" '.claim.command' '"node --test test/calc.test.js"'
assert_jq_exact "reviewer-ok: .claim.claim, .result and .matches" '[.claim.claim, .claim.result, .claim.matches]' '["node --test test/calc.test.js passes 3 tests","tests 3, pass 3, fail 0",true]'
assert_jq "reviewer-ok: .acceptance_map | length == 2" '.acceptance_map | length == 2'
assert_jq_exact "reviewer-ok: .acceptance_map[1] splits item and test" '.acceptance_map[1]' '{"item":"subtract(2, 5) returns -3","test":"test/calc.test.js::subtract(2, 5) returns -3"}'
assert_jq_exact "reviewer-ok: .status is clean" '.status' '"clean"'
assert_jq "reviewer-ok: .pr == null (no ## PR section)" '.pr == null'

# --- reviewer-skipped ------------------------------------------------------
echo "reviewer-skipped"
run_parse --role reviewer "$REPORTS/reviewer-skipped.md"
assert_exit "reviewer-skipped --role reviewer: exit 0" 0
assert_jq "reviewer-skipped: .mutation.skipped == true" '.mutation.skipped == true'
assert_jq "reviewer-skipped: .claim.skipped == true" '.claim.skipped == true'
assert_jq_exact "reviewer-skipped: an UNMAPPED item has test null" '.acceptance_map[1]' '{"item":"subtract(2, 5) returns -3","test":null}'
assert_jq_exact "reviewer-skipped: the Important finding is parsed" '.findings' '[{"severity":"Important","text":"subtract(2, 5) returns -3 has no test"}]'

# --- fixer-ok --------------------------------------------------------------
echo "fixer-ok"
run_parse --role fixer "$REPORTS/fixer-ok.md"
assert_exit "fixer-ok --role fixer: exit 0" 0
assert_jq "fixer-ok: .resolutions | length == 2" '.resolutions | length == 2'
assert_jq_exact "fixer-ok: a fixed resolution" '.resolutions[0]' '{"finding":"[Important] subtract(2, 5) returns -3 is unmapped","outcome":"fixed","why":null}'
assert_jq_exact "fixer-ok: a not-fixed resolution keeps its reason" '.resolutions[1]' '{"finding":"[Minor] calc.js has no header comment","outcome":"not fixed","why":"outside this card'"'"'s Acceptance"}'

# --- role requirements -----------------------------------------------------
echo "role requirements"
run_parse --role fixer "$REPORTS/implementor-ok.md"
assert_exit "implementor-ok --role fixer: exit 1" 1
assert_stderr_line "implementor-ok --role fixer: names ## Resolutions" "parse-report: role fixer requires ## Resolutions"

run_parse --role implementor "$REPORTS/reviewer-ok.md"
assert_exit "reviewer-ok --role implementor: exit 1" 1
assert_stderr_line "reviewer-ok --role implementor: names ## PR" "parse-report: role implementor requires ## PR"

# --- VERIFIED line ---------------------------------------------------------
echo "VERIFIED line"
run_parse "$REPORTS/no-verified.md"
assert_exit "no-verified: exit 1" 1
assert_stderr_contains "no-verified: stderr contains found 0" "found 0"
assert_stderr_line "no-verified: the whole message" "parse-report: expected exactly one VERIFIED: line, found 0"
assert_stdout_exact "no-verified: no JSON on stdout" ""

run_parse "$REPORTS/two-verified.md"
assert_exit "two-verified: exit 1" 1
assert_stderr_contains "two-verified: stderr contains found 2" "found 2"
assert_stdout_exact "two-verified: no JSON on stdout" ""

run_parse "$REPORTS/verified-no-number.md"
assert_exit "verified-no-number: exit 1" 1
assert_stderr_line "verified-no-number: names the VERIFIED shape" "parse-report: VERIFIED line needs a backticked command and an integer after ->"

run_parse "$REPORTS/verified-unicode-arrow.md"
assert_exit "verified-unicode-arrow: exit 0" 0
assert_jq_exact "verified-unicode-arrow: the number after the arrow" '.verified.number' '3'

# --- sections and status ---------------------------------------------------
echo "sections and status"
run_parse "$REPORTS/missing-for-the-card.md"
assert_exit "missing-for-the-card: exit 1" 1
assert_stderr_line "missing-for-the-card: names the section" "parse-report: missing section: ## For the card"

run_parse --role reviewer "$REPORTS/reviewer-missing-mutation.md"
assert_exit "reviewer-missing-mutation --role reviewer: exit 1" 1
assert_stderr_line "reviewer-missing-mutation --role reviewer: names ## Mutation" "parse-report: role reviewer requires ## Mutation"

run_parse "$REPORTS/reviewer-missing-mutation.md"
assert_exit "reviewer-missing-mutation without --role: exit 0" 0
assert_jq "reviewer-missing-mutation without --role: .mutation == null" '.mutation == null'

run_parse "$REPORTS/unknown-status.md"
assert_exit "unknown-status: exit 1" 1
assert_stderr_line "unknown-status: names the status" "parse-report: unknown status: finished"

# --- Out of scope and Bugs found (AC3.10) ----------------------------------
echo "Out of scope and Bugs found"
run_parse "$REPORTS/with-out-of-scope.md"
assert_exit "with-out-of-scope: exit 0" 0
assert_jq "with-out-of-scope: .out_of_scope | length == 2" '.out_of_scope | length == 2'
assert_jq "with-out-of-scope: .out_of_scope[0].title is non-empty" '(.out_of_scope[0].title | type) == "string" and (.out_of_scope[0].title | length) > 0'
assert_jq_exact "with-out-of-scope: .out_of_scope[0] splits title and detail" '.out_of_scope[0]' '{"title":"Add multiply","detail":"calc has no multiply; a later card could add it"}'
assert_jq_exact "with-out-of-scope: .bugs == []" '.bugs' '[]'

run_parse "$REPORTS/with-bugs.md"
assert_exit "with-bugs: exit 0" 0
assert_jq "with-bugs: .bugs | length == 2" '.bugs | length == 2'
assert_jq "with-bugs: .bugs[0] has non-empty title, repro, expected and observed" '.bugs[0] | [.title, .repro, .expected, .observed] | all(type == "string" and length > 0)'
assert_jq_exact "with-bugs: .bugs[0].repro has its backticks stripped" '.bugs[0].repro' '"node -e \"console.log(require('"'"'./src/calc.js'"'"').add(1, 2, 3))\""'
assert_jq_exact "with-bugs: .bugs[0] title, expected and observed" '.bugs[0] | [.title, .expected, .observed]' '["add drops a third argument","6","3"]'
assert_jq_exact "with-bugs: .bugs[1].observed" '.bugs[1].observed' '"12"'
assert_jq_exact "with-bugs: .out_of_scope == []" '.out_of_scope' '[]'

run_parse "$REPORTS/bug-missing-repro.md"
assert_exit "bug-missing-repro: exit 1" 1
assert_stderr_contains "bug-missing-repro: stderr names the four parts" "bug entry needs title, repro, expected, observed"
assert_stderr_line "bug-missing-repro: the whole message" "parse-report: bug entry needs title, repro, expected, observed"

run_parse "$REPORTS/with-oos-and-bugs.md"
assert_exit "with-oos-and-bugs: exit 0" 0
assert_jq "with-oos-and-bugs: .out_of_scope | length == 1" '.out_of_scope | length == 1'
assert_jq "with-oos-and-bugs: .bugs | length == 1" '.bugs | length == 1'
assert_jq "with-oos-and-bugs: .out_of_scope[0].detail does not contain repro:" '(.out_of_scope[0].detail | type) == "string" and (.out_of_scope[0].detail | contains("repro:") | not)'
assert_jq_exact "with-oos-and-bugs: the bug is parsed" '.bugs[0].title' '"add drops a third argument"'

run_parse "$REPORTS/with-bugs-then-oos.md"
assert_exit "with-bugs-then-oos: exit 0 (Out of scope: ends the Bugs found list)" 0
assert_jq "with-bugs-then-oos: .bugs | length == 1" '.bugs | length == 1'
assert_jq_exact "with-bugs-then-oos: the Out of scope item is parsed" '.out_of_scope' '[{"title":"Add multiply","detail":"calc has no multiply; a later card could add it"}]'

# --- findings counting -----------------------------------------------------
echo "findings counting"
run_parse "$REPORTS/findings-1-2-1.md"
assert_exit "findings-1-2-1: exit 0" 0
assert_jq_exact "findings-1-2-1: .counts" '.counts' '{"critical":1,"important":2,"minor":1}'
assert_jq_exact "findings-1-2-1: .findings[0]" '.findings[0]' '{"severity":"Critical","text":"subtract(2, 5) returns 3 instead of -3"}'
assert_jq "findings-1-2-1: four findings" '.findings | length == 4'

# --- Blocked by ------------------------------------------------------------
echo "Blocked by"
run_parse --role fixer "$REPORTS/fixer-blocked-by.md"
assert_exit "fixer-blocked-by --role fixer: exit 0" 0
assert_jq "fixer-blocked-by: .status == blocked" '.status == "blocked"'
assert_jq "fixer-blocked-by: .blocked_by == 41" '.blocked_by == 41'
assert_jq "fixer-blocked-by: .blocked_by is a number" '(.blocked_by | type) == "number"'
assert_jq_exact "fixer-blocked-by: .pr is 13" '.pr' '13'

# --- Findings shape (review cycle 1: C1) -----------------------------------
echo "Findings shape"
for v in double-space bold lowercase star no-text free-text; do
  run_parse "$REPORTS/findings-$v.md"
  assert_exit "findings-$v: exit 1" 1
  assert_stderr_contains "findings-$v: names the malformed finding line" "parse-report: malformed finding line: "
  assert_stdout_exact "findings-$v: no JSON on stdout" ""
done
run_parse "$REPORTS/findings-lowercase.md"
assert_stderr_line "findings-lowercase: quotes the line" "parse-report: malformed finding line: - [critical] subtract(2, 5) returns 3"

run_parse "$REPORTS/findings-empty.md"
assert_exit "findings-empty: exit 1" 1
assert_stderr_line "findings-empty: names the missing forms" 'parse-report: ## Findings needs "- none" or at least one "- [Critical|Important|Minor] <text>" line'

run_parse "$REPORTS/findings-none-plus-finding.md"
assert_exit "findings-none-plus-finding: exit 1" 1
assert_stderr_line "findings-none-plus-finding: names the mix" 'parse-report: ## Findings mixes "- none" with findings'

run_parse --role reviewer "$REPORTS/reviewer-clean-with-critical.md"
assert_exit "reviewer-clean-with-critical --role reviewer: exit 1" 1
assert_stderr_line "reviewer-clean-with-critical: names the contradiction" "parse-report: status clean needs zero Critical and Important findings, found 1"

run_parse --role reviewer "$REPORTS/reviewer-findings-with-zero.md"
assert_exit "reviewer-findings-with-zero --role reviewer: exit 1" 1
assert_stderr_line "reviewer-findings-with-zero: names the contradiction" "parse-report: status findings needs at least one Critical or Important finding"

run_parse --role reviewer "$REPORTS/reviewer-clean-minor-only.md"
assert_exit "reviewer-clean-minor-only --role reviewer: exit 0 (a Minor finding does not block clean)" 0
assert_jq_exact "reviewer-clean-minor-only: counts" '.counts' '{"critical":0,"important":0,"minor":1}'

# --- role section contents (review cycle 1: I1) ----------------------------
echo "role section contents"
run_parse --role implementor "$REPORTS/implementor-status-clean.md"
assert_exit "implementor-status-clean --role implementor: exit 1" 1
assert_stderr_line "implementor-status-clean: names the status" "parse-report: role implementor does not allow status: clean"
run_parse "$REPORTS/implementor-status-clean.md"
assert_exit "implementor-status-clean without --role: exit 0" 0

run_parse --role reviewer "$REPORTS/reviewer-status-done.md"
assert_exit "reviewer-status-done --role reviewer: exit 1" 1
assert_stderr_line "reviewer-status-done: names the status" "parse-report: role reviewer does not allow status: done"

run_parse --role fixer "$REPORTS/fixer-status-findings.md"
assert_exit "fixer-status-findings --role fixer: exit 1" 1
assert_stderr_line "fixer-status-findings: names the status" "parse-report: role fixer does not allow status: findings"

run_parse --role implementor "$REPORTS/implementor-pr-no-number.md"
assert_exit "implementor-pr-no-number --role implementor: exit 1" 1
assert_stderr_line "implementor-pr-no-number: names the PR number" "parse-report: role implementor requires a PR number (#<n>) in ## PR unless status is blocked"
run_parse "$REPORTS/implementor-pr-no-number.md"
assert_exit "implementor-pr-no-number without --role: exit 0" 0
assert_jq "implementor-pr-no-number without --role: .pr == null" '.pr == null'

run_parse --role implementor "$REPORTS/implementor-blocked-no-pr.md"
assert_exit "implementor-blocked-no-pr --role implementor: exit 0 (blocked may have no PR yet)" 0
assert_jq "implementor-blocked-no-pr: .pr == null and .blocked_by == 41" '.pr == null and .blocked_by == 41'

run_parse --role reviewer "$REPORTS/reviewer-mutation-commas.md"
assert_exit "reviewer-mutation-commas --role reviewer: exit 1" 1
assert_stderr_line "reviewer-mutation-commas: quotes the line" "parse-report: malformed ## Mutation line: killed: 2, survived: 0, invalid: 0"
assert_stderr_line "reviewer-mutation-commas: names the forms" 'parse-report: ## Mutation needs exactly one "killed: <n> survived: <n> invalid: <n>" or "skipped: review.mutation is off" line'
run_parse "$REPORTS/reviewer-mutation-commas.md"
assert_exit "reviewer-mutation-commas without --role: exit 1 (a present section is always checked)" 1

run_parse --role reviewer "$REPORTS/reviewer-mutation-skipped-other.md"
assert_exit "reviewer-mutation-skipped-other --role reviewer: exit 1" 1
assert_stderr_line "reviewer-mutation-skipped-other: quotes the line" "parse-report: malformed ## Mutation line: skipped: not configured"

run_parse --role reviewer "$REPORTS/reviewer-claim-free-text.md"
assert_exit "reviewer-claim-free-text --role reviewer: exit 1" 1
assert_stderr_line "reviewer-claim-free-text: quotes the line" "parse-report: malformed ## Claim check line: I re-ran node --test test/calc.test.js and it passed."
assert_stderr_line "reviewer-claim-free-text: names the forms" 'parse-report: ## Claim check needs one each of claim:, command:, result: and matches:, or only "skipped: review.verify_claim is off"'

run_parse --role reviewer "$REPORTS/reviewer-claim-matches-maybe.md"
assert_exit "reviewer-claim-matches-maybe --role reviewer: exit 1" 1
assert_stderr_line "reviewer-claim-matches-maybe: names matches" "parse-report: ## Claim check matches must be yes or no: probably"

run_parse --role reviewer "$REPORTS/reviewer-claim-command-unquoted.md"
assert_exit "reviewer-claim-command-unquoted --role reviewer: exit 1" 1
assert_stderr_line "reviewer-claim-command-unquoted: names command" "parse-report: ## Claim check command must be one backticked command: node --test test/calc.test.js"

run_parse --role reviewer "$REPORTS/reviewer-claim-missing-result.md"
assert_exit "reviewer-claim-missing-result --role reviewer: exit 1" 1
assert_stderr_line "reviewer-claim-missing-result: names the forms" 'parse-report: ## Claim check needs one each of claim:, command:, result: and matches:, or only "skipped: review.verify_claim is off"'

run_parse --role reviewer "$REPORTS/reviewer-amap-no-entries.md"
assert_exit "reviewer-amap-no-entries --role reviewer: exit 1" 1
assert_stderr_line "reviewer-amap-no-entries: quotes the line" "parse-report: malformed ## Acceptance map line: Both Acceptance items are mapped to tests."
assert_stderr_line "reviewer-amap-no-entries: needs an entry" "parse-report: role reviewer requires at least one ## Acceptance map entry"

run_parse --role reviewer "$REPORTS/reviewer-amap-no-arrow.md"
assert_exit "reviewer-amap-no-arrow --role reviewer: exit 1" 1
assert_stderr_line "reviewer-amap-no-arrow: quotes the line" "parse-report: malformed ## Acceptance map line: - subtract(5, 2) returns 3"

run_parse --role fixer "$REPORTS/fixer-resolution-bad-outcome.md"
assert_exit "fixer-resolution-bad-outcome --role fixer: exit 1" 1
assert_stderr_line "fixer-resolution-bad-outcome: quotes the line" "parse-report: malformed ## Resolutions line (want - <finding> :: fixed | not fixed: <why>): - [Important] subtract(2, 5) returns -3 is unmapped :: done"

run_parse --role fixer "$REPORTS/fixer-resolution-no-why.md"
assert_exit "fixer-resolution-no-why --role fixer: exit 1" 1
assert_stderr_contains "fixer-resolution-no-why: names the Resolutions line" "parse-report: malformed ## Resolutions line"

run_parse --role fixer "$REPORTS/fixer-resolutions-empty.md"
assert_exit "fixer-resolutions-empty --role fixer: exit 1" 1
assert_stderr_line "fixer-resolutions-empty: needs an entry" "parse-report: role fixer requires at least one ## Resolutions entry"

run_parse "$REPORTS/bug-repro-unquoted.md"
assert_exit "bug-repro-unquoted: exit 1" 1
assert_stderr_contains "bug-repro-unquoted: names the backticks" "parse-report: bug repro must be a backticked command: add drops a third argument"

# --- VERIFIED integer boundary (review cycle 1: M1) ------------------------
echo "VERIFIED integer boundary"
for v in trailing-letters decimal; do
  run_parse "$REPORTS/verified-$v.md"
  assert_exit "verified-$v: exit 1" 1
  assert_stderr_line "verified-$v: names the VERIFIED shape" "parse-report: VERIFIED line needs a backticked command and an integer after ->"
done
run_parse "$REPORTS/verified-number-at-end.md"
assert_exit "verified-number-at-end: exit 0" 0
assert_jq_exact "verified-number-at-end: .verified.number" '.verified.number' '3'

# --- Status lines and duplicate sections (review cycle 1: M2) --------------
echo "Status lines and duplicate sections"
run_parse "$REPORTS/status-extra-line.md"
assert_exit "status-extra-line: exit 1" 1
assert_stderr_line "status-extra-line: quotes the extra line" "parse-report: ## Status must be one line, extra line: Everything went fine."

run_parse "$REPORTS/duplicate-section.md"
assert_exit "duplicate-section: exit 1" 1
assert_stderr_line "duplicate-section: names the section" "parse-report: duplicate section: ## Findings"

# --- For the card sub-lists (review cycle 1: M3) ---------------------------
# Rule: a sub-list entry is a "- " line directly under its header or the
# previous entry. A blank line or a text line ends the list. A header with no
# entries is an error, and so is a "- " line (indented or not) that follows a
# list only after a blank line, or an indented "  - " line inside a list:
# either would otherwise be silently dropped.
echo "For the card sub-lists"
run_parse "$REPORTS/oos-empty-list.md"
assert_exit "oos-empty-list: exit 1" 1
assert_stderr_line "oos-empty-list: names the empty list" "parse-report: empty sub-list: Out of scope:"
assert_stderr_contains "oos-empty-list: the entry after the blank line is stray" "parse-report: stray list line in ## For the card"

run_parse "$REPORTS/bugs-empty-list.md"
assert_exit "bugs-empty-list: exit 1" 1
assert_stderr_line "bugs-empty-list: names the empty list" "parse-report: empty sub-list: Bugs found:"

run_parse "$REPORTS/oos-no-separator.md"
assert_exit "oos-no-separator: exit 1" 1
assert_stderr_line "oos-no-separator: quotes the entry" "parse-report: out of scope entry needs <title> :: <detail>: Add multiply, calc has no multiply"

run_parse "$REPORTS/oos-entry-after-blank.md"
assert_exit "oos-entry-after-blank: exit 1" 1
assert_stderr_line "oos-entry-after-blank: quotes the stray line" "parse-report: stray list line in ## For the card (sub-list entries follow their header or the previous entry directly, unindented): - Document calc :: the README does not list the exported functions"

run_parse "$REPORTS/bugs-indented-entry.md"
assert_exit "bugs-indented-entry: exit 1" 1
assert_stderr_contains "bugs-indented-entry: the indented entry is stray" "parse-report: stray list line in ## For the card"
assert_stderr_line "bugs-indented-entry: the list is then empty" "parse-report: empty sub-list: Bugs found:"

run_parse "$REPORTS/card-free-bullets.md"
assert_exit "card-free-bullets: exit 0 (bullets under a text line are free text)" 0
assert_jq_exact "card-free-bullets: one Out of scope item" '.out_of_scope' '[{"title":"Add multiply","detail":"calc has no multiply"}]'

# --- Resolutions separators (review cycle 1: M4) ---------------------------
echo "Resolutions separators"
run_parse --role fixer "$REPORTS/fixer-resolution-separators.md"
assert_exit "fixer-resolution-separators --role fixer: exit 0" 0
assert_jq_exact "fixer-resolution-separators: a finding holding ' :: '" '.resolutions[0]' '{"finding":"[Important] subtract(2, 5) :: returns -3 is unmapped","outcome":"fixed","why":null}'
assert_jq_exact "fixer-resolution-separators: a why holding ' :: '" '.resolutions[1]' '{"finding":"[Minor] calc.js has no header comment","outcome":"not fixed","why":"needs #41 :: tracked separately"}'

# --- whitespace variants (review cycle 1: M5) ------------------------------
echo "whitespace variants"
CRLF_DIR="$(mktemp -d)"
awk '{ printf "%s\r\n", $0 }' "$REPORTS/implementor-ok.md" > "$CRLF_DIR/implementor-crlf.md"
awk '{ printf "%s\r\n", $0 }' "$REPORTS/reviewer-ok.md" > "$CRLF_DIR/reviewer-crlf.md"
run_parse --role implementor "$CRLF_DIR/implementor-crlf.md"
assert_exit "implementor-crlf --role implementor: exit 0" 0
assert_jq_exact "implementor-crlf: status, pr, verified number" '[.status, .pr, .verified.number, .verified.command]' '["done",12,3,"node --test test/calc.test.js"]'
assert_jq "implementor-crlf: no carriage return in for_the_card" '.for_the_card | contains("\r") | not'
run_parse --role reviewer "$CRLF_DIR/reviewer-crlf.md"
assert_exit "reviewer-crlf --role reviewer: exit 0" 0
assert_jq_exact "reviewer-crlf: mutation and claim" '[.mutation.killed, .claim.matches, .claim.command]' '[2,true,"node --test test/calc.test.js"]'
rm -rf "$CRLF_DIR"

run_parse --role implementor "$REPORTS/padded-headings.md"
assert_exit "padded-headings --role implementor: exit 0" 0
assert_jq_exact "padded-headings: status, pr, finding" '[.status, .pr, .counts.minor]' '["done",12,1]'

run_parse --role implementor "$REPORTS/tabs.md"
assert_exit "tabs --role implementor: exit 0" 0
assert_jq_exact "tabs: finding, out of scope, verified" '[.findings[0].severity, .out_of_scope[0].title, .verified.number]' '["Important","Add multiply",3]'

# --- usage -----------------------------------------------------------------
echo "usage"
run_parse "$REPORTS/does-not-exist.md"
assert_exit "missing file: exit 2" 2
assert_stderr_contains "missing file: names the file" "does-not-exist.md"

run_parse --role manager "$REPORTS/implementor-ok.md"
assert_exit "unknown role: exit 2" 2

run_parse
assert_exit "no arguments: exit 2" 2
assert_stderr_contains "no arguments: prints usage" "usage: parse-report.sh"

# --- acceptance map items may contain " -> " (split on the last arrow) -----
echo "reviewer-amap-arrow-in-item"
run_parse --role reviewer "$REPORTS/reviewer-amap-arrow-in-item.md"
assert_exit "reviewer-amap-arrow-in-item --role reviewer: exit 0" 0
assert_jq_exact "reviewer-amap-arrow-in-item: item keeps its arrow" '.acceptance_map[0].item' '"f(x) -> y is returned"'
assert_jq_exact "reviewer-amap-arrow-in-item: test is the last arrow's target" '.acceptance_map[0].test' '"test/a.test.js::t"'

# --- an indented finding line is malformed ------------------------------------
echo "findings-indented"
run_parse "$REPORTS/findings-indented.md"
assert_exit "findings-indented: exit 1" 1
assert_stderr_contains "findings-indented: names the malformed line" "malformed finding line"

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
