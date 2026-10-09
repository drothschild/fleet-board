#!/usr/bin/env bash
#
# Plain-bash tests for config.sh
# No framework, no dependencies beyond POSIX tools.
#
# Usage: bash plugins/fleet-board/tests/test-config.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/../scripts/config.sh"
FIXTURES="${SCRIPT_DIR}/../fixtures/config"

unset FLEET_BOARD_CONFIG || true

PASS=0
FAIL=0
LAST_OUT=""
LAST_ERR=""
LAST_EXIT=0
CLEANUP_DIRS=()

cleanup() {
  for dir in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do
    rm -rf "$dir" 2>/dev/null || true
  done
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

assert_exit() {
  if [ "$LAST_EXIT" = "$2" ]; then pass "$1"; else fail "$1" "expected exit $2, got $LAST_EXIT"; fi
}

assert_stdout_exact() {
  if [ "$LAST_OUT" = "$2" ]; then pass "$1"; else fail "$1" "expected stdout: '$2', got: '$LAST_OUT'"; fi
}

assert_stdout_contains() {
  case "$LAST_OUT" in
    *"$2"*) pass "$1" ;;
    *) fail "$1" "expected to find '$2' in stdout" ;;
  esac
}

assert_stdout_not_contains() {
  case "$LAST_OUT" in
    *"$2"*) fail "$1" "did not expect '$2' in stdout" ;;
    *) pass "$1" ;;
  esac
}

assert_stderr_contains() {
  case "$LAST_ERR" in
    *"$2"*) pass "$1" ;;
    *) fail "$1" "expected to find '$2' in stderr: '$LAST_ERR'" ;;
  esac
}

assert_stderr_not_contains() {
  case "$LAST_ERR" in
    *"$2"*) fail "$1" "did not expect '$2' in stderr" ;;
    *) pass "$1" ;;
  esac
}

assert_stderr_exact() {
  if [ "$LAST_ERR" = "$2" ]; then pass "$1"; else fail "$1" "expected exact stderr: '$2', got: '$LAST_ERR'"; fi
}

run_config() {
  local dir="$1" key="${2:-}"
  local tmpout tmperr bash_exe
  tmpout="$(mktemp)"
  tmperr="$(mktemp)"
  # Use /bin/bash if available (bash 3.2 on macOS), fallback to bash
  bash_exe="/bin/bash"
  if [ ! -x "$bash_exe" ]; then
    bash_exe="bash"
  fi
  if [ -z "$key" ]; then
    "$bash_exe" "$SCRIPT" --dir "$dir" > "$tmpout" 2> "$tmperr"
  else
    "$bash_exe" "$SCRIPT" --dir "$dir" "$key" > "$tmpout" 2> "$tmperr"
  fi
  LAST_EXIT=$?
  LAST_OUT="$(cat "$tmpout")"
  LAST_ERR="$(cat "$tmperr")"
  rm -f "$tmpout" "$tmperr"
}

assert_key() {
  local dir="$1" key="$2" expected="$3" test_name="$4"
  run_config "$dir" "$key"
  assert_stdout_exact "$test_name" "$expected"
}

make_test_repo() {
  local fixture="$1"
  local tmpdir
  tmpdir="$(mktemp -d)"
  git init -q "$tmpdir"
  git -C "$tmpdir" config user.email "test@example.com"
  git -C "$tmpdir" config user.name "Test User"
  cp "$FIXTURES/$fixture" "$tmpdir/.fleet-board.yml"
  git -C "$tmpdir" add .fleet-board.yml
  git -C "$tmpdir" commit -q -m "initial"
  echo "$tmpdir"
}

# make_inline_repo: like make_test_repo, but the config content comes from stdin.
make_inline_repo() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  git init -q "$tmpdir"
  git -C "$tmpdir" config user.email "test@example.com"
  git -C "$tmpdir" config user.name "Test User"
  cat > "$tmpdir/.fleet-board.yml"
  git -C "$tmpdir" add .fleet-board.yml
  git -C "$tmpdir" commit -q -m "initial"
  echo "$tmpdir"
}

