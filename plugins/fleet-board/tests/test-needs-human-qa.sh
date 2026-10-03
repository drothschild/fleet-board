#!/usr/bin/env bash
#
# Plain-bash tests for needs-human-qa.sh (offline, fake gh).
# No framework, no dependencies beyond POSIX tools, jq and git.
#
# Usage: bash plugins/fleet-board/tests/test-needs-human-qa.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/../scripts/needs-human-qa.sh"
FIXTURES="$SCRIPT_DIR/../fixtures/gh"

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
    *) fail "$1" "expected to find '$2' in stderr, got: '$LAST_ERR'" ;;
  esac
}

assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
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

# setup_case <human_qa_paths flow list> <issue fixture> <PR file paths, space separated> [changedFiles]
setup_case() {
  local paths="$1" issue="$2" files="$3" changed="${4:-}"
  REPO="$(mktemp -d)"
  git init -q "$REPO"
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test User"
  cat > "$REPO/.fleet-board.yml" << YML
board:
  repo: acme/toy
worktrees:
  dir: .fw
human_qa_paths: $paths
YML
  git -C "$REPO" add .fleet-board.yml
  git -C "$REPO" commit -q -m "initial"

  FAKE_GH_DIR="$(mktemp -d)"
  ROUTES="$FAKE_GH_DIR/routes.txt"
  BIN="$FAKE_GH_DIR/bin"
  mkdir -p "$BIN"
  ln -s "$SCRIPT_DIR/fake-gh.sh" "$BIN/gh"

  # The PR's files, as gh pr view --json files,changedFiles prints them
  printf '%s\n' $files | jq -R . | jq -cs --arg c "$changed" \
    '{files: map({path: .})} + (if $c == "" then {changedFiles: length} else {changedFiles: ($c | tonumber)} end)' \
    > "$FAKE_GH_DIR/files.json"

  cat > "$ROUTES" << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
api repos/acme/toy/issues/12	0	$FIXTURES/labels/$issue
api --paginate repos/acme/toy/issues/12/comments	0	$FIXTURES/labels/comments-none.json
pr view 34 --repo acme/toy --json files*	0	$FAKE_GH_DIR/files.json
ROUTESEOF

  # Reset environment between cases
  unset CDPATH FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT FLEET_BOARD_CONFIG || true
  PATH="$BIN:$ORIG_PATH"
  export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH

  cd "$REPO"
  CLEANUP_DIRS+=("$REPO")
  CLEANUP_DIRS+=("$FAKE_GH_DIR")
}

# A card whose labels include needs-human-qa, written at run time
qa_issue() {
  jq -c '.labels += [{"name":"needs-human-qa"}]' "$FIXTURES/labels/issue-12.json" > "$FAKE_GH_DIR/issue-qa.json"
  sed -i.bak "s#^api repos/acme/toy/issues/12	0	.*#api repos/acme/toy/issues/12	0	$FAKE_GH_DIR/issue-qa.json#" "$ROUTES"
  rm -f "$ROUTES.bak"
}

pr_view_calls() { grep -c 'pr view 34' "$FAKE_GH_DIR/calls.log" 2>/dev/null || true; }

echo "Test: needs-human-qa.sh"
echo ""

# AC1.3: the label is present
setup_case '[]' issue-12.json "src/engine/x.ts"
qa_issue
run_check "$SCRIPT" 12 34
assert_exit "label-present: exit" 0
assert_stdout_exact "label-present: true" "true"

# AC1.3: a path matching src/components/**
setup_case '["src/components/**"]' issue-12.json "src/calc.js src/components/Button.tsx"
run_check "$SCRIPT" 12 34
assert_exit "components-path: exit" 0
assert_stdout_exact "components-path: true" "true"
assert_eq "components-path: one files lookup" "$(pr_view_calls)" 1

# A deeper path under src/components/**
setup_case '["src/components/**"]' issue-12.json "src/components/a/b.tsx"
run_check "$SCRIPT" 12 34
assert_stdout_exact "components-nested: true" "true"

# No match
setup_case '["src/components/**"]' issue-12.json "src/engine/x.ts test/engine.test.ts"
run_check "$SCRIPT" 12 34
assert_exit "engine-path: exit" 0
assert_stdout_exact "engine-path: false" "false"

# A near miss: src/componentsX is not under src/components/
setup_case '["src/components/**"]' issue-12.json "src/componentsX/y.tsx"
run_check "$SCRIPT" 12 34
assert_stdout_exact "near-miss: false" "false"

# **/*.snap matches a root-level a.snap (the **/ prefix may match nothing)
setup_case '["**/*.snap"]' issue-12.json "a.snap"
run_check "$SCRIPT" 12 34
assert_exit "root-snap: exit" 0
assert_stdout_exact "root-snap: true" "true"

