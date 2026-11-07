#!/usr/bin/env bash
#
# Plain-bash tests for tick-plan.sh printing "resets at <ISO UTC>" when a
# GitHub lookup hits a rate limit (offline, fake gh). The board is local, so
# the lookup is the card's PR view: the fake gh answers it with a rate-limit
# message on stderr (a .stderr fixture), and answers "api rate_limit" per case.
#
# Usage: bash plugins/fleet-board/tests/test-tick-plan-resets-at.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/../scripts/tick-plan.sh"
MARK='<!-- fleet-board:manager-note -->'

unset FLEET_BOARD_CONFIG FAKE_GH_ALLOW_BOARD || true
export FLEET_BOARD_USER=tester

PASS=0
FAIL=0
CLEANUP_DIRS=()
cleanup() { for d in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do rm -rf "$d" 2>/dev/null || true; done; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

# run_case <pr-view error text> <rate_limit mode: ok|fail>
# A local store with card 12 in in_review whose note names PR 34. The fake gh
# answers "pr view 34" with exit 1 and the text on stderr, and "api
# rate_limit" with a reset time (ok) or a failure.
run_case() {
  local errtext="$1" mode="$2" repo gh
  repo="$(mktemp -d)"; CLEANUP_DIRS+=("$repo")
  git init -q "$repo"
  printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\n' > "$repo/.fleet-board.yml"
  mkdir -p "$repo/.fleet-board/cards"
  echo 13 > "$repo/.fleet-board/next"
  jq -n --arg m "$MARK" '{number: 12, title: "Add subtract", body: "", acceptance: ["works"], blocked_by: [],
      pr_url: null, pr_url_source: null, state: "in_review", labels: [], next_comment_id: 2,
      comments: [{id: 1, author: "tester", created_at: "2026-01-01T00:00:00Z",
        body: ($m + "\n### n\n\n```json\n{\"state\":\"in_review\",\"branch\":\"fleet/12-add-subtract\",\"pr\":34,\"round\":1}\n```\n")}]}' \
    > "$repo/.fleet-board/cards/12.json"
  gh="$repo/gh"; mkdir -p "$gh/bin"
  ln -s "$SCRIPT_DIR/fake-gh.sh" "$gh/bin/gh"
  printf '%s\n' "$errtext" > "$gh/pr.stderr"
  printf '{"resources":{"core":{"reset":1767225600}}}\n' > "$gh/rate.json"
  printf 'rate limit query broke\n' > "$gh/rate.stderr"
  {
    printf 'pr view 34 --repo acme/toy --json *\t1\t%s\n' "$gh/pr.stderr"
    if [ "$mode" = ok ]; then printf 'api rate_limit\t0\t%s\n' "$gh/rate.json"
    else printf 'api rate_limit\t1\t%s\n' "$gh/rate.stderr"; fi
  } > "$gh/routes"
  ERRF="$repo/err"
  (cd "$repo" && PATH="$gh/bin:$PATH" FAKE_GH_DIR="$gh" FAKE_GH_ROUTES="$gh/routes" bash "$SCRIPT" > "$repo/out" 2>"$ERRF")
  RC=$?
  ERR="$(cat "$ERRF")"
  OUT="$(cat "$repo/out")"
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
if [ -z "$OUT" ]; then pass "rate limit: no plan printed"; else fail "rate limit: no plan printed" "$OUT"; fi

# The rate-limit query itself fails: original error, no resets at, still non-zero
run_case "gh: API rate limit exceeded for user" fail
if [ "$RC" -ne 0 ]; then pass "query fails: still exits non-zero"; else fail "query fails: still exits non-zero" "exit $RC"; fi
case "$ERR" in *"API rate limit exceeded"*) pass "query fails: original error kept" ;; *) fail "query fails: original error kept" "$ERR" ;; esac
case "$ERR" in *"resets at"*) fail "query fails: no resets at text" "$ERR" ;; *) pass "query fails: no resets at text" ;; esac

# Not a rate limit: the card is skipped (lookup failed) and the plan is printed
run_case "gh: HTTP 500 server error" ok
if [ "$RC" -eq 0 ]; then pass "not a rate limit: the plan is printed (exit 0)"; else fail "not a rate limit: the plan is printed (exit 0)" "exit $RC: $ERR"; fi
case "$(jq -r '.cards[0].action' <<<"$OUT" 2>/dev/null)" in skip) pass "not a rate limit: the card is skipped" ;; *) fail "not a rate limit: the card is skipped" "$OUT" ;; esac
case "$ERR" in *"resets at"*) fail "not a rate limit: no resets at text" "$ERR" ;; *) pass "not a rate limit: no resets at text" ;; esac

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