echo "Test: config reader with fixtures"
echo ""

# Test 1: minimal.yml defaults merge
REPO="$(make_test_repo minimal.yml)"
CLEANUP_DIRS+=("$REPO")
assert_key "$REPO" "board.backend" "github-labels" "minimal defaults backend"
assert_key "$REPO" "review.max_rounds" "3" "minimal defaults max_rounds"
assert_key "$REPO" "models.reviewer" "opus" "minimal defaults reviewer model"
run_config "$REPO"
if echo "$LAST_OUT" | jq -e . >/dev/null 2>&1; then
  pass "minimal config parses with jq"
else
  fail "minimal config parses with jq" "output is not valid JSON"
fi

# Test 2: full.yml with additions
REPO="$(make_test_repo full.yml)"
CLEANUP_DIRS+=("$REPO")
assert_key "$REPO" "board.states.human_qa" "Require Human Inteteraction" "full human_qa state"
assert_key "$REPO" "commands.test_one" "npm test -- --runTestsByPath {file}" "full test_one command"
assert_key "$REPO" "limits.max_cost_usd" "40" "full max_cost_usd"
assert_key "$REPO" "human_qa_paths" '["src/components/**"]' "full human_qa_paths"
assert_key "$REPO" "merge.policy" "human" "full merge policy (comment stripped)"
rm -rf "$REPO"

# Test 3: hmb.yml
REPO="$(make_test_repo hmb.yml)"
CLEANUP_DIRS+=("$REPO")
run_config "$REPO"
assert_exit "hmb.yml exit 0" "0"
assert_key "$REPO" "board.states.in_progress" "In progress" "hmb in_progress"
assert_key "$REPO" "board.states.wont_do" "Won't Do" "hmb wont_do preserves single quote"
rm -rf "$REPO"

# Test 4: Defaults survive partial map
REPO="$(mktemp -d)"
git init -q "$REPO"
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test User"
cat > "$REPO/.fleet-board.yml" << 'EOF'
board:
  repo: a/b
review: { max_rounds: 5 }
EOF
git -C "$REPO" add .fleet-board.yml
git -C "$REPO" commit -q -m "initial"
assert_key "$REPO" "review.max_rounds" "5" "defaults partial map max_rounds"
assert_key "$REPO" "review.mutation" "true" "defaults partial map mutation"
rm -rf "$REPO"

# Test 5: Missing file
REPO="$(mktemp -d)"
git init -q "$REPO"
run_config "$REPO"
assert_exit "missing file exit 3" "3"
assert_stderr_contains "missing file stderr names the file path" "/.fleet-board.yml"
assert_stderr_contains "missing file stderr contains path" "no .fleet-board.yml"
rm -rf "$REPO"

# Test 6: FLEET_BOARD_CONFIG env var
REPO="$(mktemp -d)"
CLEANUP_DIRS+=("$REPO")
git init -q "$REPO"
export FLEET_BOARD_CONFIG="$FIXTURES/full.yml"
run_config "$REPO"
assert_exit "FLEET_BOARD_CONFIG exit 0" "0"
run_config "$REPO" "board.repo"
assert_stdout_exact "FLEET_BOARD_CONFIG uses env var" "owner/name"
unset FLEET_BOARD_CONFIG

# Test 7: --dir with subdirectory
REPO="$(make_test_repo minimal.yml)"
CLEANUP_DIRS+=("$REPO")
SUBDIR="$REPO/sub/dir"
mkdir -p "$SUBDIR"
run_config "$SUBDIR"
assert_exit "subdir finds root" "0"
assert_key "$SUBDIR" "board.repo" "acme/toy" "subdir resolves to root config"
rm -rf "$REPO"

# Test 8: block lists (and comments after list items) are accepted
REPO="$(make_test_repo block-list.yml)"
CLEANUP_DIRS+=("$REPO")
run_config "$REPO"
assert_exit "block list exit 0" "0"
assert_key "$REPO" "human_qa_paths" '["src/**","docs/ui"]' "block list value"
assert_key "$REPO" "test_paths" '["tests/**"]' "block list replaces the default list"

