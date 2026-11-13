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
assert_key "$REPO" "limits.max_hours" "8" "full max_hours"
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

# Test 10b: comments, quoted strings with escapes, nested flow collections
# and multi-line strings
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
base: { k: [1, { n: 2 }] }
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

# Test 10d: no yq is needed. With only jq and git on PATH (and a yq that
# would fail loudly if called), config.sh still parses the file; an anchor,
# which the bundled parser does not support, exits 4 with the line number.
REPO="$(printf 'board:\n  repo: a/b\nmerge: { policy: human }\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO")
NOYQ="$(mktemp -d)"; CLEANUP_DIRS+=("$NOYQ")
for t in jq git dirname cat mktemp rm; do ln -s "$(command -v $t)" "$NOYQ/$t"; done
printf '#!/bin/sh\necho "yq must not be called" >&2; exit 99\n' > "$NOYQ/yq"; chmod +x "$NOYQ/yq"
OLDPATH="$PATH"; PATH="$NOYQ:/usr/bin:/bin"
run_config "$REPO" "merge.policy"
PATH="$OLDPATH"
assert_exit "no yq: exit 0" "0"
assert_stdout_exact "no yq: value parsed" "human"
assert_stderr_not_contains "no yq: yq never called" "yq must not be called"
REPO="$(printf 'board:\n  repo: &r a/b\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO")
run_config "$REPO"
assert_exit "anchor exit 4" "4"
assert_stderr_contains "anchor names file and line" ".fleet-board.yml: line 2: anchors, aliases and tags are not supported"

# Test 11: removed-backend-key.yml (a backend key the board no longer has)
REPO="$(make_test_repo removed-backend-key.yml)"
CLEANUP_DIRS+=("$REPO")
run_config "$REPO"
assert_exit "removed-backend-key.yml fixture: exit 5" "5"
assert_stderr_contains "removed-backend-key.yml fixture: names the removed key" "board.backend is no longer a setting"
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
  states: {}
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

# Test 23b: merging is a canonical board.states key
REPO="$(make_inline_repo <<'YML'
board:
  repo: a/b
  states: { merging: "Landing" }
YML
)"
CLEANUP_DIRS+=("$REPO")
run_config "$REPO" "board.states.merging"
assert_exit "board.states.merging exit 0" "0"
assert_stdout_exact "board.states.merging is read back" "Landing"

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
# models.implementor/reviewer/fixer/merger are non-empty strings, and
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
for role in implementor reviewer fixer merger; do
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

# review.stages: defaults fill in
REPO="$(printf 'board:\n  repo: a/b\nmodels: { reviewer: opus }\nreview: { max_rounds: 4, stages: [ { name: security, agent: "acme:sec" } ] }\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_exit "stages: minimal stage is valid" 0
assert_stdout_exact_jq() { # NAME JQ_FILTER EXPECTED (against LAST_OUT)
  local got; got="$(jq -c "$2" <<<"$LAST_OUT")"
  if [ "$got" = "$3" ]; then pass "$1"; else fail "$1" "expected: '$3', got: '$got'"; fi
}
assert_stdout_exact_jq "stages: defaults filled" '.review.stages[0]' \
  '{"name":"security","agent":"acme:sec","provider":null,"model":"opus","paths":[],"label":"needs-security-review","advisory":false,"max_rounds":4,"required_passes":1,"brief":null,"timeout":600,"max_output_tokens":16000,"max_diff_bytes":400000}'
