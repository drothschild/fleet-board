#!/usr/bin/env bash
#
# Plain-bash tests for worktree.sh (offline: a local bare repo is origin, and
# gh is never called). No framework, no dependencies beyond POSIX tools, jq
# and git.
#
# Usage: bash plugins/fleet-board/tests/test-worktree.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/../scripts/worktree.sh"

unset FLEET_BOARD_CONFIG FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT || true

PASS=0
FAIL=0
LAST_OUT=""
LAST_ERR=""
LAST_EXIT=0
CLEANUP_DIRS=()

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

assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}

# assert_stderr_not_contains <desc> <text>: passes when stderr lacks the text
assert_stderr_not_contains() {
  case "$LAST_ERR" in
    *"$2"*) fail "$1" "did not expect '$2' in stderr: $LAST_ERR" ;;
    *) pass "$1" ;;
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

run_wt() { run_check "$SCRIPT" "$@"; }

# jq -c of the last stdout; INVALID when it does not parse
jqc() { jq -c "$1" <<<"$LAST_OUT" 2>/dev/null || echo INVALID; }

# commit_file <repo> <file> <content> <message>
commit_file() {
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -q -m "$4"
}

# Lines of a file, 0 when it is missing
line_count() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

# Whether `git worktree list` in the repo names the path
wt_listed() { git -C "$REPO" worktree list --porcelain | grep -qxF "worktree $1"; }

# setup_case <mutate_on_copy true|false>
# A bare origin with:
#   main                 A (README) then B (main.txt)
#   fleet/13-existing    A then E (existing.txt)
#   refs/pull/7/head     A then P (feature.txt), so merge-base(origin/main, P) = A
# REPO is a clone of it, holding an untracked .fleet-board.yml.
setup_case() {
  local tmp; tmp="$(mktemp -d)"
  CLEANUP_DIRS+=("$tmp")
  TMPROOT="$(cd "$tmp" && pwd -P)"
  ORIGIN="$TMPROOT/origin.git"
  SEED="$TMPROOT/seed"
  REPO="$TMPROOT/repo"
  git init -q --bare "$ORIGIN"
  git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
  git init -q "$SEED"
  git -C "$SEED" config user.email "test@example.com"
  git -C "$SEED" config user.name "Test User"
  git -C "$SEED" checkout -q -b main
  commit_file "$SEED" README "toy" "A"
  SHA_A="$(git -C "$SEED" rev-parse HEAD)"
  git -C "$SEED" checkout -q -b fleet/13-existing
  commit_file "$SEED" existing.txt "existing" "E"
  SHA_E="$(git -C "$SEED" rev-parse HEAD)"
  git -C "$SEED" checkout -q -b pr7 "$SHA_A"
  commit_file "$SEED" feature.txt "feature" "P"
  SHA_P="$(git -C "$SEED" rev-parse HEAD)"
  git -C "$SEED" checkout -q main
  commit_file "$SEED" main.txt "main" "B"
  SHA_B="$(git -C "$SEED" rev-parse HEAD)"
  git -C "$SEED" push -q "$ORIGIN" main fleet/13-existing "pr7:refs/pull/7/head" 2>/dev/null

  git clone -q "$ORIGIN" "$REPO" 2>/dev/null
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test User"
  printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\n  setup: "echo ran >> .setup-ran"\n  mutate_on_copy: %s\n' "$1" \
    > "$REPO/.fleet-board.yml"

  unset CDPATH FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT FLEET_BOARD_CONFIG || true
  cd "$REPO"
  BASE="$(mkdir -p "$REPO/.fw" && cd "$REPO/.fw" && pwd -P)"
}

echo "Test: worktree.sh"
echo ""

setup_case true

# ---------------------------------------------------------------------------
# create from origin: a new branch from origin/HEAD, setup ran
WT12="$BASE/12-add-subtract"
run_wt create 12 fleet/12-add-subtract "$WT12"
assert_exit "create: exit" 0
assert_stdout_exact "create: prints the path" "$WT12"
assert_true "create: branch exists" git -C "$REPO" rev-parse --verify --quiet refs/heads/fleet/12-add-subtract
assert_eq "create: worktree is on the branch" "$(git -C "$WT12" symbolic-ref --short HEAD 2>/dev/null)" "fleet/12-add-subtract"
assert_eq "create: branched from origin/main" "$(git -C "$WT12" rev-parse HEAD 2>/dev/null)" "$SHA_B"
assert_true "create: git worktree list shows it" wt_listed "$WT12"
assert_eq "create: setup ran once" "$(line_count "$WT12/.setup-ran")" 1

