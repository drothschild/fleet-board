#!/usr/bin/env bash
#
# Plain-bash tests: reverting to an earlier card-lint result is re-commented.
#
# Usage: bash plugins/fleet-board/tests/test-card-lint-revert.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LINT="$SCRIPT_DIR/../scripts/card-lint.sh"
PLAN="$SCRIPT_DIR/../scripts/tick-plan.sh"
FIX="$SCRIPT_DIR/lint-fixtures"
README="$SCRIPT_DIR/../README.md"
MANAGER="$SCRIPT_DIR/../agents/manager.md"
unset FLEET_BOARD_CONFIG FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT || true

PASS=0
FAIL=0
LAST_OUT=""
LAST_ERR=""
LAST_EXIT=0
CLEANUP_DIRS=()
ORIG_PATH="$PATH"
BASH_EXE="bash"
[ -x /bin/bash ] && BASH_EXE="/bin/bash"

cleanup() { for d in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do rm -rf "$d" 2>/dev/null || true; done; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi; }
assert_contains() {
  case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "expected '$3' in: $2" ;; esac
}
assert_not_contains() {
  case "$2" in *"$3"*) fail "$1" "did not expect '$3' in: $2" ;; *) pass "$1" ;; esac
}

run_check() {
  local script="$1"; shift
  local o e
  o="$(mktemp)"; e="$(mktemp)"
  "$BASH_EXE" "$script" "$@" > "$o" 2> "$e"
  LAST_EXIT=$?
  LAST_OUT="$(cat "$o")"; LAST_ERR="$(cat "$e")"
  rm -f "$o" "$e"
}

# setup_card <body-file> [comments-json]: a temp repo whose fake gh serves
# card 13 (Ready) with that body, on the labels backend
setup_card() {
  REPO="$(mktemp -d)"
  git init -q "$REPO"
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name T
  printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\n' > "$REPO/.fleet-board.yml"
  git -C "$REPO" add .fleet-board.yml
  git -C "$REPO" commit -q -m initial
  FAKE_GH_DIR="$(mktemp -d)"
  mkdir -p "$FAKE_GH_DIR/bin"
  ln -s "$SCRIPT_DIR/fake-gh.sh" "$FAKE_GH_DIR/bin/gh"
  local d="$FAKE_GH_DIR/routes.d"
  mkdir -p "$d"
  jq -n --rawfile b "$1" '{number:13,title:"Add clamp",html_url:"x",body:$b,labels:[{name:"fleet:ready"}]}' > "$d/issue.json"
  printf '%s\n' "${2:-[]}" > "$d/comments.json"
  printf '[{"number":13,"title":"Add clamp","url":"x","labels":[{"name":"fleet:ready"}]}]\n' > "$d/list.json"
  printf '[]\n' > "$d/empty.json"
  printf '{"login":"fleet-bot"}\n' > "$d/user.json"
  {
    printf 'api user\t0\t%s\n' "$d/user.json"
    printf 'api repos/acme/toy/issues/13\t0\t%s\n' "$d/issue.json"
    printf 'api --paginate repos/acme/toy/issues/13/comments\t0\t%s\n' "$d/comments.json"
    printf 'issue list --repo acme/toy --label fleet:ready *\t0\t%s\n' "$d/list.json"
    printf 'issue list --repo acme/toy --label fleet:in_progress *\t0\t%s\n' "$d/empty.json"
    printf 'issue list --repo acme/toy --label fleet:in_review *\t0\t%s\n' "$d/empty.json"
    printf 'issue list --repo acme/toy --label fleet:blocked *\t0\t%s\n' "$d/empty.json"
  } > "$d/routes"
  PATH="$FAKE_GH_DIR/bin:$ORIG_PATH"
  FAKE_GH_ROUTES="$d/routes"
  export FAKE_GH_DIR FAKE_GH_ROUTES PATH
  CLEANUP_DIRS+=("$REPO" "$FAKE_GH_DIR")
  cd "$REPO"
}

lint() { setup_card "$1"; run_check "$LINT" 13; }
plan() { setup_card "$@"; run_check "$PLAN"; }
card() { jq -c "(.cards[] | select(.number == 13)).$1" <<<"$LAST_OUT" 2>/dev/null || echo INVALID; }

echo ""

# A card with the heading and bullets passes silently (the same phrases under
# ## Human QA do not trigger manual-check)
lint "$FIX/ok-with-human-qa.md"

echo "Test: card-lint marker compares with the latest posted result only"
echo ""

plan "$FIX/no-bullets.md"
MA="$(jq -r "(.cards[] | select(.number == 13)).lint_marker" <<<"$LAST_OUT")"
plan "$FIX/manual-check.md"
MB="$(jq -r "(.cards[] | select(.number == 13)).lint_marker" <<<"$LAST_OUT")"
assert_eq "markers A and B differ" "$([ "$MA" != "$MB" ] && echo yes)" yes

HIST="$(jq -cn --arg a "$MA
lint A" --arg b "$MB
lint B" '[{"id":5,"user":{"login":"fleet-bot"},"body":$a,"created_at":"2026-01-01T00:00:00Z"},{"id":6,"user":{"login":"fleet-bot"},"body":$b,"created_at":"2026-01-02T00:00:00Z"}]')"
plan "$FIX/no-bullets.md" "$HIST"
assert_eq "A,B then A: comment needed" "$(card comment_needed)" true

plan "$FIX/manual-check.md" "$HIST"
assert_eq "A,B then B: same as latest, no comment" "$(card comment_needed)" false

HIST_A="$(jq -cn --arg a "$MA
lint A" '[{"id":5,"user":{"login":"fleet-bot"},"body":$a,"created_at":"2026-01-01T00:00:00Z"}]')"
plan "$FIX/no-bullets.md" "$HIST_A"
assert_eq "A then A: one comment only" "$(card comment_needed)" false

# Existing card-lint comment suite still passes unchanged.
EXIST_OUT="$("$BASH_EXE" "$SCRIPT_DIR/test-card-lint.sh" 2>&1)"; EXIST_RC=$?
assert_eq "existing test-card-lint.sh suite passes (exit 0)" "$EXIST_RC" 0
assert_contains "existing test-card-lint.sh reports zero failures" "$EXIST_OUT" "Failed: 0"

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
