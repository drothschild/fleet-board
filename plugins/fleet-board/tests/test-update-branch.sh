#!/usr/bin/env bash
#
# Plain-bash tests for update-branch.sh (offline: fake gh, stubbed git).
# The stub git logs every call made against the card's worktree to $GIT_LOG and
# answers from environment variables; any other git call goes to the real git.
#
# Usage: bash plugins/fleet-board/tests/test-update-branch.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/../scripts/update-branch.sh"
TICK="$SCRIPT_DIR/../fixtures/gh/tick"
REAL_GIT="$(command -v git)"

unset FLEET_BOARD_CONFIG FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT || true

PASS=0
FAIL=0
LAST_OUT=""
LAST_ERR=""
LAST_EXIT=0
CLEANUP_DIRS=()
ORIG_PATH="$PATH"

cleanup() {
  for dir in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do rm -rf "$dir" 2>/dev/null || true; done
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi; }
assert_exit() { assert_eq "$1" "$LAST_EXIT" "$2"; }

# Number of lines of a file matching an extended regex
count_lines() { if [ -f "$2" ]; then grep -Ec -- "$1" "$2" || true; else echo 0; fi; }

# setup <changed-files> <conflicted-files> <merge-rc>
# Builds a repo, a fake gh with a note on card 12 and a stub git.
setup() {
  REPO="$(mktemp -d)"
  "$REAL_GIT" init -q "$REPO"
  "$REAL_GIT" -C "$REPO" config user.email "test@example.com"
  "$REAL_GIT" -C "$REPO" config user.name "Test User"
  printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\n' > "$REPO/.fleet-board.yml"
  "$REAL_GIT" -C "$REPO" add .fleet-board.yml
  "$REAL_GIT" -C "$REPO" commit -q -m initial

  FAKE_GH_DIR="$(mktemp -d)"
  CLEANUP_DIRS+=("$REPO" "$FAKE_GH_DIR")
  BIN="$FAKE_GH_DIR/bin"
  mkdir -p "$BIN" "$FAKE_GH_DIR/routes.d"
  ln -s "$SCRIPT_DIR/fake-gh.sh" "$BIN/gh"

  WT="$REPO/.fw/12-add-subtract"
  mkdir -p "$WT"
  GIT_LOG="$FAKE_GH_DIR/git.log"
  : > "$GIT_LOG"
  cat > "$BIN/git" <<'STUB'
#!/usr/bin/env bash
# stub git: calls against $STUB_WT are logged and answered from the environment
if [ "${1:-}" = "-C" ] && [ "${2:-}" = "$STUB_WT" ]; then
  shift 2
  printf '%s\n' "$*" >> "$GIT_LOG"
  case "$1" in
    fetch) exit 0 ;;
    rev-parse)
      if [ -f "$STUB_STATE/merged" ]; then echo "$STUB_AFTER"; else echo "$STUB_BEFORE"; fi
      exit 0 ;;
    merge)
      if [ "${2:-}" = "--abort" ]; then exit 0; fi
      touch "$STUB_STATE/merged"
      exit "$STUB_MERGE_RC" ;;
    diff)
      case "$*" in
        *--diff-filter=U*) [ -n "$STUB_CONFLICTS" ] && printf '%s\n' $STUB_CONFLICTS; exit 0 ;;
        *) [ -n "$STUB_CHANGED" ] && printf '%s\n' $STUB_CHANGED; exit 0 ;;
      esac ;;
    push) exit 0 ;;
    *) exit 0 ;;
  esac
fi
exec "$REAL_GIT" "$@"
STUB
  chmod +x "$BIN/git"

  printf 'main\n' > "$FAKE_GH_DIR/routes.d/base.txt"
  cat > "$FAKE_GH_DIR/routes" <<ROUTES
api user	0	$TICK/../labels/user.json
api repos/acme/toy/issues/12	0	$TICK/common/issue-12-in_review.json
api --paginate repos/acme/toy/issues/12/comments	0	$TICK/in-review-fix/comments-12.json
api -X PATCH repos/acme/toy/issues/comments/555 --input -	0	-
pr view 34 --repo acme/toy --json baseRefName *	0	$FAKE_GH_DIR/routes.d/base.txt
issue edit 12 *	0	-
issue comment 12 *	0	-
ROUTES

  unset CDPATH FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT FLEET_BOARD_CONFIG || true
  PATH="$BIN:$ORIG_PATH"
  FAKE_GH_ROUTES="$FAKE_GH_DIR/routes"
  STUB_WT="$WT"; STUB_STATE="$FAKE_GH_DIR/state"; mkdir -p "$STUB_STATE"
  STUB_BEFORE="1111111111111111111111111111111111111111"
  STUB_AFTER="2222222222222222222222222222222222222222"
  STUB_CHANGED="$1"; STUB_CONFLICTS="$2"; STUB_MERGE_RC="$3"
  export FAKE_GH_DIR FAKE_GH_ROUTES PATH STUB_WT STUB_STATE STUB_BEFORE STUB_AFTER \
    STUB_CHANGED STUB_CONFLICTS STUB_MERGE_RC GIT_LOG REAL_GIT
  cd "$REPO"
}

