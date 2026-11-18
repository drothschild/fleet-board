#!/usr/bin/env bash
# Wording contract for commands.test_case: an optional single-test command with {file} and {name}
# that the reviewer uses to run one mapped test per mutant. Without it a reviewer could only run a
# whole test file per mutant, and a planner card's review spent 6-10 minutes per mutant re-running
# a suite of 200 cases. A single-case run counts only when it first passes at the unmutated head and
# shows exactly one test, so a selection that runs nothing, or breaks setup, never reads as a kill.
# These checks pin the instructions and the config plumbing; they are not a behavioral test.
set -uo pipefail
unset CDPATH
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$HERE/.."
SPEC="$PLUGIN/../../docs/implementation-plans/2026-09-28-fleet-board/specs/reviewer.md"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
has() { grep -cF -- "$2" "$1" >/dev/null 2>&1; }

check_rule() { # <label> <file>: a mutation rule that uses commands.test_case
  local label="$1" f="$2"
  if has "$f" 'commands.test_case' && has "$f" '{name}'; then
    pass "$label: names commands.test_case and its {name} placeholder"
  else
    fail "$label: names commands.test_case and its {name} placeholder"
  fi
  if has "$f" 'passes at the unmutated head'; then
    pass "$label: a single-case run counts only after it passes at the unmutated head"
  else
    fail "$label: a single-case run counts only after it passes at the unmutated head"
  fi
  if has "$f" 'the mutant run also shows exactly one test ran' && has "$f" 'green is survived' && ! has "$f" 'which failed'; then
    pass "$label: the mutant run must also show exactly one test, scored as usual (green is survived)"
  else
    fail "$label: the mutant run must also show exactly one test, scored as usual (green is survived)"
  fi
  if has "$f" 'shows zero tests or more than one'; then
    pass "$label: zero tests or more than one on either run falls back to the file"
  else
    fail "$label: zero tests or more than one on either run falls back to the file"
  fi
  if has "$f" 'before you save the baseline' || has "$f" 'before it saves the baseline'; then
    pass "$label: the single-case check runs before the baseline is saved, not after a restore"
  else
    fail "$label: the single-case check runs before the baseline is saved, not after a restore"
  fi
}

check_rule "agents/reviewer.md" "$PLUGIN/agents/reviewer.md"
check_rule "specs/reviewer.md" "$SPEC"
check_rule "evidence-review-prompt.md" "$PLUGIN/scripts/providers/evidence-review-prompt.md"

# The reviewer's input list documents the key
if grep -cE '^\s*- `commands\.test_case`' "$PLUGIN/agents/reviewer.md" >/dev/null; then
  pass "agents/reviewer.md: the Config JSON input lists commands.test_case"
else
  fail "agents/reviewer.md: the Config JSON input lists commands.test_case"
fi

# The provider evidence reviewer gets the key in its config
if grep -cE 'commands \| \{test_one, test_case,' "$PLUGIN/scripts/evidence-review.sh" >/dev/null; then
  pass "evidence-review.sh: the provider reviewer's config carries commands.test_case"
else
  fail "evidence-review.sh: the provider reviewer's config carries commands.test_case"
fi

# The docs describe it
if grep -cE '^\| `commands\.test_case` \|' "$PLUGIN/README.md" >/dev/null; then
  pass "README.md: the config table has a commands.test_case row"
else
  fail "README.md: the config table has a commands.test_case row"
fi
if has "$PLUGIN/docs/config.md" "go test -v -run '^{name}\$' ./\$(dirname {file})" && ! has "$PLUGIN/docs/config.md" "-run '^{name}\$' ./..."; then
  pass "docs/config.md: the go example prints one line per test and stays in the file's package"
else
  fail "docs/config.md: the go example prints one line per test and stays in the file's package"
fi
if has "$PLUGIN/docs/config.md" 'the mutant run also shows exactly one test ran'; then
  pass "docs/config.md: states the mutant-run condition as the rule files do"
else
  fail "docs/config.md: states the mutant-run condition as the rule files do"
fi
if has "$PLUGIN/docs/config.md" 'commands.test_case'; then
  pass "docs/config.md: documents commands.test_case"
else
  fail "docs/config.md: documents commands.test_case"
fi

echo ""
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