# Test 9: bad-tab.yml
REPO="$(make_test_repo bad-tab.yml)"
CLEANUP_DIRS+=("$REPO")
run_config "$REPO"
assert_exit "tab exit 4" "4"
assert_stderr_contains "tab stderr names the file" ".fleet-board.yml"
rm -rf "$REPO"

# Test 10: a third (and fourth) nesting level is accepted
REPO="$(make_test_repo deep.yml)"
CLEANUP_DIRS+=("$REPO")
run_config "$REPO"
assert_exit "deep exit 0" "0"
assert_key "$REPO" "notes.a.b.c" "deep" "deep nesting value"

# Test 10b: comments, quoted strings with escapes, nested flow collections,
# anchors and aliases, and multi-line strings
REPO="$(cat <<'YAML' | make_inline_repo
# leading comment
board:
  repo: acme/toy   # trailing comment
commands:
  test_one: "node --test \"a b\"\tx"
  lint: 'it''s'
  tail: |
    line one
    line two
base: &base { k: [1, { n: 2 }] }
copy: *base
YAML
)"
CLEANUP_DIRS+=("$REPO")
run_config "$REPO"
assert_exit "rich yaml exit 0" "0"
assert_key "$REPO" "board.repo" "acme/toy" "trailing comment dropped"
assert_key "$REPO" "commands.test_one" "$(printf 'node --test "a b"\tx')" "double-quoted escapes"
assert_key "$REPO" "commands.lint" "it's" "single-quoted quote"
assert_key "$REPO" "commands.tail" "$(printf 'line one\nline two')" "multi-line string"
assert_key "$REPO" "base.k" '[1,{"n":2}]' "nested flow collection"
assert_key "$REPO" "copy.k" '[1,{"n":2}]' "alias resolved"

# Test 10c: a file that is not valid YAML, or not a map, exits 4 and names the file
REPO="$(printf 'board: [unclosed\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO")
run_config "$REPO"
assert_exit "invalid yaml exit 4" "4"
assert_stderr_contains "invalid yaml names the file" ".fleet-board.yml"
REPO="$(printf -- '- a\n- b\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO")
run_config "$REPO"
assert_exit "top-level list exit 4" "4"
assert_stderr_contains "top-level list says map" "must be a map"

# Test 10d: yq missing, or the wrong yq (the Python one), exits 4 with the install hint
REPO="$(printf 'board:\n  repo: a/b\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO")
NOYQ="$(mktemp -d)"; CLEANUP_DIRS+=("$NOYQ")
for t in jq git dirname cat mktemp rm; do ln -s "$(command -v $t)" "$NOYQ/$t"; done
OLDPATH="$PATH"; PATH="$NOYQ:/usr/bin:/bin"
run_config "$REPO"
PATH="$OLDPATH"
assert_exit "yq missing exit 4" "4"
assert_stderr_contains "yq missing names mikefarah yq" "mikefarah/yq"
printf '#!/bin/sh\necho "yq 3.4.3"\n' > "$NOYQ/yq"; chmod +x "$NOYQ/yq"
PATH="$NOYQ:/usr/bin:/bin"
run_config "$REPO"
PATH="$OLDPATH"
assert_exit "wrong yq exit 4" "4"
assert_stderr_contains "wrong yq names mikefarah yq" "mikefarah/yq"

# Test 11: bad-backend.yml
REPO="$(make_test_repo bad-backend.yml)"
CLEANUP_DIRS+=("$REPO")
run_config "$REPO"
assert_exit "bad backend exit 5" "5"
assert_stderr_contains "bad backend stderr mentions backend" "board.backend"
rm -rf "$REPO"

# Test 12: bad-projects-no-number.yml
REPO="$(make_test_repo bad-projects-no-number.yml)"
CLEANUP_DIRS+=("$REPO")
run_config "$REPO"
assert_exit "projects no number exit 5" "5"
assert_stderr_contains "projects no number mentions project_number" "project_number"
rm -rf "$REPO"