# **/*.snap matches a nested one too
setup_case '["**/*.snap"]' issue-12.json "src/__snapshots__/b.snap"
run_check "$SCRIPT" 12 34
assert_stdout_exact "nested-snap: true" "true"

# **/*.test.* matches a.test.js
setup_case '["src/ui/**", "**/*.test.*"]' issue-12.json "lib/a.js a.test.js"
run_check "$SCRIPT" 12 34
assert_stdout_exact "second-pattern-root-test: true" "true"

# No patterns and no label: false, with no files lookup needed
setup_case '[]' issue-12.json "src/components/Button.tsx"
run_check "$SCRIPT" 12 34
assert_exit "no-patterns: exit" 0
assert_stdout_exact "no-patterns: false" "false"

# gh listed fewer files than the PR changed: fail safe, human QA
setup_case '["src/components/**"]' issue-12.json "src/calc.js" 250
run_check "$SCRIPT" 12 34
assert_exit "truncated-files: exit" 0
assert_stdout_exact "truncated-files: true" "true"
assert_stderr_contains "truncated-files: warning" "warning"

# The files lookup fails: exit 1, no answer
setup_case '["src/components/**"]' issue-12.json "src/calc.js"
sed -i.bak "s#^pr view 34 .*#pr view 34 --repo acme/toy --json files*	1	-#" "$ROUTES"; rm -f "$ROUTES.bak"
run_check "$SCRIPT" 12 34
assert_exit "files-lookup-fails: exit" 1
assert_stdout_exact "files-lookup-fails: no stdout" ""

# The files lookup returns something that is not the expected JSON
setup_case '["src/components/**"]' issue-12.json "src/calc.js"
printf 'garbage\n' > "$FAKE_GH_DIR/files.json"
run_check "$SCRIPT" 12 34
assert_exit "files-garbage: exit" 1
assert_stdout_exact "files-garbage: no stdout" ""

# The card read fails: exit 1, no answer
setup_case '["src/components/**"]' issue-12.json "src/components/Button.tsx"
sed -i.bak "s#^api repos/acme/toy/issues/12	.*#api repos/acme/toy/issues/12	1	-#" "$ROUTES"; rm -f "$ROUTES.bak"
run_check "$SCRIPT" 12 34
assert_exit "card-read-fails: exit" 1
assert_stdout_exact "card-read-fails: no stdout" ""

# --labels <json>: the caller's labels are used; the card is not read
# (0 when gh was never called: calls.log does not exist then)
board_calls() { [ -f "$FAKE_GH_DIR/calls.log" ] || { echo 0; return; }; grep -c $'\tapi ' "$FAKE_GH_DIR/calls.log" || true; }
files_calls() { [ -f "$FAKE_GH_DIR/calls.log" ] || { echo 0; return; }; grep -c 'pr view 34' "$FAKE_GH_DIR/calls.log" || true; }
setup_case '[]' issue-12.json "src/engine/x.ts"
run_check "$SCRIPT" --labels '["fleet:in_review","needs-human-qa"]' 12 34
assert_exit "labels-arg-labelled: exit" 0
assert_stdout_exact "labels-arg-labelled: true" "true"
assert_eq "labels-arg-labelled: no board read" "$(board_calls)" 0
assert_eq "labels-arg-labelled: no files lookup" "$(files_calls)" 0
setup_case '["src/components/**"]' issue-12.json "src/components/Button.tsx"
qa_issue
run_check "$SCRIPT" --labels '["fleet:in_review"]' 12 34
assert_exit "labels-arg-path: exit" 0
assert_stdout_exact "labels-arg-path: true from the path (the stored label is not read)" "true"
assert_eq "labels-arg-path: no board read" "$(board_calls)" 0
assert_eq "labels-arg-path: one files lookup" "$(pr_view_calls)" 1
setup_case '["src/components/**"]' issue-12.json "src/engine/x.ts"
qa_issue
run_check "$SCRIPT" --labels '[]' 12 34
assert_stdout_exact "labels-arg-empty: false (the stored label is not read)" "false"
run_check "$SCRIPT" --labels 'not json' 12 34
assert_exit "labels-arg-invalid: exit 2" 2
run_check "$SCRIPT" --labels '[1]' 12 34
assert_exit "labels-arg-not-strings: exit 2" 2
run_check "$SCRIPT" --labels '["a"]' 12
assert_exit "labels-arg-missing-pr: exit 2" 2

# usage
setup_case '[]' issue-12.json "a"
run_check "$SCRIPT" 12
assert_exit "usage: one argument" 2
run_check "$SCRIPT" 12 "34; echo"
assert_exit "usage: non-numeric PR" 2

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
