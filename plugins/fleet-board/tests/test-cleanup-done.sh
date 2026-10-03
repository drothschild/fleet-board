#!/usr/bin/env bash
#
# Plain-bash tests for cleanup-done.sh (offline: fake gh for the board, a
# local git repo with real worktrees under the worktrees base). No framework,
# no dependencies beyond POSIX tools, jq and git.
#
# Usage: bash plugins/fleet-board/tests/test-cleanup-done.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/../scripts/cleanup-done.sh"
FIXTURES="$SCRIPT_DIR/../fixtures/gh"
MARK='<!-- fleet-board:manager-note -->'

unset FLEET_BOARD_CONFIG FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT || true

PASS=0
FAIL=0
LAST_OUT=""
LAST_ERR=""
LAST_EXIT=0
CLEANUP_DIRS=()
ORIG_PATH="$PATH"

if [ -x /bin/bash ]; then
  BASH_EXE="/bin/bash"
else
  BASH_EXE="bash"
fi

cleanup() {
  for dir in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do
    rm -rf "$dir" 2>/dev/null || true
  done
}
trap cleanup EXIT

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
    *) fail "$1" "expected '$2' in stderr, got: '$LAST_ERR'" ;;
  esac
}
# assert_true <desc> <command...>: passes when the command succeeds
assert_true() {
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d" "command failed: $*"; fi
}
# assert_false <desc> <command...>: passes when the command fails
assert_false() {
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$d" "command succeeded: $*"; else pass "$d"; fi
}

run_check() {
  local tmpout tmperr
  tmpout="$(mktemp)"
  tmperr="$(mktemp)"
  "$BASH_EXE" "$SCRIPT" "$@" > "$tmpout" 2> "$tmperr"
  LAST_EXIT=$?
  LAST_OUT="$(cat "$tmpout")"
  LAST_ERR="$(cat "$tmperr")"
  rm -f "$tmpout" "$tmperr"
}

# list_route <label> <state> <cards json>: a column listing
list_route() {
  printf '%s\n' "$3" > "$FAKE_GH_DIR/list-$1.json"
  printf 'issue list --repo acme/toy --label fleet:%s --state %s --json number,title,url,labels --limit 500\t0\t%s\n' \
    "$1" "$2" "$FAKE_GH_DIR/list-$1.json" >> "$ROUTES"
}

# item <n> <label>: one listing row
item() { jq -cn --argjson n "$1" --arg l "$2" '{number:$n, title:"t\($n)", url:"u", labels:[{name:$l}]}'; }

# card <n> <label> <note json or empty>: the card's read routes
card() {
  jq -cn --argjson n "$1" --arg l "$2" \
    '{number:$n, title:"t\($n)", html_url:"https://github.com/acme/toy/issues/\($n)", body:"b", labels:[{name:$l}]}' \
    > "$FAKE_GH_DIR/issue-$1.json"
  if [ -n "$3" ]; then
    jq -cn --arg m "$MARK" --arg j "$3" '
      [{id:555,user:{login:"fleet-bot"},
        body:($m + "\n### fleet-board manager note\nState: x\n\n```json\n" + $j + "\n```\n"),
        created_at:"2026-09-28T00:01:00Z"}]' > "$FAKE_GH_DIR/comments-$1.json"
  else
    printf '[]\n' > "$FAKE_GH_DIR/comments-$1.json"
  fi
  printf 'api repos/acme/toy/issues/%s\t0\t%s\n' "$1" "$FAKE_GH_DIR/issue-$1.json" >> "$ROUTES"
  printf 'api --paginate repos/acme/toy/issues/%s/comments\t0\t%s\n' "$1" "$FAKE_GH_DIR/comments-$1.json" >> "$ROUTES"
}

# note_wt <path>: a note JSON naming a worktree
note_wt() { jq -cn --arg w "$1" '{state:"done", branch:"fleet/1-x", worktree:$w, pr:3, round:1}'; }