# Test 13: Invalid merge policy
REPO="$(mktemp -d)"
git init -q "$REPO"
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test User"
cat > "$REPO/.fleet-board.yml" << 'EOF'
board:
  repo: a/b
merge: { policy: yolo }
EOF
git -C "$REPO" add .fleet-board.yml
git -C "$REPO" commit -q -m "initial"
run_config "$REPO"
assert_exit "invalid merge policy exit 5" "5"
rm -rf "$REPO"

# Test 14: --check flag
REPO="$(make_test_repo minimal.yml)"
CLEANUP_DIRS+=("$REPO")
run_config "$REPO" "--check"
assert_exit "--check exit 0" "0"
assert_stdout_exact "--check produces no output" ""
rm -rf "$REPO"

# Test 15: Value with # inside quotes
REPO="$(mktemp -d)"
git init -q "$REPO"
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test User"
cat > "$REPO/.fleet-board.yml" << 'EOF'
board:
  repo: a/b
commands:
  lint: "echo a # b"
EOF
git -C "$REPO" add .fleet-board.yml
git -C "$REPO" commit -q -m "initial"
assert_key "$REPO" "commands.lint" "echo a # b" "comment inside quotes preserved"
rm -rf "$REPO"

# Test 16: Non-canonical board state key
REPO="$(mktemp -d)"
git init -q "$REPO"
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test User"
cat > "$REPO/.fleet-board.yml" << 'EOF'
board:
  repo: a/b
  states: { qa: "X" }
EOF
git -C "$REPO" add .fleet-board.yml
git -C "$REPO" commit -q -m "initial"
run_config "$REPO"
assert_exit "non-canonical state key exit 5" "5"
rm -rf "$REPO"

# Test 17: Linked worktree (main has uncommitted .fleet-board.yml)
REPO="$(mktemp -d)"
CLEANUP_DIRS+=("$REPO")
git init -q "$REPO"
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test User"
# Create an uncommitted .fleet-board.yml (not staged)
cp "$FIXTURES/minimal.yml" "$REPO/.fleet-board.yml"
# Commit a different file instead
echo "readme" > "$REPO/README"
git -C "$REPO" add README
git -C "$REPO" commit -q -m "initial"
# Create worktree from other branch
WTDIR="$(mktemp -d)"
CLEANUP_DIRS+=("$WTDIR")
if git -C "$REPO" worktree add -q "$WTDIR" -b other 2>/dev/null; then
  # Verify .fleet-board.yml is not in the worktree (never committed)
  if [ ! -f "$WTDIR/.fleet-board.yml" ]; then
    pass "linked worktree .fleet-board.yml absent"
  else
    fail "linked worktree .fleet-board.yml absent" "file exists in worktree"
  fi
  run_config "$WTDIR" "board.repo"
  assert_stdout_exact "linked worktree finds config from main" "acme/toy"
  git -C "$REPO" worktree remove --force "$WTDIR" 2>/dev/null || true
else
  fail "linked worktree creation" "git worktree add failed"
fi

# Test 18: Missing repo in board section (validation)
REPO="$(make_inline_repo <<'YML'
board:
  backend: github-labels
YML
)"
CLEANUP_DIRS+=("$REPO")
run_config "$REPO"
assert_exit "missing repo exit 5" "5"
assert_stderr_contains "missing repo stderr mentions board.repo" "board.repo"

# Test 19: Invalid max_rounds (not integer)
REPO="$(make_inline_repo <<'YML'
board:
  repo: a/b
review: { max_rounds: 2.5 }
YML
)"
CLEANUP_DIRS+=("$REPO")
run_config "$REPO"
assert_exit "non-integer max_rounds exit 5" "5"
assert_stderr_contains "non-integer max_rounds mentions max_rounds" "max_rounds"