# A second create does not re-run setup and prints the same path
run_wt create 12 fleet/12-add-subtract "$WT12"
assert_exit "create-again: exit" 0
assert_stdout_exact "create-again: same path" "$WT12"
assert_eq "create-again: setup not re-run" "$(line_count "$WT12/.setup-ran")" 1

# An existing remote branch is tracked
WT13="$BASE/13-existing"
run_wt create 13 fleet/13-existing "$WT13"
assert_exit "create-tracks-remote: exit" 0
assert_stdout_exact "create-tracks-remote: path" "$WT13"
assert_eq "create-tracks-remote: at the remote branch head" "$(git -C "$WT13" rev-parse HEAD 2>/dev/null)" "$SHA_E"
assert_eq "create-tracks-remote: upstream" \
  "$(git -C "$WT13" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" "origin/fleet/13-existing"
assert_eq "create-tracks-remote: setup ran" "$(line_count "$WT13/.setup-ran")" 1

# create refuses a path outside the normalized base, including a sibling prefix
run_wt create 16 fleet/16-outside "${BASE}2/16-outside"
assert_exit "create-refuses-sibling-prefix: exit" 1
assert_false "create-refuses-sibling-prefix: nothing created" test -e "${BASE}2/16-outside"
assert_false "create-refuses-sibling-prefix: no branch" git -C "$REPO" rev-parse --verify --quiet refs/heads/fleet/16-outside

# create refuses an existing directory that is not a worktree on the branch
mkdir -p "$BASE/17-squat"
run_wt create 17 fleet/17-squat "$BASE/17-squat"
assert_exit "create-refuses-foreign-dir: exit" 1
assert_eq "create-refuses-foreign-dir: no stdout" "$LAST_OUT" ""

# create names the other worktree when the branch is already checked out
# elsewhere (worktrees.dir changed or the repo moved, so the note's old
# worktree reads as null and the plan gives the new default path)
OLDWT="$TMPROOT/old-base/14-moved"
git -C "$REPO" worktree add -q -b fleet/14-moved "$OLDWT" origin/main 2>/dev/null
run_wt create 14 fleet/14-moved "$BASE/14-moved"
assert_exit "create-branch-checked-out-elsewhere: exit" 1
case "$LAST_ERR" in
  *"branch fleet/14-moved is checked out at $OLDWT; remove that worktree"*"or restore worktrees.dir"*)
    pass "create-branch-checked-out-elsewhere: stderr names the other worktree" ;;
  *) fail "create-branch-checked-out-elsewhere: stderr names the other worktree" "stderr: $LAST_ERR" ;;
esac
assert_eq "create-branch-checked-out-elsewhere: no stdout" "$LAST_OUT" ""
assert_false "create-branch-checked-out-elsewhere: nothing created" test -e "$BASE/14-moved"
assert_true "create-branch-checked-out-elsewhere: old worktree untouched" wt_listed "$OLDWT"
# the same when the old directory is gone but still registered (the repo moved)
rm -rf "$OLDWT"
run_wt create 14 fleet/14-moved "$BASE/14-moved"
assert_exit "create-branch-registered-to-missing-dir: exit" 1
case "$LAST_ERR" in
  *"branch fleet/14-moved is checked out at $OLDWT; remove that worktree"*) pass "create-branch-registered-to-missing-dir: stderr names it" ;;
  *) fail "create-branch-registered-to-missing-dir: stderr names it" "stderr: $LAST_ERR" ;;
esac
assert_false "create-branch-registered-to-missing-dir: nothing created" test -e "$BASE/14-moved"
git -C "$REPO" worktree prune
# when the branch is checked out in the repository's main checkout, removing
# a worktree is the wrong advice: that checkout must switch branches
git -C "$REPO" checkout -q -b fleet/18-main-checkout origin/main 2>/dev/null
run_wt create 18 fleet/18-main-checkout "$BASE/18-main-checkout"
assert_exit "create-branch-in-main-checkout: exit" 1
case "$LAST_ERR" in
  *"branch fleet/18-main-checkout is checked out at $REPO, the repository's main checkout; switch that checkout to another branch"*)
    pass "create-branch-in-main-checkout: says to switch the main checkout" ;;
  *) fail "create-branch-in-main-checkout: says to switch the main checkout" "stderr: $LAST_ERR" ;;