# explicit values kept
REPO="$(printf 'board:\n  repo: a/b\nreview: { stages: [ { name: ux, agent: ux-reviewer, model: sonnet, paths: ["src/ui/**"], label: ux-pls, advisory: true, max_rounds: 1, brief: "Check copy." } ] }\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_stdout_exact_jq "stages: explicit values kept" '.review.stages[0]' \
  '{"name":"ux","agent":"ux-reviewer","provider":null,"model":"sonnet","paths":["src/ui/**"],"label":"ux-pls","advisory":true,"max_rounds":1,"required_passes":1,"brief":"Check copy.","timeout":600,"max_output_tokens":16000,"max_diff_bytes":400000}'
REPO="$(printf 'board:\n  repo: a/b\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_stdout_exact_jq "stages: with no review.stages, documentation and blast_radius are built in with default true and the shipped agents" \
  '.review.stages | map({name, agent, default})' \
  '[{"name":"documentation","agent":"fleet-board:documentation-reviewer","default":true},{"name":"blast_radius","agent":"fleet-board:blast-radius-reviewer","default":true}]'
# a project stage named documentation replaces the built-in one
REPO="$(printf 'board:\n  repo: a/b\nreview: { stages: [ { name: documentation, agent: "acme:docs", model: sonnet } ] }\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_exit "stages: project documentation stage is valid" 0
assert_stdout_exact_jq "stages: a project stage named documentation replaces the built-in one" \
  '[.review.stages[] | select(.name == "documentation") | .agent]' '["acme:docs"]'
assert_stdout_exact_jq "stages: replacing documentation keeps the blast_radius built-in" \
  '.review.stages | map(.name) | sort' '["blast_radius","documentation"]'
# a stage entry with enabled: false removes the built-in
REPO="$(printf 'board:\n  repo: a/b\nreview:\n  stages:\n    - name: blast_radius\n      enabled: false\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_exit "stages: enabled false entry is valid" 0
assert_stdout_exact_jq "stages: a stage entry name blast_radius with enabled false removes that stage from the printed config" \
  '.review.stages | map(.name)' '["documentation"]'
invalid_field_case "stages not a list" 'review: { stages: 3 }' "review.stages must be a list"
invalid_field_case "stage bad name" 'review: { stages: [ { name: "Sec-1", agent: a } ] }' "review.stages[0].name must match ^[a-z][a-z0-9_]*$"
invalid_field_case "stage duplicate name" 'review: { stages: [ { name: s, agent: a }, { name: s, agent: b } ] }' "review.stages[1].name s is not unique"
invalid_field_case "stage missing agent" 'review: { stages: [ { name: s } ] }' "review.stages[0] must set exactly one of agent and provider"
invalid_field_case "stage bad agent" 'review: { stages: [ { name: s, agent: "a b" } ] }' "review.stages[0].agent must match ^[A-Za-z0-9_-]+(:[A-Za-z0-9_-]+)?$"
invalid_field_case "stage empty model" 'review: { stages: [ { name: s, agent: a, model: "" } ] }' "review.stages[0].model must be a non-empty string"
invalid_field_case "stage paths" 'review: { stages: [ { name: s, agent: a, paths: [""] } ] }' "review.stages[0].paths must be a list of non-empty strings"
invalid_field_case "stage label reserved" 'review: { stages: [ { name: s, agent: a, label: needs-human-qa } ] }' "review.stages[0].label must be a non-empty string"
invalid_field_case "stage label duplicate" 'review: { stages: [ { name: s, agent: a, label: x }, { name: t, agent: a, label: x } ] }' "review.stages[1].label must be a non-empty string"
invalid_field_case "stage advisory" 'review: { stages: [ { name: s, agent: a, advisory: yes_please } ] }' "review.stages[0].advisory must be boolean"
invalid_field_case "stage default" 'review: { stages: [ { name: s, agent: a, default: yes_please } ] }' "review.stages[0].default must be boolean"
invalid_field_case "stage max_rounds" 'review: { stages: [ { name: s, agent: a, max_rounds: 0 } ] }' "review.stages[0].max_rounds must be a positive integer"
invalid_field_case "stage brief" 'review: { stages: [ { name: s, agent: a, brief: 7 } ] }' "review.stages[0].brief must be a string"
REPO="$(printf 'board:\n  repo: a/b\nreview: { stages: [ { name: s, agent: a } ] }\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_stdout_exact_jq "stage without required_passes gets 1" '.review.stages[0].required_passes' '1'
invalid_field_case "stage required_passes 0" 'review: { stages: [ { name: s, agent: a, required_passes: 0 } ] }' "review.stages[0].required_passes must be an integer from 1 to 5"
invalid_field_case "stage required_passes 6" 'review: { stages: [ { name: s, agent: a, required_passes: 6 } ] }' "review.stages[0].required_passes must be an integer from 1 to 5"
invalid_field_case "stage required_passes 1.5" 'review: { stages: [ { name: s, agent: a, required_passes: 1.5 } ] }' "review.stages[0].required_passes must be an integer from 1 to 5"
invalid_field_case "stage required_passes string" 'review: { stages: [ { name: s, agent: a, required_passes: many } ] }' "review.stages[0].required_passes must be an integer from 1 to 5"
REPO="$(printf 'board:\n  repo: a/b\nreview: { stages: [ { name: s, agent: a, required_passes: 5 } ] }\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_exit "stage required_passes 5 is valid" 0
assert_stdout_exact_jq "stage required_passes 5 kept" '.review.stages[0].required_passes' '5'
# (board is already a key in invalid_field_case's base, so this one builds its own repo)
REPO="$(printf 'board:\n  repo: a/b\n  states: { review_x: "X Review" }\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_exit "field-validation board.states names no stage: exit 5" "5"
assert_stderr_contains "field-validation board.states names no stage: names the field" "board.states key review_x names no stage"
REPO="$(printf 'board:\n  repo: a/b\n  states: { review_security: "Sec" }\nreview: { stages: [ { name: security, agent: a } ] }\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_exit "stages: board.states may map a stage" 0
REPO="$(printf 'board:\n  repo: a/b\nreview:\n  stages:\n    - name: security\n      agent: "acme:sec"\n      paths: ["src/auth/**"]\n    - name: ux\n      agent: ux-reviewer\n      advisory: true\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_exit "stages: block list of block maps parses" 0
assert_stdout_exact_jq "stages: block form names" '.review.stages | map(.name)' '["security","ux"]'

# providers map and provider-backed stages
REPO="$(make_test_repo provider-stage.yml)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_exit "provider stage: valid" 0
assert_stdout_exact_jq "provider stage merges preset" '.providers.openai' \
  '{"base_url":"https://api.openai.com/v1","api_key_env":"OPENAI_API_KEY","max_tokens_param":"max_completion_tokens"}'
assert_stdout_exact_jq "provider stage: filled stage object" '.review.stages[0]' \
  '{"name":"security","agent":null,"provider":"openai","model":"gpt-test","paths":[],"label":"needs-security-review","advisory":false,"max_rounds":3,"required_passes":1,"brief":null,"timeout":600,"max_output_tokens":16000,"max_diff_bytes":400000}'
SP='{ name: s, provider: PROV, model: m, price: { input: 1, output: 2 } }'
for prov in gemini openrouter ollama; do
  REPO="$(printf 'board:\n  repo: a/b\nreview: { stages: [ %s ] }\n' "${SP/PROV/$prov}" | make_inline_repo)"
  CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
  assert_exit "preset $prov: valid" 0
  case "$prov" in
    gemini) want='{"base_url":"https://generativelanguage.googleapis.com/v1beta/openai","api_key_env":"GEMINI_API_KEY","max_tokens_param":"max_tokens"}' ;;
    openrouter) want='{"base_url":"https://openrouter.ai/api/v1","api_key_env":"OPENROUTER_API_KEY","max_tokens_param":"max_tokens"}' ;;
    ollama) want='{"base_url":"http://localhost:11434/v1","api_key_env":null,"max_tokens_param":"max_tokens"}' ;;
  esac
  assert_stdout_exact_jq "preset $prov values" ".providers.$prov" "$want"
done
REPO="$(printf 'board:\n  repo: a/b\nproviders: { openai: { api_key_env: WORK_OPENAI } }\nreview: { stages: [ %s ] }\n' "${SP/PROV/openai}" | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_stdout_exact_jq "user provider overrides preset key by key" '.providers.openai' \
  '{"base_url":"https://api.openai.com/v1","api_key_env":"WORK_OPENAI","max_tokens_param":"max_completion_tokens"}'
REPO="$(printf 'board:\n  repo: a/b\nproviders: { corp: { base_url: "https://llm.corp.example/v1", api_key_env: CORP_KEY } }\nreview: { stages: [ %s ] }\n' "${SP/PROV/corp}" | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_exit "custom provider: valid" 0
assert_stdout_exact_jq "custom provider: max_tokens_param defaults" '.providers.corp.max_tokens_param' '"max_completion_tokens"'
REPO="$(printf 'board:\n  repo: a/b\nreview: { stages: [ { name: s, agent: a } ] }\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_stdout_exact_jq "agent stage: providers stays empty" '.providers' '{}'
assert_stdout_exact_jq "agent stage: provider null, no price" '.review.stages[0] | [.provider, has("price")]' '[null,false]'
REPO="$(make_test_repo stages.yml)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_exit "stages.yml fixture: valid" 0
assert_stdout_exact_jq "stages.yml: three stages" '.review.stages | map(.name)' '["security","ux","compliance"]'
assert_stdout_exact_jq "stages.yml: compliance is a provider stage" '.review.stages[2] | [.agent, .provider, .model, has("price")]' '[null,"openai","gpt-test",false]'

BASE_CORP='providers: { corp: { base_url: "https://llm.corp.example/v1", api_key_env: CORP_KEY } }'
CORP_STAGE='review: { stages: [ { name: s, provider: corp, model: m, price: { input: 1, output: 2 } } ] }'
invalid_field_case "stage both agent and provider" 'review: { stages: [ { name: s, agent: a, provider: openai, model: m, price: { input: 1, output: 2 } } ] }' "review.stages[0] must set exactly one of agent and provider"
invalid_field_case "stage bad provider name" 'review: { stages: [ { name: s, provider: "Open AI", model: m, price: { input: 1, output: 2 } } ] }' "review.stages[0].provider must match ^[a-z][a-z0-9_-]*\$"
invalid_field_case "stage unknown provider" 'review: { stages: [ { name: s, provider: foo, model: m, price: { input: 1, output: 2 } } ] }' "review.stages[0].provider foo names no provider"
invalid_field_case "provider stage no model" 'review: { stages: [ { name: s, provider: openai, price: { input: 1, output: 2 } } ] }' "review.stages[0].model must be set when provider is set"
# Tokens only: a provider stage needs no price, and an old price key is ignored (dropped from the stage).
REPO="$(printf 'board:\n  repo: a/b\nreview: { stages: [ { name: s, provider: openai, model: m } ] }\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_exit "provider stage with no price: valid" 0
REPO="$(printf 'board:\n  repo: a/b\nreview: { stages: [ { name: s, provider: openai, model: m, price: { input: -1, output: cheap } } ] }\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_exit "provider stage with an old price key: valid" 0
assert_stdout_exact_jq "provider stage with an old price key: price dropped" '.review.stages[0] | has("price")' 'false'
for k in timeout max_output_tokens max_diff_bytes; do
  invalid_field_case "stage $k" "review: { stages: [ { name: s, provider: openai, model: m, price: { input: 1, output: 2 }, $k: 0 } ] }" "review.stages[0].$k must be a positive integer"
done
invalid_field_case "provider base_url http" "providers: { corp: { base_url: \"http://llm.corp.example/v1\", api_key_env: CORP_KEY } }"$'\n'"$CORP_STAGE" "providers.corp.base_url must start with https:// or a loopback http:// address"
invalid_field_case "provider base_url lookalike" "providers: { corp: { base_url: \"http://localhost.evil.example/v1\", api_key_env: CORP_KEY } }"$'\n'"$CORP_STAGE" "providers.corp.base_url must start with https:// or a loopback http:// address"
# userinfo in the authority sends the request (and the key) to the host after '@'
for u in 'http://localhost:@evil.example/v1' 'http://127.0.0.1:1@evil.example/v1' 'http://[::1]:x@evil.example/v1' 'http://localhost:123@example.com/v1' 'https://user@x.example/v1'; do
  invalid_field_case "provider base_url userinfo $u" "providers: { corp: { base_url: \"$u\", api_key_env: CORP_KEY } }"$'\n'"$CORP_STAGE" "providers.corp.base_url must not contain userinfo"
done
invalid_field_case "provider base_url loopback bad port" "providers: { corp: { base_url: \"http://localhost:abc/v1\", api_key_env: CORP_KEY } }"$'\n'"$CORP_STAGE" "providers.corp.base_url must start with https:// or a loopback http:// address"
for u in 'http://localhost:11434/v1' 'http://[::1]:8080/' 'http://127.0.0.1/v1' 'http://localhost' 'https://x.example/v1?a=b@c'; do
  REPO="$(printf 'board:\n  repo: a/b\nproviders: { corp: { base_url: "%s", api_key_env: null } }\n%s\n' "$u" "$CORP_STAGE" | make_inline_repo)"
  CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
  case "$u" in
    https://*) assert_stderr_not_contains "provider base_url $u: '@' after the authority is not userinfo" "userinfo" ;;
    *) assert_exit "provider base_url $u: loopback accepted" 0 ;;
  esac
done
invalid_field_case "provider api_key_env bad" "providers: { corp: { base_url: \"https://x.example/v1\", api_key_env: sk_lower } }"$'\n'"$CORP_STAGE" "providers.corp.api_key_env must match ^[A-Z_][A-Z0-9_]*\$"
invalid_field_case "provider api_key_env null remote" "providers: { corp: { base_url: \"https://x.example/v1\", api_key_env: null } }"$'\n'"$CORP_STAGE" "providers.corp.api_key_env may be null only for a loopback base_url"
invalid_field_case "provider max_tokens_param" "providers: { corp: { base_url: \"https://x.example/v1\", api_key_env: K, max_tokens_param: limit } }"$'\n'"$CORP_STAGE" "providers.corp.max_tokens_param must be max_tokens or max_completion_tokens"
for k in api_key key token secret; do
  invalid_field_case "provider $k not allowed" "providers: { corp: { base_url: \"https://x.example/v1\", api_key_env: K, $k: topsecretvalue } }"$'\n'"$CORP_STAGE" "providers.corp.$k is not allowed; name an environment variable in api_key_env"
done
REPO="$(printf 'board:\n  repo: a/b\nproviders: { corp: { base_url: "https://x.example/v1", api_key_env: K, api_key: topsecretvalue } }\n%s\n' "$CORP_STAGE" | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
case "$LAST_ERR$LAST_OUT" in
  *topsecretvalue*) fail "provider key value never echoed" "value appeared in output" ;;
  *) pass "provider key value never echoed" ;;
esac
REPO="$(printf 'board:\n  repo: a/b\nproviders: { corp: { base_url: "https://x.example/v1", api_key_env: K } }\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_exit "unused provider: still exit 0" 0
assert_stderr_contains "unused provider: warns" "providers.corp is not used by any stage"
REPO="$(printf 'board:\n  repo: a/b\nreview: { stages: [ { name: s, provider: openai, price: { input: 1, output: 2 } } ] }\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_stderr_exact "provider stage no model: exactly one message" "config.sh: invalid config: review.stages[0].model must be set when provider is set"

# command providers (the codex preset)
CODEX_STAGE='review: { stages: [ { name: s, provider: codex, model: gpt-6-astra, price: { input: 0, output: 0 } } ] }'
REPO="$(printf 'board:\n  repo: a/b\nproviders: { codex: {} }\n%s\n' "$CODEX_STAGE" | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_exit "codex preset with providers: {codex: {}}: valid" 0
assert_stdout_exact_jq "codex preset: command from presets.json" '.providers.codex.command' '"codex exec --skip-git-repo-check -s read-only -m {model}"'
assert_stdout_exact_jq "codex preset: no key variable, no base_url" '.providers.codex | [.base_url, .api_key_env]' '[null,null]'
REPO="$(printf 'board:\n  repo: a/b\n%s\n' "$CODEX_STAGE" | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_exit "codex preset named only by a stage: valid" 0
assert_stdout_exact_jq "codex preset named only by a stage: command present" '.providers.codex.command | type' '"string"'
REPO="$(printf 'board:\n  repo: a/b\nreview: { stages: [ %s ] }\n' "${SP/PROV/openai}" | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_stdout_exact_jq "http preset has no command key" '.providers.openai | has("command")' 'false'
REPO="$(printf 'board:\n  repo: a/b\nproviders: { mycmd: { command: "mytool --model {model}" } }\nreview: { stages: [ { name: s, provider: mycmd, model: m, price: { input: 0, output: 0 } } ] }\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_exit "custom command provider: valid" 0
invalid_field_case "command with base_url" "providers: { codex: { base_url: \"https://x.example/v1\" } }"$'\n'"$CODEX_STAGE" "providers.codex sets both command and base_url"
invalid_field_case "command with api_key_env" "providers: { codex: { api_key_env: SOME_KEY } }"$'\n'"$CODEX_STAGE" "providers.codex.api_key_env must be null when command is set"
invalid_field_case "command not a string" "providers: { mycmd: { command: 5 } }"$'\n''review: { stages: [ { name: s, provider: mycmd, model: m, price: { input: 0, output: 0 } } ] }' "providers.mycmd.command must be a non-empty string"
invalid_field_case "command empty" "providers: { mycmd: { command: \"\" } }"$'\n''review: { stages: [ { name: s, provider: mycmd, model: m, price: { input: 0, output: 0 } } ] }' "providers.mycmd.command must be a non-empty string"

# a local board: accepted, defaults filled, board.dir and board.port validated
REPO="$(printf 'board:\n  repo: acme/toy\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_exit "a local board config: exit 0" "0"
assert_key "$REPO" "board.dir" ".fleet-board" "board.dir default"
assert_key "$REPO" "board.port" "8765" "board.port default"
REPO="$(printf 'board:\n  repo: acme/toy\n  dir: /tmp/x\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO" --check
assert_exit "absolute board.dir exit 5" "5"; assert_stderr_contains "absolute board.dir named" "board.dir"
REPO="$(printf 'board:\n  repo: acme/toy\n  dir: ../x\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO" --check
assert_exit "dotdot board.dir exit 5" "5"
REPO="$(printf 'board:\n  repo: acme/toy\n  dir: a/../x\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO" --check
assert_exit "embedded dotdot board.dir exit 5" "5"
REPO="$(printf 'board:\n  repo: acme/toy\n  dir: a..b/x\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO" --check
assert_exit "dots inside a segment name are fine" "0"
REPO="$(printf 'board:\n  repo: acme/toy\n  port: 80\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO" --check
assert_exit "low port exit 5" "5"; assert_stderr_contains "port named" "board.port"
REPO="$(printf 'board:\n  repo: acme/toy\n  port: 70000\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO" --check
assert_exit "high port exit 5" "5"

# The board is always local: the backend keys are refused with a pointer at the importer
for kv in "backend: local" "backend: github-labels" "backend: github-projects" "project_number: 1" "project_owner: someone"; do
  k="${kv%%:*}"
  REPO="$(printf 'board:\n  repo: acme/toy\n  %s\n' "$kv" | make_inline_repo)"
  CLEANUP_DIRS+=("$REPO"); run_config "$REPO" --check
  assert_exit "removed key board.$kv: exit 5" "5"
  assert_stderr_contains "removed key board.$kv: names the key" "board.$k is no longer a setting"
  assert_stderr_contains "removed key board.$kv: says the board is always local" "the board is now always local"
  assert_stderr_contains "removed key board.$kv: names the importer" "import-github.sh"
done
REPO="$(printf 'board:\n  repo: acme/toy\n  backend: local\n  project_number: 1\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO" --check
assert_eq_count() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected $3, got $2"; fi; }
assert_eq_count "removed keys: one message per key" "$(printf '%s\n' "$LAST_ERR" | grep -c 'is no longer a setting')" "2"

# The tick system is gone: its keys are refused, one message per key
for kv in "limits: { max_cost_usd: 40 }" "limits: { tick_interval: 60 }" "limits: { min_tick_gap: 0 }" \
  "limits: { max_consecutive_failures: 3 }" "models: { manager: sonnet }"; do
  sect="${kv%%:*}"; k="${kv#*\{ }"; k="${k%%:*}"
  REPO="$(printf 'board:\n  repo: acme/toy\n%s\n' "$kv" | make_inline_repo)"
  CLEANUP_DIRS+=("$REPO"); run_config "$REPO" --check
  assert_exit "removed tick key $sect.$k: exit 5" "5"
  assert_stderr_contains "removed tick key $sect.$k: names the key" "$sect.$k is no longer a setting"
  assert_stderr_contains "removed tick key $sect.$k: points at the supervisor" "supervisor"
done
REPO="$(printf 'board:\n  repo: acme/toy\nlimits: { max_cost_usd: 40, tick_interval: 60 }\nmodels: { manager: sonnet }\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO" --check
assert_eq_count "removed tick keys: one message per key" "$(printf '%s\n' "$LAST_ERR" | grep -c 'is no longer a setting')" "3"
REPO="$(printf 'board:\n  repo: acme/toy\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_eq_count "defaults carry no tick key" \
  "$(printf '%s' "$LAST_OUT" | jq -c '[(.limits | has("max_cost_usd"), has("tick_interval"), has("min_tick_gap"), has("max_consecutive_failures")), (.models | has("manager"))]')" '[false,false,false,false,false]'
REPO="$(printf 'board:\n  repo: acme/toy\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_exit "no backend key: exit 0" "0"
assert_eq_count "no backend key: the merged config has no backend or project keys" \
  "$(printf '%s' "$LAST_OUT" | jq -c '.board | [has("backend"), has("project_number"), has("project_owner")]')" '[false,false,false]'
assert_key "$REPO" "board.dir" ".fleet-board" "no backend key: board.dir default stays"
assert_key "$REPO" "board.port" "8765" "no backend key: board.port default stays"
assert_key "$REPO" "board.repo" "acme/toy" "no backend key: board.repo stays"

reviewer='{ provider: codex, model: gpt-6-astra, price: { input: 0, output: 0 } }'
reviewer_cfg="models: { reviewer: $reviewer, escalation: opus }"
invalid_field_case "reviewer invalid type" 'models: { reviewer: [] }' "models.reviewer must be a non-empty string or an object"
invalid_field_case "reviewer unknown provider" "${reviewer_cfg/codex/unknown}" "models.reviewer.provider unknown names no provider"
invalid_field_case "reviewer HTTP provider" "${reviewer_cfg/codex/openai}" "models.reviewer.provider openai has no review_command"
invalid_field_case "reviewer invalid model" "${reviewer_cfg/gpt-6-astra/123}" "models.reviewer.model must be a non-empty string"
REPO="$(printf 'board: { repo: a/b }\n%s\n' "${reviewer_cfg/input: 0/input: -1}" | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_exit "reviewer with an old price key: valid (price is ignored)" 0
REPO="$(printf 'board: { repo: a/b }\nmodels: { reviewer: { provider: codex, model: gpt-6-astra }, escalation: opus }\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_exit "reviewer provider with no price: valid" 0
invalid_field_case "reviewer invalid timeout" "${reviewer_cfg/model: gpt-6-astra/model: gpt-6-astra, timeout: 1501}" "models.reviewer.timeout must be an integer from 1 to 1500"
invalid_field_case "reviewer missing escalation" "models: { reviewer: $reviewer }" "models.escalation must be set when models.reviewer is a provider"
invalid_field_case "agent stage missing model" "$reviewer_cfg"$'\n''review: { stages: [{name: s, agent: reviewer}] }' "review.stages[0].model must be set when models.reviewer is a provider"
invalid_field_case "review command missing dir" 'providers: { codex: { review_command: "codex exec" } }' "providers.codex.review_command must contain {dir}"
for flag in --dangerously-bypass-approvals-and-sandbox danger-full-access --dangerously-bypass-hook-trust; do
  invalid_field_case "review command rejects $flag" "providers: { codex: { review_command: \"codex $flag {dir}\" } }" "providers.codex.review_command must not contain $flag"
done
invalid_field_case "review command with HTTP" 'providers: { codex: { base_url: "https://example.com" } }' "providers.codex sets both review_command and base_url"

REPO="$(printf 'board: { repo: a/b }\n%s\n' "$reviewer_cfg" | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_exit "reviewer object is accepted" 0
assert_stdout_exact_jq "reviewer timeout defaults" '.models.reviewer.timeout' '1500'
assert_stdout_exact_jq "codex review command preset" .providers.codex.review_command '"codex exec --ephemeral --skip-git-repo-check -s workspace-write -c sandbox_workspace_write.network_access=true -c sandbox_workspace_write.exclude_tmpdir_env_var=true -c sandbox_workspace_write.exclude_slash_tmp=true -c features.network_proxy.enabled=true -c features.network_proxy.allow_local_binding=true -c '"'"'features.network_proxy.proxy_url=\"http://127.0.0.1:0\"'"'"' -c '"'"'features.network_proxy.socks_url=\"http://127.0.0.1:0\"'"'"' -c '"'"'features.network_proxy.domains={\"localhost\"=\"allow\",\"127.0.0.1\"=\"allow\",\"::1\"=\"allow\"}'"'"' -C {dir} -m {model}"'
REPO="$(printf 'board: { repo: a/b }\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_exit "default reviewer is accepted" 0
assert_stdout_exact_jq "reviewer string is unchanged" '.models.reviewer' '"opus"'

# Supervisor configuration is validated before the launcher can use it.
REPO="$(make_test_repo supervisor-default.yml)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_exit "supervisor defaults accepted" 0
assert_stdout_exact_jq "supervisor exact defaults" '.supervisor' '{"reconcile_interval_seconds":5,"progress_timeout_seconds":900,"attempt_timeout_seconds":7200,"shutdown_grace_seconds":30,"retry_backoff_seconds":60,"aging_seconds":900,"provider_concurrency":{},"scope_ignore":[],"version_files":[]}'
assert_stdout_exact_jq "supervisor defaults carry no enabled, start_on_boot or heartbeat key" '.supervisor | [has("enabled"), has("start_on_boot"), has("heartbeat_interval_seconds"), has("heartbeat_timeout_seconds")]' '[false,false,false,false]'
REPO="$(make_test_repo supervisor-caps.yml)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_exit "supervisor with configured caps" 0
assert_stdout_exact_jq "supervisor provider caps preserved" '.supervisor.provider_concurrency' '{"claude":2,"codex":1}'
# config.sh checks only the supervisor keys it knows: a stale enabled or start_on_boot is ignored, not rejected.
for k in enabled start_on_boot heartbeat_interval_seconds; do
  for v in null 1 '"true"' 0; do
    REPO="$(printf 'board: { repo: a/b }\nsupervisor: { %s: %s }\n' "$k" "$v" | make_inline_repo)"
    CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
    assert_exit "supervisor $k: $v is ignored, not validated" 0
  done
done
REPO="$(make_test_repo supervisor-invalid.yml)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_exit "supervisor invalid fixture rejected" 5
for k in reconcile_interval_seconds progress_timeout_seconds attempt_timeout_seconds shutdown_grace_seconds retry_backoff_seconds aging_seconds; do
  for v in 0 -1 1.5 null '"5"' '[]'; do
    invalid_field_case "supervisor $k rejects $v" "supervisor: { $k: $v }" "supervisor.$k must be a positive integer"
  done
done
invalid_field_case "supervisor section type" 'supervisor: []' 'supervisor must be an object'
invalid_field_case "supervisor caps type" 'supervisor: { provider_concurrency: [] }' 'supervisor.provider_concurrency must be an object'
invalid_field_case "supervisor unknown cap" 'supervisor: { provider_concurrency: { unknown: 1 } }' 'supervisor.provider_concurrency.unknown names no provider'
for v in 0 -1 1.5 null '"1"' '[]'; do
  invalid_field_case "supervisor cap rejects $v" "supervisor: { provider_concurrency: { claude: $v } }" 'supervisor.provider_concurrency.claude must be a positive integer'
done
# supervisor.scope_ignore: repo-relative globs the scheduler leaves out of scope overlap
REPO="$(printf 'board: { repo: a/b }\nsupervisor: { scope_ignore: [".claude-plugin/marketplace.json", "plugins/*/.claude-plugin/plugin.json"] }\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_exit "supervisor scope_ignore list accepted" 0
assert_stdout_exact_jq "supervisor scope_ignore preserved" '.supervisor.scope_ignore' '[".claude-plugin/marketplace.json","plugins/*/.claude-plugin/plugin.json"]'
for v in '"x.json"' 3 null '{ a: 1 }'; do
  invalid_field_case "supervisor scope_ignore rejects $v" "supervisor: { scope_ignore: $v }" 'supervisor.scope_ignore must be a list of strings'