# Test 20: FLEET_BOARD_CONFIG pointing at missing file
REPO="$(mktemp -d)"
CLEANUP_DIRS+=("$REPO")
git init -q "$REPO"
export FLEET_BOARD_CONFIG="/nonexistent/path/.fleet-board.yml"
run_config "$REPO"
assert_exit "missing FLEET_BOARD_CONFIG exit 3" "3"
assert_stderr_contains "missing FLEET_BOARD_CONFIG stderr names the path" "no .fleet-board.yml at /nonexistent/path/.fleet-board.yml"
unset FLEET_BOARD_CONFIG

# Test 21: A missing nested key prints nothing and exits 0
REPO="$(make_test_repo minimal.yml)"
CLEANUP_DIRS+=("$REPO")
run_config "$REPO" "board.states.nonexistent.nested.deep"
assert_exit "missing nested key exit 0" "0"
assert_stdout_exact "missing nested key empty stdout" ""

# Test 22: board is not an object (string instead)
REPO="$(make_inline_repo <<'YML'
board: acme
YML
)"
CLEANUP_DIRS+=("$REPO")
run_config "$REPO"
assert_exit "board string exit 5" "5"
assert_stderr_contains "board string gives specific reason" "config.sh: invalid config: board must be an object"
assert_stderr_not_contains "board string avoids generic fallback" "validation script failed"

# Test 23: board.states is not a map (string instead)
REPO="$(make_inline_repo <<'YML'
board:
  repo: a/b
  states: foo
YML
)"
CLEANUP_DIRS+=("$REPO")
run_config "$REPO"
assert_exit "board.states string exit 5" "5"
assert_stderr_contains "board.states string gives specific reason" "config.sh: invalid config: board.states must be a map"

# Test 24: KEY lookup that jq cannot evaluate (index into an array by name) exits 2
REPO="$(make_inline_repo <<'YML'
board:
  repo: a/b
YML
)"
CLEANUP_DIRS+=("$REPO")
run_config "$REPO" "test_paths.0"
assert_exit "failed key lookup exit 2" "2"
assert_stderr_contains "failed key lookup stderr" "key lookup failed"

# Test 25: every top-level section that must be a map is rejected when it is a scalar
for section in merge review models worktrees limits commands headless; do
  REPO="$(printf 'board:\n  repo: a/b\n%s: x\n' "$section" | make_inline_repo)"
  CLEANUP_DIRS+=("$REPO")
  run_config "$REPO"
  assert_exit "$section scalar exit 5" "5"
  assert_stderr_contains "$section scalar gives specific reason" "config.sh: invalid config: $section must be an object"
  assert_stderr_not_contains "$section scalar avoids generic fallback" "validation script failed"
done

# Test 26: list-valued sections are rejected when they are not lists
for section in test_paths human_qa_paths; do
  REPO="$(printf 'board:\n  repo: a/b\n%s: x\n' "$section" | make_inline_repo)"
  CLEANUP_DIRS+=("$REPO")
  run_config "$REPO"
  assert_exit "$section scalar exit 5" "5"
  assert_stderr_contains "$section scalar gives specific reason" "config.sh: invalid config: $section must be a list"
done

# Test 27: board.project_owner must be null or a string
REPO="$(printf 'board:\n  repo: a/b\n  project_owner: someone\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO")
assert_key "$REPO" "board.project_owner" "someone" "project_owner string accepted"
REPO="$(printf 'board:\n  repo: a/b\n  project_owner: 42\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO")
run_config "$REPO"
assert_exit "project_owner number exit 5" "5"
assert_stderr_contains "project_owner number reason" "config.sh: invalid config: board.project_owner must be null or a string"
REPO="$(make_test_repo minimal.yml)"
CLEANUP_DIRS+=("$REPO")
run_config "$REPO"
if printf '%s' "$LAST_OUT" | jq -e '.board | has("project_owner") and .project_owner == null' >/dev/null; then
  pass "project_owner defaults to null"
else
  fail "project_owner defaults to null" "got $(printf '%s' "$LAST_OUT" | jq -c .board)"
fi