esac
assert_stderr_not_contains "create-branch-in-main-checkout: no remove-worktree advice" "remove that worktree"
assert_false "create-branch-in-main-checkout: nothing created" test -e "$BASE/18-main-checkout"
assert_eq "create-branch-in-main-checkout: main checkout still on the branch" \
  "$(git -C "$REPO" symbolic-ref --short HEAD 2>/dev/null)" "fleet/18-main-checkout"
git -C "$REPO" checkout -q main

# ---------------------------------------------------------------------------
# review: a detached checkout at the PR head, with a copy
RV="$BASE/12-review"
RC="$BASE/12-review-copy"
run_wt review 12 7
assert_exit "review: exit" 0
assert_eq "review: path" "$(jqc .path)" "\"$RV\""
assert_eq "review: copy" "$(jqc .copy)" "\"$RC\""
assert_eq "review: sha is the PR head" "$(jqc .sha)" "\"$SHA_P\""
assert_eq "review: base is merge-base(origin/main, head)" "$(jqc .base)" "\"$SHA_A\""
assert_eq "review: checkout at the PR head" "$(git -C "$RV" rev-parse HEAD 2>/dev/null)" "$SHA_P"
assert_false "review: detached HEAD" git -C "$RV" symbolic-ref -q HEAD
assert_true "review: git worktree list shows it" wt_listed "$RV"
assert_eq "review: setup ran in the review worktree" "$(line_count "$RV/.setup-ran")" 1
# mutate_on_copy: a copy without .git, holding the checkout and the installed deps
assert_true "review-copy: copy dir exists" test -d "$RC"
assert_false "review-copy: no .git in the copy" test -e "$RC/.git"
assert_true "review-copy: holds the PR's files" test -f "$RC/feature.txt"
assert_eq "review-copy: setup output copied" "$(line_count "$RC/.setup-ran")" 1

# review again after the PR head moved: same worktree, new head, no second setup
git -C "$SEED" checkout -q pr7
commit_file "$SEED" feature2.txt "more" "P2"
SHA_P2="$(git -C "$SEED" rev-parse HEAD)"
git -C "$SEED" push -q -f "$ORIGIN" "pr7:refs/pull/7/head" 2>/dev/null
run_wt review 12 7
assert_exit "review-again: exit" 0
assert_eq "review-again: sha is the new head" "$(jqc .sha)" "\"$SHA_P2\""
assert_eq "review-again: checkout moved" "$(git -C "$RV" rev-parse HEAD 2>/dev/null)" "$SHA_P2"
assert_eq "review-again: setup not re-run" "$(line_count "$RV/.setup-ran")" 1
assert_true "review-again: copy refreshed" test -f "$RC/feature2.txt"

# ---------------------------------------------------------------------------
# remove refuses paths outside the normalized base, before removing anything
mkdir -p "${BASE}2/x"
printf 'keep\n' > "${BASE}2/x/sentinel"
run_wt remove 12 "${BASE}2/x"
assert_exit "remove-refuses-sibling-prefix: exit" 1
assert_true "remove-refuses-sibling-prefix: sibling untouched" test -f "${BASE}2/x/sentinel"
assert_true "remove-refuses-sibling-prefix: card worktree untouched" test -d "$WT12"
assert_true "remove-refuses-sibling-prefix: review untouched" test -d "$RV"
assert_true "remove-refuses-sibling-prefix: copy untouched" test -d "$RC"

run_wt remove 12 "$BASE/../outside"
assert_exit "remove-refuses-dotdot: exit" 1
run_wt remove 12 "relative/12-x"
assert_exit "remove-refuses-relative: exit" 1
run_wt remove 12 "$BASE"
assert_exit "remove-refuses-the-base-itself: exit" 1
assert_true "remove-refuses-the-base-itself: base untouched" test -d "$WT12"

mkdir -p "$TMPROOT/elsewhere"
printf 'keep\n' > "$TMPROOT/elsewhere/sentinel"
ln -s "$TMPROOT/elsewhere" "$BASE/12-link"
run_wt remove 12 "$BASE/12-link"
assert_exit "remove-refuses-symlink-out: exit" 1
assert_true "remove-refuses-symlink-out: target untouched" test -f "$TMPROOT/elsewhere/sentinel"
rm -f "$BASE/12-link"

