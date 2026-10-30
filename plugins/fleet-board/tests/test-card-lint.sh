#!/usr/bin/env bash
#
# Plain-bash tests for card-lint.sh and the skip_card_lint action in
# tick-plan.sh (offline, fake gh). Card bodies are fixtures/lint/*.md.
#
# Usage: bash plugins/fleet-board/tests/test-card-lint.sh

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

echo "Test: card-lint.sh"
echo ""

# A card with the heading and bullets passes silently (the same phrases under
# ## Human QA do not trigger manual-check)
lint "$FIX/ok-with-human-qa.md"
assert_eq "ok: exit 0" "$LAST_EXIT" 0
assert_eq "ok: prints nothing" "$LAST_OUT" ""

# no-heading
lint "$FIX/no-heading-bold.md"
assert_eq "no-heading bold: exit 1" "$LAST_EXIT" 1
assert_contains "no-heading bold: names the rule" "$LAST_OUT" "no-heading"
lint "$FIX/no-heading-colon.md"
assert_eq "no-heading colon: exit 1" "$LAST_EXIT" 1
assert_contains "no-heading colon: names the rule" "$LAST_OUT" "no-heading"
lint "$FIX/plain-no-heading.md"
assert_eq "no-heading plain: exit 1" "$LAST_EXIT" 1
assert_contains "no-heading plain: names the rule" "$LAST_OUT" "no-heading"

# no-bullets
lint "$FIX/no-bullets.md"
assert_eq "no-bullets: exit 1" "$LAST_EXIT" 1
assert_contains "no-bullets: names the rule" "$LAST_OUT" "no-bullets"
assert_not_contains "no-bullets: not no-heading" "$LAST_OUT" "no-heading"

# manual-check, one phrase at a time
for phrase in "on device" "on a device" "verify on" "by hand" "Human QA" "simulator"; do
  body="$(mktemp)"; CLEANUP_DIRS+=("$body")
  printf '## Acceptance\n- clamp returns 3\n- check the layout %s please\n' "$phrase" > "$body"
  lint "$body"
  assert_eq "manual-check '$phrase': exit 1" "$LAST_EXIT" 1
  assert_contains "manual-check '$phrase': names the rule" "$LAST_OUT" "manual-check"
  assert_contains "manual-check '$phrase': names the bullet" "$LAST_OUT" "check the layout $phrase please"
  assert_not_contains "manual-check '$phrase': ignores the clean bullet" "$LAST_OUT" "clamp returns 3"
done
lint "$FIX/manual-check.md"
assert_contains "manual-check fixture: offending bullet" "$LAST_OUT" "The slider looks right on device"

# usage
run_check "$LINT"
assert_eq "no argument: exit 2" "$LAST_EXIT" 2
run_check "$LINT" abc
assert_eq "non-numeric: exit 2" "$LAST_EXIT" 2

echo ""
echo "Test: tick-plan.sh skip_card_lint"
echo ""

plan "$FIX/no-bullets.md"
assert_eq "plan no-bullets: exit" "$LAST_EXIT" 0
assert_eq "plan no-bullets: action" "$(card action)" '"skip_card_lint"'
assert_contains "plan no-bullets: lint result in the plan" "$(card lint)" "no-bullets"
assert_eq "plan no-bullets: comment_needed" "$(card comment_needed)" true
assert_eq "plan no-bullets: dispatchable (a comment is due)" "$(jq -c .dispatchable <<<"$LAST_OUT")" true
MARKER="$(jq -r "(.cards[] | select(.number == 13)).lint_marker" <<<"$LAST_OUT")"
assert_contains "plan no-bullets: marker shape" "$MARKER" "<!-- fleet-board:card-lint:"

plan "$FIX/manual-check.md"
assert_eq "plan manual-check: action" "$(card action)" '"skip_card_lint"'
assert_contains "plan manual-check: lint names the bullet" "$(card lint)" "The slider looks right on device"
MARKER2="$(jq -r "(.cards[] | select(.number == 13)).lint_marker" <<<"$LAST_OUT")"

plan "$FIX/no-heading-bold.md"
assert_eq "plan bold Acceptance: action" "$(card action)" '"skip_card_lint"'

# a body with no hint at all stays skip_no_acceptance
plan "$FIX/plain-no-heading.md"
assert_eq "plan plain no heading: stays skip_no_acceptance" "$(card action)" '"skip_no_acceptance"'

# a clean card starts, with no lint
plan "$FIX/ok-with-human-qa.md"
assert_eq "plan ok: action start" "$(card action)" '"start"'
assert_eq "plan ok: lint null" "$(card lint)" null

# same lint result already commented: no new comment; a changed result: new one
COMMENTS="$(jq -cn --arg b "$MARKER
Card lint failed" '[{"id":5,"user":{"login":"fleet-bot"},"body":$b,"created_at":"2026-01-01T00:00:00Z"}]')"
plan "$FIX/no-bullets.md" "$COMMENTS"
assert_eq "plan repeat: still skip_card_lint" "$(card action)" '"skip_card_lint"'
assert_eq "plan repeat: same result needs no comment" "$(card comment_needed)" false
assert_eq "plan repeat: not dispatchable" "$(jq -c .dispatchable <<<"$LAST_OUT")" false
plan "$FIX/manual-check.md" "$COMMENTS"
assert_eq "plan changed: new result needs a comment" "$(card comment_needed)" true
assert_eq "plan changed: marker differs" "$([ "$MARKER" != "$MARKER2" ] && echo yes)" yes

echo ""
echo "Test: docs"
echo ""
section="$(sed -n '/^### Writing a card/,/^## /p' "$README")"
for rule in no-heading no-bullets manual-check; do
  assert_contains "README Writing a card links $rule" "$section" "(#card-lint-$rule)"
  assert_contains "README has an anchor heading for $rule" "$(cat "$README")" "card-lint-$rule"
done
assert_contains "manager.md handles skip_card_lint" "$(cat "$MANAGER")" "skip_card_lint"

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
