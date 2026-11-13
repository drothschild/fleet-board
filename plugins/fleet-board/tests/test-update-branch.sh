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
. "$SCRIPT_DIR/store-sync.sh" # the local store, rebuilt from the routes before each run
. "$SCRIPT_DIR/store-calls.sh" # its changes, recorded as the gh issue calls they replace
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
  store_sync
  store_snap
  local out err
  out="$(mktemp)"; err="$(mktemp)"
  bash "$SCRIPT" 12 34 fleet/12-add-subtract "$WT" > "$out" 2> "$err"
  LAST_EXIT=$?
  LAST_OUT="$(cat "$out")"; LAST_ERR="$(cat "$err")"
  rm -f "$out" "$err"
  store_calls
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

# A clean merge that changed files: the reviewed-sha baseline is kept; the plan
# decides from the commits whether the merge needs a review
setup "src/calc.js" "" 0
run_update
assert_exit "changed merge: exit 0" 0
assert_eq "changed merge: last_review.sha unchanged" "$(written_note | jq -c '.last_review.sha')" '"abc1234"'
assert_eq "changed merge: the note records changed code" "$(written_note | jq -c '.last_update.changed')" 'true'
assert_eq "changed merge: still pushed" "$(count_lines '^push ' "$GIT_LOG")" 1

# A merge that conflicts: aborted, nothing pushed, the card stays where it is, and
# the note records the conflicted files so the next tick dispatches the fixer
check_conflict() { # <label> <files...>: run a conflicting merge over the files and assert the shared rules
  local label="$1"; shift
  setup "" "$*" 1
  run_update
  assert_exit "$label: exit 1 so the manager counts the failure" 1
  assert_eq "$label: the merge is aborted" "$(count_lines '^merge --abort' "$GIT_LOG")" 1
  assert_eq "$label: nothing is pushed" "$(count_lines '^push ' "$GIT_LOG")" 0
  assert_eq "$label: git log has no rebase" "$(count_lines 'rebase' "$GIT_LOG")" 0
  assert_eq "$label: the card is not moved to blocked" "$(gh_calls 'issue edit')" 0
  assert_eq "$label: the note stays in_review" "$(written_note | jq -c '.state')" '"in_review"'
  assert_eq "$label: one comment" "$(gh_calls 'issue comment 12')" 1
  local body_file f
  body_file="$(ls "$FAKE_GH_DIR"/bodies/* 2>/dev/null | head -1)"
  for f in "$@"; do
    assert_eq "$label: comment names $f" "$(count_lines "$f" "$body_file")" 1
  done
  assert_eq "$label: the script does not count the failure (the manager does, once)" \
    "$(written_note | jq -c '.action_failures // 0')" '0'
}

check_conflict "conflict in one non-test file dispatches the fixer" src/calc.js
assert_eq "conflict in one non-test file dispatches the fixer: the note records the file" \
  "$(written_note | jq -c '.conflicted_files')" '["src/calc.js"]'

check_conflict "conflict in several files dispatches the fixer" src/calc.js src/util.js src/more.js
assert_eq "conflict in several files dispatches the fixer: every file is recorded in the note" \
  "$(written_note | jq -c '.conflicted_files')" '["src/calc.js","src/util.js","src/more.js"]'

check_conflict "conflict touching a test path dispatches the fixer" src/calc.js test/calc.test.js
assert_eq "conflict touching a test path dispatches the fixer: the test file is recorded in the note" \
  "$(written_note | jq -c '.conflicted_files')" '["src/calc.js","test/calc.test.js"]'

# A clean merge records no conflicted files
setup "" "" 0
run_update
assert_eq "clean merge: the note has no conflicted files" "$(written_note | jq -c '.conflicted_files // []')" '[]'

# ---------------------------------------------------------------------------
# Version-only conflicts: every conflicted file is JSON and every hunk differs
# only in "version" values. The merge is resolved here, committed and pushed.