# remove <n> <path> only takes the card's own <base>/<n>-* directory
run_wt remove 12 "$WT13"
assert_exit "remove-refuses-other-card: exit" 1
assert_true "remove-refuses-other-card: #13 worktree untouched" wt_listed "$WT13"
assert_true "remove-refuses-other-card: #12 worktree untouched" test -d "$WT12"
assert_true "remove-refuses-other-card: #12 review untouched" test -d "$RV"
run_wt remove 1 "$WT12"
assert_exit "remove-refuses-number-prefix (1 vs 12-): exit" 1
assert_true "remove-refuses-number-prefix: #12 worktree untouched" wt_listed "$WT12"
git -C "$REPO" worktree add -q --detach "$BASE/main-check" 2>/dev/null
run_wt remove 12 "$BASE/main-check"
assert_exit "remove-refuses-main-check: exit" 1
assert_true "remove-refuses-main-check: untouched" wt_listed "$BASE/main-check"
git -C "$REPO" worktree remove --force "$BASE/main-check"
# a real worktree nested one level down, so that only the check refuses it
git -C "$REPO" worktree add -q --detach "$WT12/12-nested" 2>/dev/null
run_wt remove 12 "$WT12/12-nested"
assert_exit "remove-refuses-nested (not directly under the base): exit" 1
assert_true "remove-refuses-nested: untouched" wt_listed "$WT12/12-nested"
git -C "$REPO" worktree remove --force "$WT12/12-nested"
ln -s "$WT13" "$BASE/12-alias"
run_wt remove 12 "$BASE/12-alias"
assert_exit "remove-refuses-alias-to-other-card: exit" 1
assert_true "remove-refuses-alias-to-other-card: #13 untouched" wt_listed "$WT13"
rm -f "$BASE/12-alias"

# The path as given must itself be <base>/<n>-*: an alias of the card's own
# worktree one level down resolves to <base>/12-*, but its given parent is not
# the base
mkdir -p "$BASE/foo"
ln -s "$WT12" "$BASE/foo/12-x"
run_wt remove 12 "$BASE/foo/12-x"
assert_exit "remove-refuses-nested-alias-to-own (given parent is not the base): exit" 1
assert_true "remove-refuses-nested-alias-to-own: #12 worktree untouched" wt_listed "$WT12"
assert_true "remove-refuses-nested-alias-to-own: #12 review untouched" wt_listed "$RV"
rm -f "$BASE/foo/12-x"
rmdir "$BASE/foo"
# Another card's name as given, resolving to this card's worktree
ln -s "$WT12" "$BASE/13-x"
run_wt remove 12 "$BASE/13-x"
assert_exit "remove-refuses-other-card-name (13-x -> #12's worktree): exit" 1
assert_true "remove-refuses-other-card-name: #12 worktree untouched" wt_listed "$WT12"
assert_true "remove-refuses-other-card-name: #12 review untouched" wt_listed "$RV"
rm -f "$BASE/13-x"

# remove deletes all three paths; the branch survives
run_wt remove 12 "$WT12"
assert_exit "remove: exit" 0
assert_false "remove: card worktree gone" test -e "$WT12"
assert_false "remove: review worktree gone" test -e "$RV"
assert_false "remove: copy gone" test -e "$RC"
assert_false "remove: worktree list no longer shows the card worktree" wt_listed "$WT12"
assert_false "remove: worktree list no longer shows the review worktree" wt_listed "$RV"
assert_true "remove: branch still exists" git -C "$REPO" rev-parse --verify --quiet refs/heads/fleet/12-add-subtract
assert_true "remove: other card untouched" test -d "$WT13"

# Missing paths are fine; the literal null means omitted
run_wt remove 12 "$WT12"
assert_exit "remove-missing: exit" 0
run_wt remove 12 null
assert_exit "remove-null: exit" 0
run_wt remove 12 ""
assert_exit "remove-empty: exit" 0