# worktrees <n>: a card worktree on its own branch, a detached review
# worktree, and a review copy, all under the base
worktrees() {
  git -C "$REPO" worktree add -q -b "fleet/$1-x" "$BASE/$1-x" 2>/dev/null
  git -C "$REPO" worktree add -q --detach "$BASE/$1-review" 2>/dev/null
  mkdir -p "$BASE/$1-review-copy" && printf 'c\n' > "$BASE/$1-review-copy/file"
}

# setup_case [extra routes, prepended]
# Cards: #12 done with all three dirs; #13 done, already clean; #14 in_review
# with dirs (not done: untouched); #15 done with a leftover 15-x dir, its
# note's worktree outside the base (/etc style path; note.sh nulls it and warns); #16 done, its note's worktree a symlink under the base
# pointing outside it (valid note, refused by worktree.sh); #17 done, no note.
setup_case() {
  local tmp; tmp="$(mktemp -d)"
  CLEANUP_DIRS+=("$tmp")
  TMPROOT="$(cd "$tmp" && pwd -P)"
  REPO="$TMPROOT/repo"
  git init -q "$REPO"
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test User"
  printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\n' > "$REPO/.fleet-board.yml"
  printf '.fw/\n' > "$REPO/.gitignore"
  git -C "$REPO" add .fleet-board.yml .gitignore
  git -C "$REPO" commit -q -m "initial"
  BASE="$(mkdir -p "$REPO/.fw" && cd "$REPO/.fw" && pwd -P)"

  worktrees 12
  worktrees 14
  mkdir -p "$BASE/15-x" # #15 has a leftover dir, so its note is read (and nulled)
  mkdir -p "$TMPROOT/outside" && printf 's\n' > "$TMPROOT/outside/sentinel"
  mkdir -p "$TMPROOT/etc" && printf 's\n' > "$TMPROOT/etc/sentinel"
  ln -s "$TMPROOT/outside" "$BASE/16-link"

  FAKE_GH_DIR="$TMPROOT/gh"
  BIN="$FAKE_GH_DIR/bin"
  mkdir -p "$BIN"
  ln -s "$SCRIPT_DIR/fake-gh.sh" "$BIN/gh"
  ROUTES="$FAKE_GH_DIR/routes.txt"
  printf '%s' "${1:-}" > "$ROUTES"
  printf 'api user\t0\t%s\n' "$FIXTURES/labels/user.json" >> "$ROUTES"

  list_route done all "[$(item 12 fleet:done),$(item 13 fleet:done),$(item 15 fleet:done),$(item 16 fleet:done),$(item 17 fleet:done)]"
  list_route in_review open "[$(item 14 fleet:in_review)]"
  card 12 fleet:done "$(note_wt "$BASE/12-x")"
  card 13 fleet:done "$(note_wt "$BASE/13-x")"
  card 14 fleet:in_review "$(note_wt "$BASE/14-x")"
  card 15 fleet:done "$(note_wt "$TMPROOT/etc")"
  card 16 fleet:done "$(note_wt "$BASE/16-link")"
  card 17 fleet:done ""

  unset CDPATH FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT FLEET_BOARD_CONFIG || true
  PATH="$BIN:$ORIG_PATH"
  export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH
  cd "$REPO"
}

wt_listed() { git -C "$REPO" worktree list --porcelain | grep -qxF "worktree $1"; }

echo "Test: cleanup-done.sh"
echo ""