done
for v in '[""]' '[3]' '[null]'; do
  invalid_field_case "supervisor scope_ignore entry rejects $v" "supervisor: { scope_ignore: $v }" 'supervisor.scope_ignore entries must be non-empty strings'
done
for v in '"/etc/x.json"' '"../x.json"' '"a/../b.json"' '".."' '"a/./b.json"' '"\\\\etc\\\\x.json"'; do
  invalid_field_case "supervisor scope_ignore path rejects $v" "supervisor: { scope_ignore: [$v] }" 'supervisor.scope_ignore entries must be repo-relative, without a leading / or ..'
done
for v in '"*"' '"**"' '"*/*"' '"?"' '"./"' '"."' '"/"' '"**/"'; do
  invalid_field_case "supervisor scope_ignore wildcard-only rejects $v" "supervisor: { scope_ignore: [$v] }" 'supervisor.scope_ignore entries must name a path, not only wildcards or separators'
done
for k in scope_ignore version_files; do
  invalid_field_case "supervisor $k rejects [z-a].json" "supervisor: { $k: [\"ok.json\", \"[z-a].json\"] }" "supervisor.$k entry \"[z-a].json\" is not a valid glob"
  invalid_field_case "supervisor $k rejects x/[b-a]" "supervisor: { $k: [\"x/[b-a]\"] }" "supervisor.$k entry \"x/[b-a]\" is not a valid glob"