run_update() {
  local out err
  out="$(mktemp)"; err="$(mktemp)"
  bash "$SCRIPT" 12 34 fleet/12-add-subtract "$WT" > "$out" 2> "$err"
  LAST_EXIT=$?
  LAST_OUT="$(cat "$out")"; LAST_ERR="$(cat "$err")"
  rm -f "$out" "$err"
}

# The note JSON written by the call, from the PATCH body (last input saved)
written_note() {
  local f last=""
  for f in "$FAKE_GH_DIR"/inputs/*; do [ -f "$f" ] && last="$f"; done
  [ -n "$last" ] || { echo '{}'; return; }
  jq -r '.body' "$last" | sed -n '/^```json$/,/^```$/p' | sed '1d;$d'
}

gh_calls() { count_lines "$1" "$FAKE_GH_DIR/calls.log"; }

# ---------------------------------------------------------------------------
# A clean merge: merges the base in, pushes plainly, moves nothing, no comment
setup "" "" 0
run_update
assert_exit "clean merge: exit 0" 0
assert_eq "clean merge: merges origin/main into the branch" "$(count_lines '^merge .*origin/main' "$GIT_LOG")" 1
assert_eq "clean merge: pushes the branch" "$(count_lines '^push .*fleet/12-add-subtract' "$GIT_LOG")" 1
assert_eq "clean merge: git log has no rebase" "$(count_lines 'rebase' "$GIT_LOG")" 0
assert_eq "clean merge: git log has no --force" "$(count_lines '--force' "$GIT_LOG")" 0
assert_eq "clean merge: git log has no --force-with-lease" "$(count_lines '--force-with-lease' "$GIT_LOG")" 0
assert_eq "clean merge: no label change" "$(gh_calls 'issue edit')" 0
assert_eq "clean merge: no comment" "$(gh_calls 'issue comment')" 0
assert_eq "clean merge: the note records the update" "$(written_note | jq -c '.last_update.sha')" '"2222222222222222222222222222222222222222"'
assert_eq "clean merge: the reviewed sha is kept" "$(written_note | jq -c '.last_review.sha')" '"abc1234"'
assert_eq "clean merge: state unchanged in the note" "$(written_note | jq -c '.state')" '"in_review"'

# A merge that changed files: the reviewed-sha baseline is dropped
setup "src/calc.js" "" 0
run_update
assert_exit "changed merge: exit 0" 0
assert_eq "changed merge: last_review cleared so the next tick reviews" "$(written_note | jq -c '.last_review')" 'null'
assert_eq "changed merge: the note records changed code" "$(written_note | jq -c '.last_update.changed')" 'true'
assert_eq "changed merge: still pushed" "$(count_lines '^push ' "$GIT_LOG")" 1

# A merge that needs a manual resolution: aborted, card blocked, files named
setup "" "src/calc.js src/util.js" 1
run_update
assert_exit "conflict: exit 0" 0
assert_eq "conflict: the merge is aborted" "$(count_lines '^merge --abort' "$GIT_LOG")" 1
assert_eq "conflict: nothing is pushed" "$(count_lines '^push ' "$GIT_LOG")" 0
assert_eq "conflict: git log has no rebase" "$(count_lines 'rebase' "$GIT_LOG")" 0
assert_eq "conflict: card moved to blocked" "$(gh_calls 'issue edit 12 --repo acme/toy --add-label fleet:blocked')" 1
assert_eq "conflict: one comment" "$(gh_calls 'issue comment 12')" 1
BODY_FILE="$(ls "$FAKE_GH_DIR"/bodies/* 2>/dev/null | head -1)"
assert_eq "conflict: comment names src/calc.js" "$(count_lines 'src/calc.js' "$BODY_FILE")" 1
assert_eq "conflict: comment names src/util.js" "$(count_lines 'src/util.js' "$BODY_FILE")" 1

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