# ---------------------------------------------------------------------------
setup_case
run_check
assert_exit "one card fails (hostile notes): exit 1" 1
assert_stdout_exact "one line per card cleaned, only #12" "cleaned #12 $BASE/12-x"
assert_false "done-with-dirs: card worktree gone" test -e "$BASE/12-x"
assert_false "done-with-dirs: review worktree gone" test -e "$BASE/12-review"
assert_false "done-with-dirs: review copy gone" test -e "$BASE/12-review-copy"
assert_false "done-with-dirs: git no longer lists the card worktree" wt_listed "$BASE/12-x"
assert_true "done-with-dirs: the branch survives" git -C "$REPO" rev-parse -q --verify refs/heads/fleet/12-x
assert_true "not-done: in_review worktree untouched" test -d "$BASE/14-x"
assert_true "not-done: in_review review worktree untouched" test -d "$BASE/14-review"
assert_true "not-done: in_review copy untouched" test -f "$BASE/14-review-copy/file"
assert_true "hostile-note: outside dir untouched" test -f "$TMPROOT/etc/sentinel"
assert_stderr_contains "outside-base: warning naming the card" "#15"
assert_true "symlink-out: target untouched" test -f "$TMPROOT/outside/sentinel"
assert_true "symlink-out: link untouched" test -L "$BASE/16-link"
assert_stderr_contains "symlink-out: refusal reported for the card" "#16"

# Idempotent: a second run cleans nothing more; with only clean done cards it exits 0
run_check
assert_stdout_exact "second run: nothing cleaned" ""
assert_true "second run: in_review worktree still untouched" test -d "$BASE/14-x"

# done_only <n>...: the done column lists only these cards
done_only() {
  local rows="" n
  for n in "$@"; do rows="${rows:+$rows,}$(item "$n" fleet:done)"; done
  printf '[%s]\n' "$rows" > "$FAKE_GH_DIR/list-done.json"
}

setup_case
done_only 12 13 17
run_check
assert_exit "clean-board: exit 0" 0
assert_stdout_exact "clean-board: #12 cleaned" "cleaned #12 $BASE/12-x"
run_check
assert_exit "idempotent: second run exit 0" 0
assert_stdout_exact "idempotent: second run prints nothing" ""
assert_true "idempotent: in_review worktree untouched" test -d "$BASE/14-x"

# A done card whose note's worktree lies outside the base (another clone, a
# moved repo): nothing to remove, a warning, and not a failure
setup_case
done_only 15
run_check
assert_exit "outside-base alone: exit 0" 0
assert_stdout_exact "outside-base alone: nothing printed" ""
assert_stderr_contains "outside-base alone: warning names the card" "skipping #15: its manager note names a worktree outside $BASE; nothing removed"
assert_true "outside-base alone: outside dir untouched" test -f "$TMPROOT/etc/sentinel"

# A done card whose dirs are already gone is a no-op (#13 alone)
setup_case
done_only 13
run_check
assert_exit "already-clean: exit 0" 0
assert_stdout_exact "already-clean: nothing printed" ""

# The done column cannot be listed: exit 1, nothing removed
setup_case "$(printf 'issue list --repo acme/toy --label fleet:done *\t1\t-\n')
"
run_check
assert_exit "list-failure: exit 1" 1
assert_stdout_exact "list-failure: nothing printed" ""
assert_true "list-failure: #12 worktree untouched" test -d "$BASE/12-x"
assert_true "list-failure: #12 review untouched" test -d "$BASE/12-review"
assert_true "list-failure: #12 copy untouched" test -d "$BASE/12-review-copy"

# The done column is at the list limit: cleanup lists it with --allow-truncated,
# so it warns and still cleans (a missed old card only leaves a worktree behind)
setup_case "$(printf 'issue list --repo acme/toy --label fleet:done --state all --json number,title,url,labels --limit 3\t0\tlist-done.json\n')
"
done_only 12 13 17
FLEET_BOARD_LIST_LIMIT=3 run_check
assert_exit "done-at-limit: exit 0" 0
assert_stdout_exact "done-at-limit: #12 still cleaned" "cleaned #12 $BASE/12-x"
assert_stderr_contains "done-at-limit: warning names the limit" "list limit (3); the list may be truncated, continuing"
assert_false "done-at-limit: #12 worktree gone" test -e "$BASE/12-x"

# A note that cannot be read: that card is skipped, others still cleaned, exit 1
setup_case "$(printf 'api --paginate repos/acme/toy/issues/12/comments\t1\t-\n')
"
worktrees 18
card 18 fleet:done "$(note_wt "$BASE/18-x")"
done_only 12 18
run_check
assert_exit "unreadable-note: exit 1" 1
assert_true "unreadable-note: #12 untouched" test -d "$BASE/12-x"
assert_stderr_contains "unreadable-note: warning names #12" "#12"
assert_stdout_exact "unreadable-note: the next card is still cleaned" "cleaned #18 $BASE/18-x"