done
# supervisor.version_files: the same glob rules
REPO="$(printf 'board: { repo: a/b }\nsupervisor: { version_files: [".claude-plugin/marketplace.json", "plugins/*/.claude-plugin/plugin.json", "**/package.json"] }\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_exit "supervisor version_files list accepted" 0
assert_stdout_exact_jq "supervisor version_files preserved" '.supervisor.version_files' '[".claude-plugin/marketplace.json","plugins/*/.claude-plugin/plugin.json","**/package.json"]'
for v in '"x.json"' 3 null '{ a: 1 }'; do
  invalid_field_case "supervisor version_files rejects $v" "supervisor: { version_files: $v }" 'supervisor.version_files must be a list of strings'
done
for v in '[""]' '[3]'; do
  invalid_field_case "supervisor version_files entry rejects $v" "supervisor: { version_files: $v }" 'supervisor.version_files entries must be non-empty strings'
done
for v in '"/x.json"' '"../x.json"'; do
  invalid_field_case "supervisor version_files path rejects $v" "supervisor: { version_files: [$v] }" 'supervisor.version_files entries must be repo-relative, without a leading / or ..'
done
for v in '"*"' '"**/*"' '"."'; do
  invalid_field_case "supervisor version_files wildcard-only rejects $v" "supervisor: { version_files: [$v] }" 'supervisor.version_files entries must name a path, not only wildcards or separators'
