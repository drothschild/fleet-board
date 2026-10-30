#!/usr/bin/env bash
#
# Plain-bash tests for the CI workflow (.github/workflows/tests.yml) and its
# suite runner (.github/scripts/run-suites.sh).
#
# Two modes:
#   * default: run every check below against the real repo files and exit
#     non-zero if any fail.
#   * WORKFLOW=<file> with --check-only: run only the workflow checks against
#     that file (used by this script to prove the checks can fail on mutants).
#
# Usage: bash plugins/fleet-board/tests/test-ci-workflow.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WF_REAL="${ROOT}/.github/workflows/tests.yml"
RUNNER="${ROOT}/.github/scripts/run-suites.sh"
GLOB='plugins/fleet-board/tests/test-*.sh'

# workflow_problems FILE: print one line per problem; no output means OK.
workflow_problems() {
  local wf="$1"
  if [ ! -f "$wf" ]; then echo "workflow file missing: $wf"; return; fi
  grep -q 'ubuntu-latest' "$wf" || echo "matrix lacks ubuntu-latest"
  grep -q 'macos-latest' "$wf" || echo "matrix lacks macos-latest"
  grep -qF "$GLOB" "$wf" || echo "workflow does not run $GLOB"
  grep -q 'behavioral-' "$wf" && echo "workflow includes behavioral suites"
  grep -qiE 'brew|homebrew' "$wf" && echo "workflow uses Homebrew"
  # any bash path other than exactly /bin/bash
  grep -oE '[A-Za-z0-9_./~$-]*/bash([^A-Za-z0-9_-]|$)' "$wf" \
    | sed -E 's/[^A-Za-z0-9_]$//' | grep -vx '/bin/bash' | grep -q . \
    && echo "workflow uses a bash path outside /bin/bash"
  grep -q '/bin/bash' "$wf" || echo "workflow does not select /bin/bash"
  # the glob must cover test-clean-room.sh
  case "plugins/fleet-board/tests/test-clean-room.sh" in
    plugins/fleet-board/tests/test-*.sh) : ;;
    *) echo "glob misses test-clean-room.sh" ;;
  esac
  [ -f "${ROOT}/plugins/fleet-board/tests/test-clean-room.sh" ] \
    || echo "test-clean-room.sh missing"
}

if [ "${1:-}" = "--check-only" ]; then
  out="$(workflow_problems "${WORKFLOW:-$WF_REAL}")"
  [ -z "$out" ] && exit 0
  printf '%s\n' "$out"
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILS=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { FAILS=$((FAILS + 1)); printf '  FAIL %s\n' "$1"; }

# 1. Real workflow passes all checks.
out="$(workflow_problems "$WF_REAL")"
if [ -z "$out" ]; then pass "workflow lists both runners, runs the glob, uses /bin/bash"
else fail "real workflow: $out"; fi

# Each mutant must make the check fail (a suite that cannot fail proves nothing).
mutant() { # name sed-expr
  local name="$1" expr="$2" f="$TMP/m.yml"
  if [ ! -f "$WF_REAL" ]; then fail "mutant $name: no workflow to mutate"; return; fi
  sed -E "$expr" "$WF_REAL" > "$f"
  if cmp -s "$f" "$WF_REAL"; then fail "mutant $name: sed changed nothing"; return; fi
  if WORKFLOW="$f" bash "$0" --check-only >/dev/null 2>&1; then
    fail "mutant $name was accepted"
  else pass "mutant rejected: $name"; fi
}
mutant "glob includes behavioral-*.sh" 's#test-\*\.sh#behavioral-*.sh#'
mutant "brew install bash" 's#/bin/bash#brew install bash#'
mutant "bash path outside /bin/bash" 's#/bin/bash#/opt/homebrew/bin/bash#'
mutant "ubuntu-latest dropped" 's#ubuntu-latest#ubuntu-20.04#'
mutant "macos-latest dropped" 's#macos-latest#macos-13#'

# 2. Runner: fixture dir with one passing and one failing suite.
FIX="$TMP/fix"; mkdir -p "$FIX"
printf 'echo hi\nexit 0\n' > "$FIX/test-pass.sh"
printf 'echo boom\nexit 3\n' > "$FIX/test-fail.sh"
if [ ! -f "$RUNNER" ]; then
  fail "runner missing: $RUNNER"
else
  out="$(bash "$RUNNER" "$FIX/test-*.sh" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && pass "runner exits non-zero when a suite fails" \
    || fail "runner exited 0 despite a failing suite"
  printf '%s\n' "$out" | grep -q 'test-pass.sh.*PASS' \
    && pass "runner prints passing suite name and result" \
    || fail "runner output lacks 'test-pass.sh ... PASS': $out"
  printf '%s\n' "$out" | grep -q 'test-fail.sh.*FAIL' \
    && pass "runner prints failing suite name and result" \
    || fail "runner output lacks 'test-fail.sh ... FAIL': $out"
  rm "$FIX/test-fail.sh"
  bash "$RUNNER" "$FIX/test-*.sh" >/dev/null 2>&1 \
    && pass "runner exits 0 when all suites pass" \
    || fail "runner exited non-zero with only passing suites"
fi

# 3. Badge in both READMEs within the first five lines.
for r in "${ROOT}/README.md" "${ROOT}/plugins/fleet-board/README.md"; do
  if head -5 "$r" | grep -qE '!\[[^]]*\]\([^)]*tests\.yml[^)]*\)'; then
    pass "tests.yml badge in first 5 lines of ${r#"$ROOT"/}"
  else fail "no tests.yml badge in first 5 lines of ${r#"$ROOT"/}"; fi
done

echo
if [ "$FAILS" -eq 0 ]; then echo "all passed"; exit 0; fi
echo "$FAILS failed"; exit 1