# plugin_conflict <file> <branch-version> <base-version>: a plugin.json-shaped conflict
plugin_conflict() {
  mkdir -p "$(dirname "$WT/$1")"
  printf '{\n  "name": "fleet-board",\n<<<<<<< HEAD\n  "version": "%s",\n=======\n  "version": "%s",\n>>>>>>> origin/main\n  "description": "x"\n}\n' \
    "$2" "$3" > "$WT/$1"
}
# market_conflict <file> <branch-version> <base-version>: a nested marketplace.json-shaped conflict
# with a second plugin whose version line does not conflict
market_conflict() {
  mkdir -p "$(dirname "$WT/$1")"
  printf '{\n  "name": "m",\n  "plugins": [\n    {\n      "name": "fleet-board",\n<<<<<<< HEAD\n      "version": "%s",\n=======\n      "version": "%s",\n>>>>>>> origin/main\n      "source": "./plugins/fleet-board"\n    },\n    { "name": "other", "version": "1.0.0" }\n  ]\n}\n' \
    "$2" "$3" > "$WT/$1"
}
PLUGIN_JSON="plugins/fleet-board/.claude-plugin/plugin.json"
MARKET_JSON=".claude-plugin/marketplace.json"

assert_resolved() { # <label> <expected-version> <files...>
  local label="$1" want="$2"; shift 2
  assert_exit "$label: exit 0" 0
  assert_eq "$label: the merge is not aborted" "$(count_lines '^merge --abort' "$GIT_LOG")" 0
  assert_eq "$label: the merge is committed" "$(count_lines '^commit ' "$GIT_LOG")" 1
  assert_eq "$label: pushed with a plain push" "$(count_lines '^push origin fleet/12-add-subtract$' "$GIT_LOG")" 1
  assert_eq "$label: git log has no rebase" "$(count_lines 'rebase' "$GIT_LOG")" 0
  assert_eq "$label: git log has no --force" "$(count_lines '--force' "$GIT_LOG")" 0
  assert_eq "$label: no comment (no fixer)" "$(gh_calls 'issue comment')" 0
  assert_eq "$label: the note has no conflicted files" "$(written_note | jq -c '.conflicted_files // []')" '[]'
  assert_eq "$label: the note records the update" "$(written_note | jq -c '.last_update.sha')" '"2222222222222222222222222222222222222222"'
  local f
  for f in "$@"; do
    assert_eq "$label: $f is staged" "$(count_lines "^add .*$f" "$GIT_LOG")" 1
    assert_eq "$label: $f has no conflict markers" "$(count_lines '^(<<<<<<<|=======|>>>>>>>)' "$WT/$f")" 0
    assert_eq "$label: $f is valid JSON" "$(jq -e . "$WT/$f" >/dev/null 2>&1 && echo yes || echo no)" yes
    assert_eq "$label: $f version" "$(jq -r '.version // .plugins[0].version' "$WT/$f")" "$want"
  done
}

assert_to_fixer() { # <label> <files...>: today's conflict path, nothing auto-committed
  local label="$1"; shift
  assert_exit "$label: exit 1" 1
  assert_eq "$label: the merge is aborted" "$(count_lines '^merge --abort' "$GIT_LOG")" 1
  assert_eq "$label: nothing is committed" "$(count_lines '^commit' "$GIT_LOG")" 0
  assert_eq "$label: nothing is staged" "$(count_lines '^add' "$GIT_LOG")" 0
  assert_eq "$label: nothing is pushed" "$(count_lines '^push ' "$GIT_LOG")" 0
  assert_eq "$label: one comment" "$(gh_calls 'issue comment 12')" 1
  assert_eq "$label: the note records the files for the fixer" "$(written_note | jq -c '.conflicted_files')" \
    "$(printf '%s\n' "$@" | jq -R . | jq -sc .)"
}

setup "" "$MARKET_JSON $PLUGIN_JSON" 1
market_conflict "$MARKET_JSON" 0.28.4 0.28.5
plugin_conflict "$PLUGIN_JSON" 0.28.4 0.28.5
run_update
assert_resolved "version-only conflict in both manifests" 0.28.6 "$MARKET_JSON" "$PLUGIN_JSON"
assert_eq "version-only conflict in both manifests: the non-conflicting version line is untouched" \
  "$(jq -r '.plugins[1].version' "$WT/$MARKET_JSON")" 1.0.0
assert_eq "version-only conflict in both manifests: the commit message says so" \
  "$(count_lines '^commit .*version' "$GIT_LOG")" 1