# Test 28: cdpath-relative-script. With CDPATH exported and a same-named
# "scripts" directory in it, config.sh run by a relative path must still find
# its own directory (cd would go to the CDPATH one and echo its path).
REPO="$(make_test_repo minimal.yml)"
CDPATH_DECOY="$(mktemp -d)"
mkdir -p "$CDPATH_DECOY/scripts"
CLEANUP_DIRS+=("$REPO" "$CDPATH_DECOY")
tmpout="$(mktemp)"
tmperr="$(mktemp)"
bash_exe="/bin/bash"
[ -x "$bash_exe" ] || bash_exe="bash"
(cd "$SCRIPT_DIR/.." && export CDPATH="$CDPATH_DECOY" && "$bash_exe" scripts/config.sh --dir "$REPO" board.repo) > "$tmpout" 2> "$tmperr"
LAST_EXIT=$?
LAST_OUT="$(cat "$tmpout")"
LAST_ERR="$(cat "$tmperr")"
rm -f "$tmpout" "$tmperr"
assert_exit "cdpath-relative-script: exit" "0"
assert_stdout_exact "cdpath-relative-script: board.repo" "acme/toy"


# Test 29: field-validation. limits.concurrency is a positive integer,
# models.manager/implementor/reviewer/fixer are non-empty strings, and
# worktrees.dir is a non-empty relative path (it is joined onto the repo root,
# so an absolute one would silently land inside the repo). '..' stays allowed:
# the default ../.fleet-worktrees sits beside the repo on purpose.
invalid_field_case() { # NAME YAML_BODY EXPECTED_STDERR
  REPO="$(printf 'board:\n  repo: a/b\n%s\n' "$2" | make_inline_repo)"
  CLEANUP_DIRS+=("$REPO")
  run_config "$REPO"
  assert_exit "field-validation $1: exit 5" "5"
  assert_stderr_contains "field-validation $1: names the field" "$3"
}
invalid_field_case "concurrency 0" 'limits: { concurrency: 0 }' "limits.concurrency must be a positive integer"
invalid_field_case "concurrency 1.5" 'limits: { concurrency: 1.5 }' "limits.concurrency must be a positive integer"
invalid_field_case "concurrency string" 'limits: { concurrency: many }' "limits.concurrency must be a positive integer"
for role in manager implementor reviewer fixer; do
  invalid_field_case "models.$role empty" "models: { $role: \"\" }" "models.$role must be a non-empty string"
  invalid_field_case "models.$role number" "models: { $role: 5 }" "models.$role must be a non-empty string"
done
invalid_field_case "models.escalation empty" 'models: { escalation: "" }' "models.escalation must be null or a non-empty string"
invalid_field_case "models.escalation number" 'models: { escalation: 5 }' "models.escalation must be null or a non-empty string"
REPO="$(printf 'board:\n  repo: a/b\nmodels: { escalation: fable }\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO")
assert_key "$REPO" "models.escalation" "fable" "models.escalation set"
REPO="$(printf 'board:\n  repo: a/b\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO")
run_config "$REPO"
if printf '%s' "$LAST_OUT" | jq -e '.models | has("escalation") and .escalation == null' >/dev/null; then
  pass "models.escalation defaults to null"
else
  fail "models.escalation defaults to null" "got $(printf '%s' "$LAST_OUT" | jq -c .models)"
fi
invalid_field_case "worktrees.dir empty" 'worktrees: { dir: "" }' "worktrees.dir must be a non-empty relative path"
invalid_field_case "worktrees.dir absolute" 'worktrees: { dir: /tmp/wt }' "worktrees.dir must be a non-empty relative path"
invalid_field_case "worktrees.dir number" 'worktrees: { dir: 7 }' "worktrees.dir must be a non-empty relative path"
REPO="$(printf 'board:\n  repo: a/b\nlimits: { concurrency: 2 }\nmodels: { reviewer: claude-opus-5-5 }\nworktrees: { dir: ../wt }\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO")
run_config "$REPO"
assert_exit "field-validation valid values: exit 0" "0"
assert_key "$REPO" "worktrees.dir" "../wt" "field-validation valid values: relative dir with .. kept"

echo ""
echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