done
invalid_field_case "supervisor deadline equality" 'supervisor: { attempt_timeout_seconds: 30, shutdown_grace_seconds: 30 }' 'supervisor.attempt_timeout_seconds must exceed shutdown_grace_seconds'
invalid_field_case "supervisor deadline less" 'supervisor: { attempt_timeout_seconds: 29, shutdown_grace_seconds: 30 }' 'supervisor.attempt_timeout_seconds must exceed shutdown_grace_seconds'

# Test 30: token limits. limits.max_tokens is a positive integer (default 20000000);
# limits.max_tokens_per_card is null or a positive integer (default null).
REPO="$(printf 'board:\n  repo: a/b\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_exit "token limits defaults accepted" 0
assert_stdout_exact_jq "limits.max_tokens defaults to 20000000" '.limits.max_tokens' '20000000'
assert_stdout_exact_jq "limits.max_tokens_per_card defaults to null" '.limits.max_tokens_per_card' 'null'
REPO="$(printf 'board:\n  repo: a/b\nlimits: { max_tokens: 500000, max_tokens_per_card: 90000 }\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_exit "token limits set accepted" 0
assert_stdout_exact_jq "limits.max_tokens set" '.limits.max_tokens' '500000'
assert_stdout_exact_jq "limits.max_tokens_per_card set" '.limits.max_tokens_per_card' '90000'
for v in 0 -1 1.5 null '"5"' '[]'; do
  invalid_field_case "max_tokens rejects $v" "limits: { max_tokens: $v }" "limits.max_tokens must be a positive integer"
