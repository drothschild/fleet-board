#!/usr/bin/env bash
#
# Plain-bash tests for tick-plan.sh printing "resets at <ISO UTC>" on a GitHub
# rate-limit failure (offline, stub gh).
#
# Usage: bash plugins/fleet-board/tests/test-tick-plan-resets-at.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/../scripts/tick-plan.sh"

PASS=0
FAIL=0
CLEANUP_DIRS=()
cleanup() { for d in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do rm -rf "$d" 2>/dev/null || true; done; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

# run_case <list-error-text> <rate_limit mode: ok|fail>
# The stub gh answers api user, answers "api rate_limit" per mode, and fails
# every other call with the given text on stderr.
run_case() {
  local errtext="$1" mode="$2" repo bin
  repo="$(mktemp -d)"; CLEANUP_DIRS+=("$repo")
  git init -q "$repo"
  printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\n' > "$repo/.fleet-board.yml"
  bin="$repo/bin"; mkdir -p "$bin"
  cat > "$bin/gh" <<STUB
#!/usr/bin/env bash
case "\$*" in
  "api user") echo '{"login":"tester"}'; exit 0 ;;
  "api rate_limit")
    if [ "$mode" = ok ]; then echo '{"resources":{"core":{"reset":1767225600}}}'; exit 0; fi
    echo "rate limit query broke" >&2; exit 1 ;;
esac
echo "$errtext" >&2
exit 1
STUB
  chmod +x "$bin/gh"
  ERRF="$repo/err"
  (cd "$repo" && PATH="$bin:$PATH" bash "$SCRIPT" >/dev/null 2>"$ERRF")
  RC=$?
  ERR="$(cat "$ERRF")"
}

echo "Test: tick-plan.sh resets at"
echo ""

# Rate limit failure: resets at the reply's time, as UTC ISO 8601
run_case "gh: API rate limit exceeded for user" ok
if [ "$RC" -ne 0 ]; then pass "rate limit: exits non-zero"; else fail "rate limit: exits non-zero" "exit $RC"; fi
case "$ERR" in *"API rate limit exceeded"*) pass "rate limit: original error kept" ;; *) fail "rate limit: original error kept" "$ERR" ;; esac
case "$ERR" in *"resets at 2026-01-01T00:00:00Z"*) pass "rate limit: prints resets at the reply's reset time" ;; *) fail "rate limit: prints resets at the reply's reset time" "$ERR" ;; esac
if printf '%s\n' "$ERR" | grep -Eq 'resets at [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
  pass "rate limit: the time is UTC ISO 8601 (pattern)"
else fail "rate limit: the time is UTC ISO 8601 (pattern)" "$ERR"; fi

# The rate-limit query itself fails: original error, no resets at, still non-zero
run_case "gh: API rate limit exceeded for user" fail
if [ "$RC" -ne 0 ]; then pass "query fails: still exits non-zero"; else fail "query fails: still exits non-zero" "exit $RC"; fi
case "$ERR" in *"API rate limit exceeded"*) pass "query fails: original error kept" ;; *) fail "query fails: original error kept" "$ERR" ;; esac
case "$ERR" in *"resets at"*) fail "query fails: no resets at text" "$ERR" ;; *) pass "query fails: no resets at text" ;; esac

# Not a rate limit
run_case "gh: HTTP 500 server error" ok
if [ "$RC" -ne 0 ]; then pass "not a rate limit: exits non-zero"; else fail "not a rate limit: exits non-zero" "exit $RC"; fi
case "$ERR" in *"resets at"*) fail "not a rate limit: no resets at text" "$ERR" ;; *) pass "not a rate limit: no resets at text" ;; esac

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