setup "" "$PLUGIN_JSON" 1
plugin_conflict "$PLUGIN_JSON" 0.28.3 0.28.4
run_update
assert_resolved "branch 0.28.3 against base 0.28.4" 0.28.5 "$PLUGIN_JSON"

setup "" "$PLUGIN_JSON" 1
plugin_conflict "$PLUGIN_JSON" 0.29.0 0.28.4
run_update
assert_resolved "branch 0.29.0 against base 0.28.4" 0.29.0 "$PLUGIN_JSON"

setup "" "$PLUGIN_JSON" 1
plugin_conflict "$PLUGIN_JSON" 0.28.10 0.28.9
run_update
assert_resolved "branch 0.28.10 against base 0.28.9 (numeric)" 0.28.10 "$PLUGIN_JSON"

setup "" "$PLUGIN_JSON" 1
plugin_conflict "$PLUGIN_JSON" 0.28.9 0.28.10
run_update
assert_resolved "branch 0.28.9 against base 0.28.10 (numeric)" 0.28.11 "$PLUGIN_JSON"

setup "" "$PLUGIN_JSON" 1
plugin_conflict "$PLUGIN_JSON" 0.29.0 0.29.0-rc.1
run_update
assert_resolved "branch 0.29.0 against base 0.29.0-rc.1 (release ranks above prerelease)" 0.29.0 "$PLUGIN_JSON"

setup "" "$PLUGIN_JSON" 1
plugin_conflict "$PLUGIN_JSON" 0.29.0-rc.2 0.29.0-rc.10
run_update
assert_resolved "branch 0.29.0-rc.2 against base 0.29.0-rc.10 (numeric prerelease)" 0.29.1 "$PLUGIN_JSON"

# A hunk that also changes another line goes to the fixer as today
setup "" "$PLUGIN_JSON" 1
mkdir -p "$(dirname "$WT/$PLUGIN_JSON")"
printf '{\n  "name": "fleet-board",\n<<<<<<< HEAD\n  "version": "0.28.3",\n  "description": "mine"\n=======\n  "version": "0.28.4",\n  "description": "theirs"\n>>>>>>> origin/main\n}\n' > "$WT/$PLUGIN_JSON"
run_update
assert_to_fixer "a JSON conflict that also touches another line" "$PLUGIN_JSON"

# One side drops the version line: not version-only
setup "" "$PLUGIN_JSON" 1
printf '{\n  "name": "fleet-board",\n<<<<<<< HEAD\n  "version": "0.28.3",\n=======\n>>>>>>> origin/main\n  "description": "x"\n}\n' > "$WT/$PLUGIN_JSON"
run_update
assert_to_fixer "a JSON conflict where one side drops the version line" "$PLUGIN_JSON"

# A version that is not semver goes to the fixer
setup "" "$PLUGIN_JSON" 1
plugin_conflict "$PLUGIN_JSON" 0.28.3 latest
run_update
assert_to_fixer "a version that cannot be parsed" "$PLUGIN_JSON"

# A non-JSON file with a version-shaped hunk goes to the fixer as today
setup "" "notes.txt" 1
printf '<<<<<<< HEAD\n  "version": "0.28.3",\n=======\n  "version": "0.28.4",\n>>>>>>> origin/main\n' > "$WT/notes.txt"
run_update
assert_to_fixer "a conflict in a non-JSON file" "notes.txt"

# A version-only file next to a real conflict: the fixer gets both, nothing is auto-committed
setup "" "$PLUGIN_JSON src/calc.js" 1
plugin_conflict "$PLUGIN_JSON" 0.28.3 0.28.4
mkdir -p "$WT/src"
printf '<<<<<<< HEAD\nconst a = 1;\n=======\nconst a = 2;\n>>>>>>> origin/main\n' > "$WT/src/calc.js"
run_update
assert_to_fixer "a version-only file mixed with a real conflict" "$PLUGIN_JSON" src/calc.js
assert_eq "a version-only file mixed with a real conflict: the version-only file is not rewritten" \
  "$(count_lines '^<<<<<<<' "$WT/$PLUGIN_JSON")" 1

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