done
for v in 0 -1 1.5 '"5"' '[]'; do
  invalid_field_case "max_tokens_per_card rejects $v" "limits: { max_tokens_per_card: $v }" "limits.max_tokens_per_card must be null or a positive integer"
done
REPO="$(printf 'board:\n  repo: a/b\nlimits: { max_tokens_per_card: null }\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_exit "max_tokens_per_card null accepted" 0

# merge.persona (null or a non-empty relative path), merge.persona_append (null or string), models.merger
REPO="$(printf 'board:\n  repo: a/b\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
# null: the driver uses .fleet-board/merger.md when present, else the plugin default (a set path is explicit)
assert_stdout_exact_jq "merge.persona defaults to null" '.merge.persona' 'null'
assert_stdout_exact_jq "merge.persona_append defaults to null" '.merge.persona_append' 'null'
assert_stdout_exact_jq "models.merger defaults to sonnet" '.models.merger' '"sonnet"'
REPO="$(printf 'board:\n  repo: a/b\nmerge:\n  persona: null\n  persona_append: "Also run make deploy."\nmodels: { merger: opus }\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_exit "merge.persona null with an append accepted" 0
assert_stdout_exact_jq "merge.persona null kept" '.merge.persona' 'null'
assert_stdout_exact_jq "merge.persona_append kept" '.merge.persona_append' '"Also run make deploy."'
assert_stdout_exact_jq "models.merger overridden" '.models.merger' '"opus"'
REPO="$(printf 'board:\n  repo: a/b\nmerge:\n  persona: docs/merger.md\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_stdout_exact_jq "merge.persona relative path kept" '.merge.persona' '"docs/merger.md"'
for v in '""' '/etc/merger.md' '../merger.md' 'a/../b.md' '5' '[x]'; do
  invalid_field_case "merge.persona rejects $v" $'merge:\n  persona: '"$v" "merge.persona must be null or a non-empty relative path without .."
