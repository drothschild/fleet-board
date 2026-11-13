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
  printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\n%s' "${UB_YAML:-}" > "$REPO/.fleet-board.yml"
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
    symbolic-ref) echo "${STUB_HEAD_BRANCH:-fleet/12-add-subtract}"; exit 0 ;;
    merge-base) echo 0000000000000000000000000000000000000000; exit 0 ;;
    reset) [ "${STUB_RESET_RC:-0}" -eq 0 ] || exit "$STUB_RESET_RC"; rm -f "$STUB_STATE/merged"; exit 0 ;;
    rev-parse)
      case "$*" in
        *MERGE_HEAD*) exit 1 ;;
        *origin/*) # the remote-tracking branch: what the last successful push left
          if [ -f "$STUB_STATE/pushed" ]; then echo "$STUB_AFTER"; else echo "${STUB_REMOTE:-$STUB_BEFORE}"; fi
          exit 0 ;;
      esac
      if [ -f "$STUB_STATE/merged" ]; then echo "$STUB_AFTER"; else echo "$STUB_BEFORE"; fi
      exit 0 ;;
    merge)
      if [ "${2:-}" = "--abort" ]; then rm -f "$STUB_STATE/merged"; exit 0; fi
      touch "$STUB_STATE/merged"
      exit "$STUB_MERGE_RC" ;;
    diff)
      case "$*" in
        *--diff-filter=U*) [ -n "$STUB_CONFLICTS" ] && printf '%s\n' $STUB_CONFLICTS; exit 0 ;;
        *) [ -n "$STUB_CHANGED" ] && printf '%s\n' $STUB_CHANGED; exit 0 ;;
      esac ;;
    push)
      [ "${STUB_PUSH_RC:-0}" -eq 0 ] || exit "$STUB_PUSH_RC"
      [ -n "${STUB_PUSH_LIES:-}" ] || touch "$STUB_STATE/pushed"
      exit 0 ;;
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

  unset CDPATH FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT FLEET_BOARD_CONFIG STUB_HEAD_BRANCH STUB_REMOTE STUB_PUSH_RC STUB_PUSH_LIES STUB_RESET_RC || true
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
VF_YAML='supervisor:
  version_files: [".claude-plugin/marketplace.json", "plugins/**/plugin.json", "notes.txt", "*.json"]
'
UB_YAML="$VF_YAML"
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