# With the path omitted, every <n>-* directory goes, but not another card's
mkdir -p "$BASE/130-other"
printf 'keep\n' > "$BASE/130-other/sentinel"
run_wt remove 13
assert_exit "remove-omitted-path: exit" 0
assert_false "remove-omitted-path: card worktree gone" test -e "$WT13"
assert_false "remove-omitted-path: worktree list no longer shows it" wt_listed "$WT13"
assert_true "remove-omitted-path: branch still exists" git -C "$REPO" rev-parse --verify --quiet refs/heads/fleet/13-existing
assert_true "remove-omitted-path: card 130 untouched" test -f "$BASE/130-other/sentinel"

# ---------------------------------------------------------------------------
# create when worktrees.setup fails: the worktree goes; a branch this call made
# from origin/HEAD goes too, so the retry starts from the current origin base;
# a pre-existing local branch, or one tracking origin/<branch>, is kept
setup_case false
printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\n  setup: "test -f ok"\n  mutate_on_copy: false\n' \
  > "$REPO/.fleet-board.yml"

WT20="$BASE/20-setup-fails"
run_wt create 20 fleet/20-setup-fails "$WT20"
assert_exit "create-setup-fails: exit" 1
assert_stdout_exact "create-setup-fails: no stdout" ""
assert_false "create-setup-fails: worktree dir gone" test -e "$WT20"
assert_false "create-setup-fails: worktree not listed" wt_listed "$WT20"
assert_false "create-setup-fails: new branch deleted" git -C "$REPO" show-ref --verify --quiet refs/heads/fleet/20-setup-fails
case "$LAST_ERR" in
  *"the new branch was deleted"*) pass "create-setup-fails: stderr says the new branch was deleted" ;;
  *) fail "create-setup-fails: stderr says the new branch was deleted" "stderr: $LAST_ERR" ;;
esac

# A pre-existing local branch is kept at its own commit
SHA_L="$(git -C "$REPO" commit-tree "$SHA_B^{tree}" -p "$SHA_B" -m L)"
git -C "$REPO" branch fleet/21-local "$SHA_L"
WT21="$BASE/21-local"
run_wt create 21 fleet/21-local "$WT21"
assert_exit "create-setup-fails-local-branch: exit" 1
assert_false "create-setup-fails-local-branch: worktree dir gone" test -e "$WT21"
assert_eq "create-setup-fails-local-branch: branch kept at its commit" \
  "$(git -C "$REPO" rev-parse --verify --quiet refs/heads/fleet/21-local)" "$SHA_L"
assert_stderr_not_contains "create-setup-fails-local-branch: no branch deletion reported" "branch was deleted"

# A branch just created tracking origin/<branch> is kept
WT13F="$BASE/13-existing"
run_wt create 13 fleet/13-existing "$WT13F"
assert_exit "create-setup-fails-tracking: exit" 1
assert_false "create-setup-fails-tracking: worktree dir gone" test -e "$WT13F"
assert_eq "create-setup-fails-tracking: branch kept at the remote head" \
  "$(git -C "$REPO" rev-parse --verify --quiet refs/heads/fleet/13-existing)" "$SHA_E"
assert_stderr_not_contains "create-setup-fails-tracking: no branch deletion reported" "branch was deleted"

# The fix lands on origin main; the retry picks it up
commit_file "$SEED" ok "ok" "FIX"
SHA_FIX="$(git -C "$SEED" rev-parse HEAD)"
git -C "$SEED" push -q "$ORIGIN" main 2>/dev/null
run_wt create 20 fleet/20-setup-fails "$WT20"
assert_exit "create-setup-fails-retry: exit" 0
assert_stdout_exact "create-setup-fails-retry: prints the path" "$WT20"
assert_eq "create-setup-fails-retry: at the fixed origin main" "$(git -C "$WT20" rev-parse HEAD 2>/dev/null)" "$SHA_FIX"
assert_eq "create-setup-fails-retry: on the branch" "$(git -C "$WT20" symbolic-ref --short HEAD 2>/dev/null)" "fleet/20-setup-fails"

# ---------------------------------------------------------------------------
# mutate_on_copy false: no copy
setup_case false
run_wt review 12 7
assert_exit "review-no-copy: exit" 0
assert_eq "review-no-copy: copy null" "$(jqc .copy)" "null"
assert_false "review-no-copy: no copy dir" test -e "$BASE/12-review-copy"
assert_eq "review-no-copy: setup ran" "$(line_count "$BASE/12-review/.setup-ran")" 1
run_wt remove 12
assert_exit "review-no-copy: remove exit" 0
assert_false "review-no-copy: review worktree gone" test -e "$BASE/12-review"

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