done
for v in '5' '[x]'; do
  invalid_field_case "merge.persona_append rejects $v" $'merge:\n  persona_append: '"$v" "merge.persona_append must be null or a string"
done
invalid_field_case "models.merger empty" 'models: { merger: "" }' "models.merger must be a non-empty string"
invalid_field_case "models.merger number" 'models: { merger: 5 }' "models.merger must be a non-empty string"

# merge.ignore_checks: a list of {name, reason, until}; every field required, until a real YYYY-MM-DD
REPO="$(printf 'board:\n  repo: a/b\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_stdout_exact_jq "merge.ignore_checks defaults to []" '.merge.ignore_checks' '[]'
REPO="$(printf 'board:\n  repo: a/b\nmerge:\n  ignore_checks:\n    - name: "lint-*"\n      reason: flaky docs lint\n      until: 2026-12-31\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_exit "ignore_checks entry accepted" 0
assert_stdout_exact_jq "ignore_checks entry kept as strings" '.merge.ignore_checks' '[{"name":"lint-*","reason":"flaky docs lint","until":"2026-12-31"}]'
IGN_MSG="merge.ignore_checks entries need a non-empty name and reason and an until date (YYYY-MM-DD)"
invalid_field_case "ignore_checks missing until" $'merge:\n  ignore_checks:\n    - name: lint\n      reason: r' "$IGN_MSG"
invalid_field_case "ignore_checks missing reason" $'merge:\n  ignore_checks:\n    - name: lint\n      until: 2026-12-31' "$IGN_MSG"
# pending: an optional boolean; true lets a matching check that is still running count as green
REPO="$(printf 'board:\n  repo: a/b\nmerge:\n  ignore_checks:\n    - name: "*"\n      reason: CI is asynchronous\n      until: 2026-12-31\n      pending: true\n' | make_inline_repo)"
run_config "$REPO"
assert_exit "ignore_checks entry with pending: true accepted" 0
assert_stdout_exact_jq "ignore_checks pending kept as a boolean" '.merge.ignore_checks[0].pending' 'true'
invalid_field_case "ignore_checks pending must be a boolean" $'merge:\n  ignore_checks:\n    - name: lint\n      reason: r\n      until: 2026-12-31\n      pending: "yes"' "merge.ignore_checks pending must be true or false"
invalid_field_case "ignore_checks pending: null is refused" $'merge:\n  ignore_checks:\n    - name: lint\n      reason: r\n      until: 2026-12-31\n      pending: null' "merge.ignore_checks pending must be true or false"
invalid_field_case "ignore_checks missing name" $'merge:\n  ignore_checks:\n    - reason: r\n      until: 2026-12-31' "$IGN_MSG"
invalid_field_case "ignore_checks empty reason" $'merge:\n  ignore_checks:\n    - name: lint\n      reason: ""\n      until: 2026-12-31' "$IGN_MSG"
for d in 2026-13-01 2026-02-30 20261231 2026-1-5 soon 2026-12-31T00:00; do
  invalid_field_case "ignore_checks bad date $d" $'merge:\n  ignore_checks:\n    - name: lint\n      reason: r\n      until: "'"$d"$'"' "$IGN_MSG"