# ---------------------------------------------------------------------------
# Prefilter: a done card's note is read only when the base holds an entry
# named <n>-*. The done column grows without bound; the cost must scale with
# the local dirs, not with the column.

# card_read <n>: the fake gh was asked for card n's issue or its comments
card_read() { grep -qE "repos/acme/toy/issues/$1(/| |\$)" "$FAKE_GH_DIR/calls.log" 2>/dev/null; }
reset_calls() { rm -f "$FAKE_GH_DIR/calls.log"; }

# (a) several done cards, only #12 has dirs: only #12 is read, and it is cleaned
setup_case
card 19 fleet:done "$(note_wt "$BASE/19-x")"
done_only 12 13 17 19
reset_calls
run_check
assert_exit "prefilter-some: exit 0" 0
assert_stdout_exact "prefilter-some: #12 cleaned" "cleaned #12 $BASE/12-x"
assert_true "prefilter-some: #12 read" card_read 12
assert_false "prefilter-some: #13 (no dirs) not read" card_read 13
assert_false "prefilter-some: #17 (no dirs) not read" card_read 17
assert_false "prefilter-some: #19 (no dirs) not read" card_read 19

# (b) card 1 vs a dir 12-x: the prefix is <n>- exactly, so #1 is not read
setup_case
card 1 fleet:done "$(note_wt "$BASE/1-x")"
done_only 1 12
reset_calls
run_check
assert_exit "prefix-exact: exit 0" 0
assert_false "prefix-exact: #1 not read (12-x is not 1-*)" card_read 1
assert_true "prefix-exact: #12 read" card_read 12
assert_stdout_exact "prefix-exact: only #12 cleaned" "cleaned #12 $BASE/12-x"

# (c) an empty base: no per-card call at all, exit 0
setup_case
git -C "$REPO" worktree remove --force "$BASE/12-x" 2>/dev/null
git -C "$REPO" worktree remove --force "$BASE/12-review" 2>/dev/null
git -C "$REPO" worktree remove --force "$BASE/14-x" 2>/dev/null
git -C "$REPO" worktree remove --force "$BASE/14-review" 2>/dev/null
rm -rf "$BASE/12-review-copy" "$BASE/14-review-copy" "$BASE/15-x" "$BASE/16-link"
done_only 12 13 15 16 17
reset_calls
run_check
assert_exit "empty-base: exit 0" 0
assert_stdout_exact "empty-base: nothing printed" ""
assert_false "empty-base: no per-card gh call" grep -qE 'repos/acme/toy/issues/[0-9]' "$FAKE_GH_DIR/calls.log"
assert_true "empty-base: the base is still empty" sh -c '[ -z "$(ls -A "$1")" ]' _ "$BASE"

# (d) a <n>-review dir alone makes n a candidate; names with spaces are harmless
setup_case
git -C "$REPO" worktree add -q --detach "$BASE/22-review" 2>/dev/null
mkdir -p "$BASE/2 22-x" "$BASE/x 22-y"
card 22 fleet:done "$(note_wt "$BASE/22-x")"
card 2 fleet:done "$(note_wt "$BASE/2-x")"
done_only 2 22
reset_calls
run_check
assert_exit "review-only: exit 0" 0
assert_true "review-only: #22 read" card_read 22
assert_false "review-only: #2 not read ('2 22-x' is not 2-*)" card_read 2
assert_stdout_exact "review-only: #22 cleaned" "cleaned #22 $BASE/22-x"
assert_false "review-only: 22-review gone" test -e "$BASE/22-review"
assert_true "review-only: dirs with spaces untouched" test -d "$BASE/2 22-x"

# Usage
run_check --bogus
assert_exit "unknown argument: exit 2" 2

echo ""
echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