# The comment and the error say why a version-only resolution was refused
comment_body() { cat "$(ls "$FAKE_GH_DIR"/bodies/* 2>/dev/null | head -1)" 2>/dev/null; }
assert_why() { # <label> <fixed text>
  assert_eq "$1: the comment says why" "$(comment_body | grep -cF -- "$2")" 1
  assert_eq "$1: the error says why" "$(printf '%s\n' "$LAST_ERR" | grep -cF -- "$2")" 1
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
assert_resolved "branch 0.29.0-rc.2 against base 0.29.0-rc.10 (numeric prerelease; the base core is above it)" 0.29.0 "$PLUGIN_JSON"

# A hunk that also changes another line goes to the fixer as today
setup "" "$PLUGIN_JSON" 1
mkdir -p "$(dirname "$WT/$PLUGIN_JSON")"
printf '{\n  "name": "fleet-board",\n<<<<<<< HEAD\n  "version": "0.28.3",\n  "description": "mine"\n=======\n  "version": "0.28.4",\n  "description": "theirs"\n>>>>>>> origin/main\n}\n' > "$WT/$PLUGIN_JSON"
run_update
assert_to_fixer "a JSON conflict that also touches another line" "$PLUGIN_JSON"

# A hunk whose sides also share an identical non-version line: not version-only
setup "" "$PLUGIN_JSON" 1
mkdir -p "$(dirname "$WT/$PLUGIN_JSON")"
printf '{\n  "name": "fleet-board",\n<<<<<<< HEAD\n  "version": "0.28.3",\n  "main": "a.js",\n=======\n  "version": "0.28.4",\n  "main": "a.js",\n>>>>>>> origin/main\n  "description": "x"\n}\n' > "$WT/$PLUGIN_JSON"
run_update
assert_to_fixer "a hunk with an identical non-version line on both sides" "$PLUGIN_JSON"
assert_why "a hunk with an identical non-version line on both sides" "changes lines other than"

# One side drops the version line: not version-only
setup "" "$PLUGIN_JSON" 1
mkdir -p "$(dirname "$WT/$PLUGIN_JSON")"
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


# C1: each conflicted version line is resolved from its own two sides
two_plugin_market() { # <file> <a ours> <a theirs> <b ours> <b theirs>
  mkdir -p "$(dirname "$WT/$1")"
  printf '{\n  "name": "m",\n  "plugins": [\n    {\n      "name": "a",\n<<<<<<< HEAD\n      "version": "%s"\n=======\n      "version": "%s"\n>>>>>>> origin/main\n    },\n    {\n      "name": "b",\n<<<<<<< HEAD\n      "version": "%s"\n=======\n      "version": "%s"\n>>>>>>> origin/main\n    }\n  ]\n}\n' \
    "$2" "$3" "$4" "$5" > "$WT/$1"
}
PA="plugins/a/.claude-plugin/plugin.json"; PB="plugins/b/.claude-plugin/plugin.json"
setup "" "$MARKET_JSON $PA $PB" 1
two_plugin_market "$MARKET_JSON" 0.3.0 0.2.0 1.0.1 1.1.0
plugin_conflict "$PA" 0.3.0 0.2.0
plugin_conflict "$PB" 1.0.1 1.1.0
run_update
assert_exit "two plugins: exit 0" 0
assert_eq "two plugins: plugin a keeps its own higher branch version" "$(jq -r .version "$WT/$PA")" 0.3.0
assert_eq "two plugins: plugin b goes one patch above its own base" "$(jq -r .version "$WT/$PB")" 1.1.1
assert_eq "two plugins: marketplace a" "$(jq -r '.plugins[0].version' "$WT/$MARKET_JSON")" 0.3.0
assert_eq "two plugins: marketplace b" "$(jq -r '.plugins[1].version' "$WT/$MARKET_JSON")" 1.1.1
assert_eq "two plugins: plugin a equals its marketplace entry" "$(jq -r .version "$WT/$PA")" "$(jq -r '.plugins[0].version' "$WT/$MARKET_JSON")"
assert_eq "two plugins: plugin b equals its marketplace entry" "$(jq -r .version "$WT/$PB")" "$(jq -r '.plugins[1].version' "$WT/$MARKET_JSON")"
setup "" "$MARKET_JSON $PA" 1
two_plugin_market "$MARKET_JSON" 0.1.1 0.2.0 1.0.0 1.0.0
plugin_conflict "$PA" 0.1.1 0.2.0
run_update
assert_eq "one plugin of two: a is base + 1 patch" "$(jq -r '.plugins[0].version' "$WT/$MARKET_JSON")" 0.2.1
assert_eq "one plugin of two: b is not lifted by a" "$(jq -r '.plugins[1].version' "$WT/$MARKET_JSON")" 1.0.1
assert_eq "one plugin of two: plugin a equals its marketplace entry" "$(jq -r .version "$WT/$PA")" 0.2.1

# I3: resolution is opt-in
UB_YAML=""
setup "" "$PLUGIN_JSON" 1
plugin_conflict "$PLUGIN_JSON" 0.28.3 0.28.4
run_update
assert_to_fixer "version_files unset: a version-only conflict goes to the fixer" "$PLUGIN_JSON"
UB_YAML="$VF_YAML"
setup "" "other/x.json" 1
plugin_conflict "other/x.json" 0.28.3 0.28.4
run_update
assert_to_fixer "a version-only file outside version_files goes to the fixer" "other/x.json"
assert_why "a version-only file outside version_files" "other/x.json does not match supervisor.version_files"

# M1: diff3 hunks resolve; formatting differences, symlinks and invalid JSON are refused
setup "" "$PLUGIN_JSON" 1
mkdir -p "$(dirname "$WT/$PLUGIN_JSON")"
printf '{\n  "name": "fleet-board",\n<<<<<<< HEAD\n  "version": "0.28.3",\n||||||| merged common ancestors\n  "version": "0.28.2",\n=======\n  "version": "0.28.4",\n>>>>>>> origin/main\n  "description": "x"\n}\n' > "$WT/$PLUGIN_JSON"
run_update
assert_resolved "a diff3 hunk" 0.28.5 "$PLUGIN_JSON"

setup "" "$PLUGIN_JSON" 1
mkdir -p "$(dirname "$WT/$PLUGIN_JSON")"
printf '{\n  "name": "fleet-board",\n<<<<<<< HEAD\n  "version": "0.28.3",\n||||||| base\n  "description": "old",\n=======\n  "version": "0.28.4",\n>>>>>>> origin/main\n  "description": "x"\n}\n' > "$WT/$PLUGIN_JSON"
run_update
assert_to_fixer "a diff3 base section with a non-version line" "$PLUGIN_JSON"

setup "" "$PLUGIN_JSON" 1
mkdir -p "$(dirname "$WT/$PLUGIN_JSON")"
printf '{\n  "name": "fleet-board",\n<<<<<<< HEAD\n  "version": "0.28.3"\n=======\n  "version": "0.28.4",\n>>>>>>> origin/main\n  "description": "x"\n}\n' > "$WT/$PLUGIN_JSON"
run_update
assert_to_fixer "a hunk differing by a trailing comma" "$PLUGIN_JSON"
assert_why "a hunk differing by a trailing comma" "differ in more than the version value"

setup "" "$PLUGIN_JSON" 1
mkdir -p "$(dirname "$WT/$PLUGIN_JSON")"
printf '{\n  "name": "fleet-board",\n<<<<<<< HEAD\n  "version": "0.28.3",\n=======\n    "version": "0.28.4",\n>>>>>>> origin/main\n  "description": "x"\n}\n' > "$WT/$PLUGIN_JSON"
run_update
assert_to_fixer "a hunk differing by indentation" "$PLUGIN_JSON"

setup "" "link.json" 1
plugin_conflict "real/target.json" 0.28.3 0.28.4
ln -s real/target.json "$WT/link.json"
run_update
assert_to_fixer "a symlinked JSON file" "link.json"
assert_why "a symlinked JSON file" "link.json is a symlink"

setup "" "bad.json" 1
printf '{\n  // a comment makes this not JSON\n<<<<<<< HEAD\n  "version": "0.28.3",\n=======\n  "version": "0.28.4",\n>>>>>>> origin/main\n  "description": "x"\n}\n' > "$WT/bad.json"
run_update
assert_to_fixer "a file that is not valid JSON once resolved" "bad.json"
assert_why "a file that is not valid JSON once resolved" "bad.json is not valid JSON after resolution"

setup "" "notes.txt" 1
printf '<<<<<<< HEAD\n  "version": "0.28.3",\n=======\n  "version": "0.28.4",\n>>>>>>> origin/main\n' > "$WT/notes.txt"
run_update
assert_why "a non-JSON file in version_files" "notes.txt is not a JSON file"

setup "" "$PLUGIN_JSON" 1
plugin_conflict "$PLUGIN_JSON" 0.28.3 latest
run_update
assert_why "an unparsable version" "not semver"

# I1: the branch must be checked out; pushes are verified; a rejected push leaves nothing behind
setup "" "" 0
STUB_HEAD_BRANCH=main; export STUB_HEAD_BRANCH
run_update
assert_exit "another branch checked out: exit 1" 1
assert_eq "another branch checked out: no merge" "$(count_lines '^merge' "$GIT_LOG")" 0
assert_eq "another branch checked out: no push" "$(count_lines '^push' "$GIT_LOG")" 0

setup "" "" 0
STUB_AFTER="$STUB_BEFORE"; STUB_REMOTE="3333333333333333333333333333333333333333"; export STUB_AFTER STUB_REMOTE
run_update
assert_exit "local branch ahead of origin with nothing new merged: exit 0" 0
assert_eq "local branch ahead of origin with nothing new merged: pushed" "$(count_lines '^push origin fleet/12-add-subtract$' "$GIT_LOG")" 1

setup "" "" 0
STUB_AFTER="$STUB_BEFORE"; STUB_REMOTE="$STUB_BEFORE"; export STUB_AFTER STUB_REMOTE
run_update
assert_exit "up to date with origin: exit 0" 0
assert_eq "up to date with origin: no push" "$(count_lines '^push' "$GIT_LOG")" 0

setup "" "" 0
STUB_PUSH_RC=1; export STUB_PUSH_RC
run_update
assert_exit "rejected push: exit 1" 1
assert_eq "rejected push: the branch is reset to where it was" "$(count_lines '^reset (-q )?--keep 1111111111111111111111111111111111111111$' "$GIT_LOG")" 1
assert_eq "rejected push: never reset --hard" "$(count_lines -- '--hard' "$GIT_LOG")" 0
assert_eq "rejected push: no last_update in the note" "$(written_note | jq -c '.last_update // null')" 'null'

setup "" "" 0
STUB_PUSH_RC=1; STUB_RESET_RC=1; export STUB_PUSH_RC STUB_RESET_RC
run_update
assert_exit "rejected push and a refused reset --keep: exit 1" 1
assert_eq "rejected push and a refused reset --keep: the error says so" \
  "$(printf '%s\n' "$LAST_ERR" | grep -c 'git reset --keep .* refused')" 1

setup "" "" 0
STUB_PUSH_LIES=1; export STUB_PUSH_LIES
run_update
assert_exit "push that did not reach origin: exit 1" 1
assert_eq "push that did not reach origin: no last_update in the note" "$(written_note | jq -c '.last_update // null')" 'null'

# ---------------------------------------------------------------------------
# M2: real git, a bare remote and a clone. gh, note.sh and board-comment.sh are stubs.
RG_SCRIPTS=""
real_scripts() { # a copy of scripts/ with note.sh and board-comment.sh logging to $RG/log
  RG_SCRIPTS="$(mktemp -d)"; CLEANUP_DIRS+=("$RG_SCRIPTS")
  cp -R "$SCRIPT_DIR/../scripts/." "$RG_SCRIPTS/"
  printf '#!/usr/bin/env bash\nprintf "note %%s %%s\\n" "$1" "$(cat "$3")" >> "$RG_LOG"\nexit "${RG_NOTE_RC:-0}"\n' > "$RG_SCRIPTS/note.sh"
  printf '#!/usr/bin/env bash\nprintf "comment %%s\\n" "$1" >> "$RG_LOG"\n' > "$RG_SCRIPTS/board-comment.sh"
  mkdir -p "$RG_SCRIPTS/.bin"
  printf '#!/usr/bin/env bash\necho main\n' > "$RG_SCRIPTS/.bin/gh"
  chmod +x "$RG_SCRIPTS/.bin/gh"
}
rg_plugin() { printf '{\n  "name": "%s",\n  "version": "%s",\n  "description": "d"\n}\n' "$2" "$3" > "$1"; }
rg_market() { printf '{\n  "name": "m",\n  "plugins": [\n    {\n      "name": "a",\n      "version": "%s"\n    },\n    {\n      "name": "b",\n      "version": "%s"\n    }\n  ]\n}\n' "$2" "$3" > "$1"; }
rg_git() { git -c user.email=t@e -c user.name=T "$@"; }
# real_setup: remote.git with main (a 0.1.0, b 1.0.0) and fleet/12-x; seed (main) and wt (the branch) clones
real_setup() {
  RG="$(mktemp -d)"; CLEANUP_DIRS+=("$RG"); RG_LOG="$RG/log"; : > "$RG_LOG"; export RG_LOG
  PATH="$ORIG_PATH"
  git init -q --bare "$RG/remote.git"
  git -C "$RG/remote.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$RG/remote.git" "$RG/seed" 2>/dev/null
  mkdir -p "$RG/seed/plugins/a/.claude-plugin" "$RG/seed/plugins/b/.claude-plugin" "$RG/seed/.claude-plugin" "$RG/seed/src"
  printf 'board:\n  repo: acme/toy\nsupervisor:\n  version_files: [".claude-plugin/marketplace.json", "plugins/*/.claude-plugin/plugin.json"]\n' > "$RG/seed/.fleet-board.yml"
  rg_plugin "$RG/seed/plugins/a/.claude-plugin/plugin.json" a 0.1.0
  rg_plugin "$RG/seed/plugins/b/.claude-plugin/plugin.json" b 1.0.0
  rg_market "$RG/seed/.claude-plugin/marketplace.json" 0.1.0 1.0.0
  echo x > "$RG/seed/src/x.txt"; echo y > "$RG/seed/src/y.txt"
  rg_git -C "$RG/seed" checkout -q -b main 2>/dev/null || true
  rg_git -C "$RG/seed" add -A; rg_git -C "$RG/seed" commit -q -m init
  rg_git -C "$RG/seed" push -q origin HEAD:main
  rg_git -C "$RG/seed" push -q origin HEAD:refs/heads/fleet/12-x
  git clone -q -b fleet/12-x "$RG/remote.git" "$RG/wt" 2>/dev/null
  git -C "$RG/wt" config user.email t@e; git -C "$RG/wt" config user.name T
}
rg_main() { # <a> <b> [src/y content]: a commit on main
  rg_plugin "$RG/seed/plugins/a/.claude-plugin/plugin.json" a "$1"
  rg_plugin "$RG/seed/plugins/b/.claude-plugin/plugin.json" b "$2"
  rg_market "$RG/seed/.claude-plugin/marketplace.json" "$1" "$2"
  [ -z "${3:-}" ] || echo "$3" > "$RG/seed/src/y.txt"
  rg_git -C "$RG/seed" commit -q -am "main $1"; rg_git -C "$RG/seed" push -q origin HEAD:main
}
rg_market_inline() { printf '{\n  "name": "m",\n  "plugins": [\n    {\n      "name": "a",\n      "version": "%s"\n    },\n    { "name": "b", "version": "%s" }\n  ]\n}\n' "$2" "$3" > "$1"; }
rg_main_other() { echo "$1" > "$RG/seed/src/y.txt"; rg_git -C "$RG/seed" commit -q -am "main other $1"; rg_git -C "$RG/seed" push -q origin HEAD:main; }
rg_branch() { # <a> <b>: a commit on the branch (also touches src/x.txt), pushed
  rg_plugin "$RG/wt/plugins/a/.claude-plugin/plugin.json" a "$1"
  rg_plugin "$RG/wt/plugins/b/.claude-plugin/plugin.json" b "$2"
  rg_market "$RG/wt/.claude-plugin/marketplace.json" "$1" "$2"
  echo "branch $1" > "$RG/wt/src/x.txt"
  git -C "$RG/wt" commit -q -am "branch $1"; git -C "$RG/wt" push -q origin fleet/12-x
}
real_run() {
  local out err
  out="$(mktemp)"; err="$(mktemp)"
  (cd "$RG/wt" && PATH="$RG_SCRIPTS/.bin:$ORIG_PATH" bash "$RG_SCRIPTS/update-branch.sh" 12 34 fleet/12-x "$RG/wt") > "$out" 2> "$err"
  LAST_EXIT=$?
  LAST_OUT="$(cat "$out")"; LAST_ERR="$(cat "$err")"; rm -f "$out" "$err"
}
rg_ver() { jq -r "$2" "$RG/wt/$1"; }
rg_local() { git -C "$RG/wt" rev-parse HEAD; }
rg_remote() { git -C "$RG/remote.git" rev-parse refs/heads/fleet/12-x; }

real_scripts

# A version-only conflict: resolved, a two-parent merge, pushed, the remote equals local
real_setup
rg_main 0.2.0 1.0.0
rg_branch 0.1.1 1.0.0
real_run
assert_exit "real git version-only: exit 0" 0
assert_eq "real git version-only: a two-parent merge" "$(git -C "$RG/wt" log -1 --format=%P | wc -w | tr -d ' ')" 2
assert_eq "real git version-only: plugin a is base + 1 patch" "$(rg_ver plugins/a/.claude-plugin/plugin.json .version)" 0.2.1
assert_eq "real git version-only: marketplace a matches" "$(rg_ver .claude-plugin/marketplace.json '.plugins[0].version')" 0.2.1
assert_eq "real git version-only: plugin b untouched" "$(rg_ver .claude-plugin/marketplace.json '.plugins[1].version')" 1.0.0
assert_eq "real git version-only: the remote equals local" "$(rg_remote)" "$(rg_local)"
assert_eq "real git version-only: a clean tree" "$(git -C "$RG/wt" status --porcelain | wc -l | tr -d ' ')" 0
assert_eq "real git version-only: no fixer comment" "$(grep -c '^comment' "$RG_LOG")" 0

# I4: identical bumps merge cleanly; the merged version equals the base and is raised
real_setup
rg_main 0.1.1 1.0.0
rg_branch 0.1.1 1.0.0
real_run
assert_exit "real git identical bump: exit 0" 0
assert_eq "real git identical bump: plugin a raised above base" "$(rg_ver plugins/a/.claude-plugin/plugin.json .version)" 0.1.2
assert_eq "real git identical bump: marketplace a raised too" "$(rg_ver .claude-plugin/marketplace.json '.plugins[0].version')" 0.1.2
assert_eq "real git identical bump: b, which the branch did not change, is untouched" "$(rg_ver .claude-plugin/marketplace.json '.plugins[1].version')" 1.0.0
assert_eq "real git identical bump: the remote equals local" "$(rg_remote)" "$(rg_local)"
assert_eq "real git identical bump: a clean tree" "$(git -C "$RG/wt" status --porcelain | wc -l | tr -d ' ')" 0

# N1: run 1 fails after the merge (the raise refuses an inline "version" key); the
# merge is undone, and run 2 fails too instead of pushing the duplicate version
real_setup
rg_market_inline "$RG/seed/.claude-plugin/marketplace.json" 0.1.0 1.0.0
rg_git -C "$RG/seed" commit -q -am inline; rg_git -C "$RG/seed" push -q origin HEAD:main
git -C "$RG/wt" pull -q --no-rebase origin main 2>/dev/null; git -C "$RG/wt" push -q origin fleet/12-x
rg_plugin "$RG/seed/plugins/a/.claude-plugin/plugin.json" a 0.1.1
rg_market_inline "$RG/seed/.claude-plugin/marketplace.json" 0.1.1 1.0.0
rg_git -C "$RG/seed" commit -q -am "main 0.1.1"; rg_git -C "$RG/seed" push -q origin HEAD:main
rg_plugin "$RG/wt/plugins/a/.claude-plugin/plugin.json" a 0.1.1
rg_market_inline "$RG/wt/.claude-plugin/marketplace.json" 0.1.1 1.0.0
echo "branch" > "$RG/wt/src/x.txt"
git -C "$RG/wt" commit -q -am "branch 0.1.1"; git -C "$RG/wt" push -q origin fleet/12-x
BEFORE_SHA="$(rg_local)"; REMOTE_SHA="$(rg_remote)"
real_run
assert_exit "real git failed raise, run 1: exit 1" 1
assert_eq "real git failed raise, run 1: the error says why" "$(printf '%s\n' "$LAST_ERR" | grep -c 'not each on a line of their own')" 1
assert_eq "real git failed raise, run 1: the merge is undone" "$(rg_local)" "$BEFORE_SHA"
assert_eq "real git failed raise, run 1: a clean tree" "$(git -C "$RG/wt" status --porcelain | wc -l | tr -d ' ')" 0
assert_eq "real git failed raise, run 1: nothing pushed" "$(rg_remote)" "$REMOTE_SHA"
real_run
assert_exit "real git failed raise, run 2: still exit 1" 1
assert_eq "real git failed raise, run 2: the duplicate version is not pushed" "$(rg_remote)" "$REMOTE_SHA"

# N1(b): the branch merged the base (with the same bump) earlier and pushed it; the
# base then moved on. The branch's own bump is still raised above the base.
real_setup
rg_branch 0.1.1 1.0.0
rg_main 0.1.1 1.0.0
git -C "$RG/wt" fetch -q origin; git -C "$RG/wt" merge -q --no-edit origin/main; git -C "$RG/wt" push -q origin fleet/12-x
rg_main_other "later"
real_run
assert_exit "real git earlier merge: exit 0" 0
assert_eq "real git earlier merge: plugin a raised above base" "$(rg_ver plugins/a/.claude-plugin/plugin.json .version)" 0.1.2
assert_eq "real git earlier merge: marketplace a raised too" "$(rg_ver .claude-plugin/marketplace.json '.plugins[0].version')" 0.1.2
assert_eq "real git earlier merge: b untouched" "$(rg_ver .claude-plugin/marketplace.json '.plugins[1].version')" 1.0.0
assert_eq "real git earlier merge: the remote equals local" "$(rg_remote)" "$(rg_local)"

# A key the branch never bumped is not raised, even though the branch edited the
# same file and a merge of the base brought the base's bump in
real_setup
long_plugin() { printf '{\n  "name": "a",\n  "version": "%s",\n  "k1": 1,\n  "k2": 2,\n  "description": "%s"\n}\n' "$2" "$3" > "$1"; }
long_plugin "$RG/seed/plugins/a/.claude-plugin/plugin.json" 0.1.0 d
rg_git -C "$RG/seed" commit -q -am long; rg_git -C "$RG/seed" push -q origin HEAD:main
git -C "$RG/wt" pull -q --no-rebase origin main 2>/dev/null; git -C "$RG/wt" push -q origin fleet/12-x
long_plugin "$RG/wt/plugins/a/.claude-plugin/plugin.json" 0.1.0 "edited on the branch"
git -C "$RG/wt" commit -q -am "branch: description only"; git -C "$RG/wt" push -q origin fleet/12-x
long_plugin "$RG/seed/plugins/a/.claude-plugin/plugin.json" 0.2.0 d
rg_market "$RG/seed/.claude-plugin/marketplace.json" 0.2.0 1.0.0
rg_git -C "$RG/seed" commit -q -am "main 0.2.0"; rg_git -C "$RG/seed" push -q origin HEAD:main
git -C "$RG/wt" fetch -q origin; git -C "$RG/wt" merge -q --no-edit origin/main; git -C "$RG/wt" push -q origin fleet/12-x
rg_main_other "later"
real_run
assert_exit "real git base bump merged in, branch never bumped: exit 0" 0
assert_eq "real git base bump merged in, branch never bumped: version left at the base's" "$(rg_ver plugins/a/.claude-plugin/plugin.json .version)" 0.2.0
assert_eq "real git base bump merged in, branch never bumped: the branch's edit kept" "$(rg_ver plugins/a/.claude-plugin/plugin.json .description)" "edited on the branch"

# A lingering local merge commit (as a failed run without the reset would leave):
# the raise still sees the branch's own bump
real_setup
rg_branch 0.1.1 1.0.0
rg_main 0.1.1 1.0.0
git -C "$RG/wt" fetch -q origin; git -C "$RG/wt" merge -q --no-edit origin/main
real_run
assert_exit "real git lingering merge: exit 0" 0
assert_eq "real git lingering merge: plugin a raised above base" "$(rg_ver plugins/a/.claude-plugin/plugin.json .version)" 0.1.2
assert_eq "real git lingering merge: the remote equals local" "$(rg_remote)" "$(rg_local)"

# G1: the fixer merged main and took main's side, hiding the branch's own bump from a
# simplified history; the head equals the base and is still raised
real_setup
rg_branch 0.1.1 1.0.0
rg_main 0.2.0 1.0.0
git -C "$RG/wt" fetch -q origin
git -C "$RG/wt" merge -q --no-edit origin/main >/dev/null 2>&1
git -C "$RG/wt" checkout -q --theirs -- plugins/a/.claude-plugin/plugin.json .claude-plugin/marketplace.json
git -C "$RG/wt" add -A; git -C "$RG/wt" commit -q --no-edit; git -C "$RG/wt" push -q origin fleet/12-x
real_run
assert_exit "real git take-theirs merge: exit 0" 0
assert_eq "real git take-theirs merge: plugin a raised above base" "$(rg_ver plugins/a/.claude-plugin/plugin.json .version)" 0.2.1
assert_eq "real git take-theirs merge: marketplace a raised too" "$(rg_ver .claude-plugin/marketplace.json '.plugins[0].version')" 0.2.1
assert_eq "real git take-theirs merge: the remote equals local" "$(rg_remote)" "$(rg_local)"

# A bump the branch reverted is not raised
real_setup
rg_branch 0.1.1 1.0.0
git -C "$RG/wt" revert --no-edit HEAD >/dev/null; git -C "$RG/wt" push -q origin fleet/12-x
rg_main_other "later"
real_run
assert_exit "real git reverted bump: exit 0" 0
assert_eq "real git reverted bump: version left at the base's" "$(rg_ver plugins/a/.claude-plugin/plugin.json .version)" 0.1.0
assert_eq "real git reverted bump: marketplace left too" "$(rg_ver .claude-plugin/marketplace.json '.plugins[0].version')" 0.1.0

# A bump cherry-picked from the base is not the branch's own: not raised
real_setup
rg_main 0.1.1 1.0.0
echo "branch work" > "$RG/wt/src/x.txt"; git -C "$RG/wt" commit -q -am "branch work"
git -C "$RG/wt" fetch -q origin; git -C "$RG/wt" cherry-pick origin/main >/dev/null; git -C "$RG/wt" push -q origin fleet/12-x
assert_eq "real git cherry-picked bump: the pick is a new commit" "$(git -C "$RG/wt" merge-base --is-ancestor origin/main HEAD && echo ancestor || echo picked)" picked
rg_main_other "later"
real_run
assert_exit "real git cherry-picked bump: exit 0" 0
assert_eq "real git cherry-picked bump: version left at the base's" "$(rg_ver plugins/a/.claude-plugin/plugin.json .version)" 0.1.1

# A version file the branch touched but removed: fail closed, nothing pushed
real_setup
git -C "$RG/wt" rm -q plugins/b/.claude-plugin/plugin.json; git -C "$RG/wt" commit -q -m "drop b"; git -C "$RG/wt" push -q origin fleet/12-x
rg_main_other "later"
REMOTE_SHA="$(rg_remote)"
real_run
assert_exit "real git missing version file: exit 1" 1
assert_eq "real git missing version file: the error names it" "$(printf '%s\n' "$LAST_ERR" | grep -c 'plugins/b/.claude-plugin/plugin.json.*missing')" 1
assert_eq "real git missing version file: nothing pushed" "$(rg_remote)" "$REMOTE_SHA"

# G2: a failure after a verified push does not rewind the branch
real_setup
rg_main 0.1.0 1.0.0 "main change"
rg_branch 0.1.1 1.0.0
RG_NOTE_RC=1; export RG_NOTE_RC
real_run
assert_exit "real git note fails after the push: exit 1" 1
assert_eq "real git note fails after the push: local stays equal to the remote" "$(rg_local)" "$(rg_remote)"
assert_eq "real git note fails after the push: the merge was pushed" "$(git -C "$RG/wt" log -1 --format=%P | wc -w | tr -d ' ')" 2
RG_NOTE_RC=0
# a later commit date: a re-made merge cannot reuse the pushed merge's hash
GIT_AUTHOR_DATE="2030-01-01T00:00:00Z" GIT_COMMITTER_DATE="2030-01-01T00:00:00Z"; export GIT_AUTHOR_DATE GIT_COMMITTER_DATE
real_run
unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE
assert_exit "real git note fails after the push: the next run succeeds" 0
assert_eq "real git note fails after the push: the next run is not rejected" "$(printf '%s\n' "$LAST_ERR" | grep -c 'rejected')" 0
assert_eq "real git note fails after the push: still equal to the remote" "$(rg_local)" "$(rg_remote)"
unset RG_NOTE_RC

# A rejected push: exit 1, the branch is reset, and the next run is not a success either
real_setup
rg_main 0.1.0 1.0.0 "main change"
rg_branch 0.1.1 1.0.0
BEFORE_SHA="$(rg_local)"; REMOTE_SHA="$(rg_remote)"
printf '#!/bin/sh\nexit 1\n' > "$RG/remote.git/hooks/pre-receive"; chmod +x "$RG/remote.git/hooks/pre-receive"
real_run
assert_exit "real git rejected push: exit 1" 1
assert_eq "real git rejected push: local is reset to where it was" "$(rg_local)" "$BEFORE_SHA"
assert_eq "real git rejected push: the remote is unchanged" "$(rg_remote)" "$REMOTE_SHA"
assert_eq "real git rejected push: no last_update recorded" "$(grep -c 'last_update' "$RG_LOG")" 0
real_run
assert_exit "real git rejected push: the next run fails too" 1
assert_eq "real git rejected push: still no last_update" "$(grep -c 'last_update' "$RG_LOG")" 0
PATH="$ORIG_PATH"

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