done
invalid_field_case "ignore_checks not a list" $'merge:\n  ignore_checks: lint' "merge.ignore_checks must be a list"
invalid_field_case "ignore_checks entry not a map" $'merge:\n  ignore_checks:\n    - lint' "$IGN_MSG"

# Test 31: headless.permission_mode, limits.max_turns and limits.max_hours are validated by --check
check_case() { # NAME YAML_BODY EXPECTED_EXIT [EXPECTED_STDERR]
  REPO="$(printf 'board:\n  repo: a/b\n%s\n' "$2" | make_inline_repo)"
  CLEANUP_DIRS+=("$REPO")
  run_config "$REPO" --check
  assert_exit "$1: exit $3" "$3"
  [ -z "${4:-}" ] || assert_stderr_contains "$1: message" "$4"
}
check_case "config.sh --check refuses permission_mode bypassPermissions and names the allowed values" $'headless:\n  permission_mode: bypassPermissions' 5 "auto, acceptEdits, default, plan"
check_case "bypassPermissions message says why" $'headless:\n  permission_mode: bypassPermissions' 5 "no permission checks"
check_case "config.sh --check refuses limits.max_turns ten" $'limits:\n  max_turns: ten' 5 "limits.max_turns must be a positive integer"
check_case "config.sh --check refuses limits.max_hours 0" $'limits:\n  max_hours: 0' 5 "limits.max_hours must be a positive integer"
for m in auto acceptEdits default plan; do
  check_case "config.sh --check accepts permission_mode $m" "headless: { permission_mode: $m }" 0
done

# Test 32: board.terminal_command is a list of strings containing {dir}; default opens macOS Terminal
REPO="$(printf 'board:\n  repo: a/b\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO" board.terminal_command
assert_stdout_exact "With no setting, board.terminal_command resolves to open -a Terminal {dir}" '["open","-a","Terminal","{dir}"]'
REPO="$(printf 'board:\n  repo: a/b\n  terminal_command: ["open", "-a", "iTerm", "{dir}"]\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO" board.terminal_command
assert_stdout_exact "A .fleet-board.yml board.terminal_command of open -a iTerm {dir} replaces the default as given" '["open","-a","iTerm","{dir}"]'
TC_MSG="board.terminal_command"
invalid_field_case "board.terminal_command not a list" '  terminal_command: "open -a Terminal {dir}"' "$TC_MSG"
invalid_field_case "board.terminal_command list of non-strings" '  terminal_command: ["open", 5, "{dir}"]' "$TC_MSG"
invalid_field_case "board.terminal_command list with no {dir}" '  terminal_command: ["open", "-a", "iTerm"]' "$TC_MSG"

echo ""
echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
