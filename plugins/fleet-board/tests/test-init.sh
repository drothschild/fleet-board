#!/usr/bin/env bash
#
# Plain-bash tests for init.sh (offline, using the fake gh).
# No framework, no dependencies beyond POSIX tools, jq and git.
#
# Usage: bash plugins/fleet-board/tests/test-init.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/../scripts/init.sh"
CONFIG_SH="${SCRIPT_DIR}/../scripts/config.sh"
FIXTURES="$SCRIPT_DIR/../fixtures/gh"

unset FLEET_BOARD_CONFIG FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT || true

PASS=0
FAIL=0
LAST_OUT=""
LAST_ERR=""
LAST_EXIT=0
CLEANUP_DIRS=()
ORIG_PATH="$PATH"

# Choose a bash executable for consistent invocation.
# Prefer /bin/bash if available (standard on macOS/BSD), else use bash from PATH.
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
    *) fail "$1" "expected to find '$2' in stderr, got: '$LAST_ERR'" ;;
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

# One whole line of stderr equals $2 exactly
assert_stderr_line() {
  if printf '%s\n' "$LAST_ERR" | grep -Fxq -- "$2"; then
    pass "$1"
  else
    fail "$1" "expected a stderr line exactly '$2', got: '$LAST_ERR'"
  fi
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

run_init() { run_check "$SCRIPT" "$@"; }

# --- fake gh call inspection (argv/<seq> holds one argument per line) ---

# Every recorded call, in call order
all_calls() {
  local f
  for f in "$FAKE_GH_DIR"/argv/*; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
}

# Calls whose first two arguments are $1 $2, in call order
calls_of() {
  local f
  for f in $(all_calls); do
    [ "$(sed -n 1p "$f")" = "$1" ] && [ "$(sed -n 2p "$f")" = "$2" ] && printf '%s\n' "$f"
  done
}

# `gh label create <name> ...` calls for exactly this name
label_creates_named() {
  local f
  for f in $(calls_of label create); do
    [ "$(sed -n 3p "$f")" = "$1" ] && printf '%s\n' "$f"
  done
}

# Calls (from stdin, one argv file per line) that carry the whole argument $1
with_arg() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] && grep -Fxq -- "$1" "$f" && printf '%s\n' "$f"
  done
}

# Calls (from stdin) that do NOT carry the whole argument $1
without_arg() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] && ! grep -Fxq -- "$1" "$f" && printf '%s\n' "$f"
  done
}

# file_has_pair <argv-file> <flag> <value>: <flag> immediately followed by <value>
file_has_pair() {
  local file="$1" flag="$2" value="$3" prev="" arg
  while IFS= read -r arg || [ -n "$arg" ]; do
    if [ "$prev" = "$flag" ] && [ "$arg" = "$value" ]; then return 0; fi
    prev="$arg"
  done < "$file"
  return 1
}

count_lines() { grep -c . || true; }

# Sequence number of an argv file (its call order)
seq_of() { local b; b="$(basename "$1")"; echo $((10#$b)); }

assert_count() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected $3, got $2"; fi
}

assert_no_config() {
  if [ ! -e "$TARGET/.fleet-board.yml" ]; then
    pass "$1"
  else
    fail "$1" "found $TARGET/.fleet-board.yml"
  fi
}

# The target dir holds exactly the listed entries (no stray temp files)
assert_dir_listing() {
  local got
  got="$(ls -A "$TARGET" | tr '\n' ' ')"
  if [ "$got" = "$2" ]; then pass "$1"; else fail "$1" "expected dir listing '$2', got '$got'"; fi
}

# cfg <key>: read the written config through config.sh
cfg() { FLEET_BOARD_CONFIG="$TARGET/.fleet-board.yml" "$BASH_EXE" "$CONFIG_SH" "$@" 2>&1; }

assert_cfg() {
  local got
  got="$(cfg "$2")"
  if [ "$got" = "$3" ]; then pass "$1"; else fail "$1" "config.sh $2: expected '$3', got '$got'"; fi
}

# Suite default routes (plan "Routing rule"): appended AFTER case-specific
# routes, because fake-gh's first matching route wins.
default_routes() {
  printf 'label list --repo * --search bug --json name*\t0\t%s\n' "$FAKE_GH_DIR/label-list-empty.json"
  printf 'label create*\t0\t-\n'
}

setup_case() {
  TARGET="$(mktemp -d)"
  FAKE_GH_DIR="$(mktemp -d)"
  ROUTES="$FAKE_GH_DIR/routes.txt"
  BIN="$FAKE_GH_DIR/bin"
  mkdir -p "$BIN"
  ln -s "$SCRIPT_DIR/fake-gh.sh" "$BIN/gh"

  # Label-list replies, written at run time (absolute paths in routes)
  printf '[]\n' > "$FAKE_GH_DIR/label-list-empty.json"
  printf '[{"name":"bug"}]\n' > "$FAKE_GH_DIR/label-list-bug.json"
  printf '[{"name":"bugfix"},{"name":"not-a-bug"}]\n' > "$FAKE_GH_DIR/label-list-near-miss.json"

  # Reset environment between cases
  unset FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT FLEET_BOARD_CONFIG || true
  PATH="$BIN:$ORIG_PATH"
  export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH

  # Run from a neutral directory, so a script that ignores --dir writes elsewhere
  cd "$FAKE_GH_DIR"

  CLEANUP_DIRS+=("$TARGET")
  CLEANUP_DIRS+=("$FAKE_GH_DIR")
}

LABELS_CMD=(--backend github-labels --repo acme/toy --test-one "node --test {file}" --lint "npm run lint" --human-qa-path "src/ui/**")
PROJ_CMD=(--backend github-projects --repo drothschild/HMBWorkout --project 1
  --state "in_progress=In progress" --state "in_review=In review"
  --state "human_qa=Require Human Inteteraction" --state "wont_do=Won't Do")
HEADER='# fleet-board config. Supported YAML subset: see the fleet-board README.'

echo "Test: init.sh"
echo ""

# ---------------------------------------------------------------------------
# AC7.1 labels-writes-valid-config
setup_case
{ cat << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
label create*	0	-
ROUTESEOF
default_routes; } > "$ROUTES"
run_init "${LABELS_CMD[@]}" --dir "$TARGET"
assert_exit "labels-writes-valid-config: exit" 0
if [ -f "$TARGET/.fleet-board.yml" ]; then
  pass "labels-writes-valid-config: file exists"
else
  fail "labels-writes-valid-config: file exists" "no $TARGET/.fleet-board.yml"
fi
FLEET_BOARD_CONFIG="$TARGET/.fleet-board.yml" "$BASH_EXE" "$CONFIG_SH" --check >/dev/null 2>&1
rc=$?
assert_count "labels-writes-valid-config: config.sh --check exits 0" "$rc" 0
assert_cfg "labels-writes-valid-config: commands.test_one" commands.test_one "node --test {file}"
assert_cfg "labels-writes-valid-config: human_qa_paths" human_qa_paths '["src/ui/**"]'
assert_cfg "labels-writes-valid-config: omitted flags left out (commands)" commands '{"test_one":"node --test {file}","lint":"npm run lint"}'
assert_cfg "labels-writes-valid-config: board.backend" board.backend "github-labels"
assert_cfg "labels-writes-valid-config: board.repo" board.repo "acme/toy"
first_line="$(sed -n 1p "$TARGET/.fleet-board.yml" 2>/dev/null)"
assert_count "labels-writes-valid-config: header comment" "$first_line" "$HEADER"
if grep -Fxq '  test_one: "node --test {file}"' "$TARGET/.fleet-board.yml" 2>/dev/null; then
  pass "labels-writes-valid-config: string value double-quoted"
else
  fail "labels-writes-valid-config: string value double-quoted" "no line '  test_one: \"node --test {file}\"'"
fi
if [ ! -f "$TARGET/.fleet-board.yml" ]; then
  fail "labels-writes-valid-config: no keys for omitted flags" "no file"
elif grep -Eq '^(merge|worktrees|typecheck|qa_build):|^  (typecheck|qa_build|setup|dir|project_number|project_owner|states):' "$TARGET/.fleet-board.yml"; then
  fail "labels-writes-valid-config: no keys for omitted flags" "$(cat "$TARGET/.fleet-board.yml")"
else
  pass "labels-writes-valid-config: no keys for omitted flags"
fi
assert_stdout_exact "labels-writes-valid-config: stdout" "wrote $(cd "$TARGET" && pwd)/.fleet-board.yml"
assert_dir_listing "labels-writes-valid-config: no stray temp files" ".fleet-board.yml "

# ---------------------------------------------------------------------------
# AC7.2 labels-creates-all
setup_case
{ cat << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
label list --repo acme/toy --search bug --json name*	0	$FAKE_GH_DIR/label-list-empty.json
label create*	0	-
ROUTESEOF
default_routes; } > "$ROUTES"
run_init "${LABELS_CMD[@]}" --dir "$TARGET"
assert_exit "labels-creates-all: exit" 0

forced="$(calls_of label create | with_arg --force)"
assert_count "labels-creates-all: exactly 9 label create calls with --force" "$(printf '%s\n' "$forced" | count_lines)" 9

n_repo=0
for f in $forced; do file_has_pair "$f" --repo acme/toy && n_repo=$((n_repo + 1)); done
assert_count "labels-creates-all: all 9 --force creates carry --repo acme/toy" "$n_repo" 9

got_names="$(for f in $forced; do sed -n 3p "$f"; done | sort | tr '\n' ' ')"
want_names="$(printf '%s\n' fleet:backlog fleet:ready fleet:in_progress fleet:in_review fleet:human_qa fleet:blocked fleet:done fleet:wont_do needs-human-qa | sort | tr '\n' ' ')"
assert_count "labels-creates-all: names are the 8 fleet:<state> labels plus needs-human-qa" "$got_names" "$want_names"

bad=""
for pair in backlog:cfd3d7 ready:0e8a16 in_progress:1d76db in_review:5319e7 human_qa:fbca04 blocked:b60205 done:0e8a16 wont_do:ffffff; do
  s="${pair%%:*}"; c="${pair#*:}"
  f="$(label_creates_named "fleet:$s" | head -n 1)"
  if [ -z "$f" ] || ! file_has_pair "$f" --color "$c" || ! file_has_pair "$f" --description "fleet-board state: $s"; then
    bad="$bad fleet:$s"
  fi
done
f="$(label_creates_named needs-human-qa | head -n 1)"
if [ -z "$f" ] || ! file_has_pair "$f" --color d93f0b || ! file_has_pair "$f" --description "fleet-board: route to Human QA"; then
  bad="$bad needs-human-qa"
fi
assert_count "labels-creates-all: colors and descriptions" "$bad" ""

bug_creates="$(label_creates_named bug)"
assert_count "labels-creates-all: exactly one label create bug" "$(printf '%s\n' "$bug_creates" | count_lines)" 1
assert_count "labels-creates-all: label create bug has no --force" "$(printf '%s\n' "$bug_creates" | with_arg --force | count_lines)" 0
f="$(printf '%s\n' "$bug_creates" | head -n 1)"
if [ -n "$f" ] && file_has_pair "$f" --repo acme/toy && file_has_pair "$f" --color d73a4a \
   && file_has_pair "$f" --description "Something isn't working"; then
  pass "labels-creates-all: label create bug --repo acme/toy, color and description"
else
  fail "labels-creates-all: label create bug --repo acme/toy, color and description" "call: $(tr '\n' ' ' < "${f:-/dev/null}")"
fi
lists="$(calls_of label list)"
assert_count "labels-creates-all: one bug label check" "$(printf '%s\n' "$lists" | count_lines)" 1
f="$(printf '%s\n' "$lists" | head -n 1)"
if [ -n "$f" ] && file_has_pair "$f" --repo acme/toy && file_has_pair "$f" --search bug && file_has_pair "$f" --json name \
   && file_has_pair "$f" --limit 1000; then
  pass "labels-creates-all: bug check is label list --repo acme/toy --search bug --json name --limit 1000"
else
  fail "labels-creates-all: bug check is label list --repo acme/toy --search bug --json name --limit 1000" "call: $(tr '\n' ' ' < "${f:-/dev/null}")"
fi
last_forced="$(printf '%s\n' "$forced" | tail -n 1)"
if [ -n "$f" ] && [ -n "$last_forced" ] && [ "$(seq_of "$f")" -gt "$(seq_of "$last_forced")" ]; then
  pass "labels-creates-all: bug check runs after the state labels"
else
  fail "labels-creates-all: bug check runs after the state labels" "list=$f last forced create=$last_forced"
fi

# ---------------------------------------------------------------------------
# AC3.10 bug-label-kept-if-present
setup_case
{ cat << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
label list --repo acme/toy --search bug --json name*	0	$FAKE_GH_DIR/label-list-bug.json
label create*	0	-
ROUTESEOF
default_routes; } > "$ROUTES"
run_init "${LABELS_CMD[@]}" --dir "$TARGET"
assert_exit "bug-label-kept-if-present: exit" 0
assert_count "bug-label-kept-if-present: bug label was checked" "$(calls_of label list | count_lines)" 1
assert_count "bug-label-kept-if-present: no label create bug" "$(label_creates_named bug | count_lines)" 0
assert_count "bug-label-kept-if-present: no label edit" "$(calls_of label edit | count_lines)" 0
assert_count "bug-label-kept-if-present: state labels still created" "$(calls_of label create | with_arg --force | count_lines)" 9
if [ -f "$TARGET/.fleet-board.yml" ]; then
  pass "bug-label-kept-if-present: config written"
else
  fail "bug-label-kept-if-present: config written" "no file"
fi

# AC3.10 bug-label-near-miss: labels merely matching the search are not "bug"
setup_case
{ cat << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
label list --repo acme/toy --search bug --json name*	0	$FAKE_GH_DIR/label-list-near-miss.json
ROUTESEOF
default_routes; } > "$ROUTES"
run_init "${LABELS_CMD[@]}" --dir "$TARGET"
assert_exit "bug-label-near-miss: exit" 0
assert_count "bug-label-near-miss: label create bug once" "$(label_creates_named bug | count_lines)" 1

# ---------------------------------------------------------------------------
# AC3.10 bug-label-list-fails
setup_case
{ cat << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
label list*	1	-
ROUTESEOF
default_routes; } > "$ROUTES"
run_init "${LABELS_CMD[@]}" --dir "$TARGET"
assert_exit "bug-label-list-fails: exit" 1
assert_stderr_contains "bug-label-list-fails: stderr" "cannot check bug label"
assert_no_config "bug-label-list-fails: no .fleet-board.yml written"
assert_dir_listing "bug-label-list-fails: no stray temp files" ""
assert_count "bug-label-list-fails: no label create bug" "$(label_creates_named bug | count_lines)" 0

# AC3.10 bug-label-create-fails
setup_case
{ cat << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
label create bug *	1	-
ROUTESEOF
default_routes; } > "$ROUTES"
run_init "${LABELS_CMD[@]}" --dir "$TARGET"
assert_exit "bug-label-create-fails: exit" 1
assert_stderr_contains "bug-label-create-fails: stderr" "cannot check bug label"
assert_no_config "bug-label-create-fails: no .fleet-board.yml written"
assert_dir_listing "bug-label-create-fails: no stray temp files" ""

# state-label-create-fails
setup_case
{ cat << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
label create fleet:ready *	1	-
ROUTESEOF
default_routes; } > "$ROUTES"
run_init "${LABELS_CMD[@]}" --dir "$TARGET"
assert_exit "state-label-create-fails: exit" 1
assert_stderr_contains "state-label-create-fails: stderr names the label" "fleet:ready"
assert_no_config "state-label-create-fails: no .fleet-board.yml written"
assert_dir_listing "state-label-create-fails: no stray temp files" ""

# labels-state-override: label names come from board.states
setup_case
{ cat << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
ROUTESEOF
default_routes; } > "$ROUTES"
run_init "${LABELS_CMD[@]}" --state "ready=fleet:todo" --dir "$TARGET"
assert_exit "labels-state-override: exit" 0
assert_count "labels-state-override: creates fleet:todo" "$(label_creates_named fleet:todo | with_arg --force | count_lines)" 1
assert_count "labels-state-override: no fleet:ready" "$(label_creates_named fleet:ready | count_lines)" 0
f="$(label_creates_named fleet:todo | head -n 1)"
if [ -n "$f" ] && file_has_pair "$f" --description "fleet-board state: ready" && file_has_pair "$f" --color 0e8a16; then
  pass "labels-state-override: fleet:todo described as state ready"
else
  fail "labels-state-override: fleet:todo described as state ready" "call: $(tr '\n' ' ' < "${f:-/dev/null}")"
fi
assert_cfg "labels-state-override: board.states.ready" board.states.ready "fleet:todo"

# ---------------------------------------------------------------------------
# AC7.2 projects-verifies-options-ok
setup_case
{ cat << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list-with-blocked.json
label create*	0	-
ROUTESEOF
default_routes; } > "$ROUTES"
run_init "${PROJ_CMD[@]}" --dir "$TARGET"
assert_exit "projects-verifies-options-ok: exit" 0
FLEET_BOARD_CONFIG="$TARGET/.fleet-board.yml" "$BASH_EXE" "$CONFIG_SH" --check >/dev/null 2>&1
rc=$?
assert_count "projects-verifies-options-ok: config.sh --check exits 0" "$rc" 0
assert_cfg "projects-verifies-options-ok: board.backend" board.backend "github-projects"
assert_cfg "projects-verifies-options-ok: board.project_number" board.project_number "1"
assert_cfg "projects-verifies-options-ok: board.states" board.states \
  '{"in_progress":"In progress","in_review":"In review","human_qa":"Require Human Inteteraction","wont_do":"Won'"'"'t Do"}'
assert_count "projects-verifies-options-ok: field-list called once" "$(calls_of project field-list | count_lines)" 1
f="$(calls_of project field-list | head -n 1)"
if [ -n "$f" ] && [ "$(sed -n 3p "$f")" = "1" ] && file_has_pair "$f" --owner drothschild && file_has_pair "$f" --format json; then
  pass "projects-verifies-options-ok: field-list 1 --owner drothschild --format json"
else
  fail "projects-verifies-options-ok: field-list 1 --owner drothschild --format json" "call: $(tr '\n' ' ' < "${f:-/dev/null}")"
fi
fl="$f"
n_fleet=0
for f in $(calls_of label create); do
  case "$(sed -n 3p "$f")" in fleet:*) n_fleet=$((n_fleet + 1)) ;; esac
done
assert_count "projects-verifies-options-ok: no label create fleet:*" "$n_fleet" 0
nhq="$(label_creates_named needs-human-qa)"
assert_count "projects-verifies-options-ok: exactly one label create needs-human-qa" "$(printf '%s\n' "$nhq" | count_lines)" 1
f="$(printf '%s\n' "$nhq" | head -n 1)"
if [ -n "$f" ] && file_has_pair "$f" --repo drothschild/HMBWorkout && grep -Fxq -- --force "$f" \
   && file_has_pair "$f" --color d93f0b && file_has_pair "$f" --description "fleet-board: route to Human QA"; then
  pass "projects-verifies-options-ok: needs-human-qa create args"
else
  fail "projects-verifies-options-ok: needs-human-qa create args" "call: $(tr '\n' ' ' < "${f:-/dev/null}")"
fi
if [ -n "$f" ] && [ -n "$fl" ] && [ "$(seq_of "$f")" -gt "$(seq_of "$fl")" ]; then
  pass "projects-verifies-options-ok: needs-human-qa created after options verify"
else
  fail "projects-verifies-options-ok: needs-human-qa created after options verify" "field-list=$fl create=$f"
fi
lists="$(calls_of label list)"
assert_count "projects-verifies-options-ok: one bug label check" "$(printf '%s\n' "$lists" | count_lines)" 1
f="$(printf '%s\n' "$lists" | head -n 1)"
if [ -n "$f" ] && file_has_pair "$f" --repo drothschild/HMBWorkout && file_has_pair "$f" --search bug && file_has_pair "$f" --json name \
   && file_has_pair "$f" --limit 1000; then
  pass "projects-verifies-options-ok: bug check args"
else
  fail "projects-verifies-options-ok: bug check args" "call: $(tr '\n' ' ' < "${f:-/dev/null}")"
fi
bug_creates="$(label_creates_named bug)"
assert_count "projects-verifies-options-ok: exactly one label create bug" "$(printf '%s\n' "$bug_creates" | count_lines)" 1
assert_count "projects-verifies-options-ok: label create bug has no --force" "$(printf '%s\n' "$bug_creates" | with_arg --force | count_lines)" 0
assert_count "projects-verifies-options-ok: label creates total" "$(calls_of label create | count_lines)" 2

# projects-owner-flag: --owner overrides the repo owner
setup_case
{ cat << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
project field-list 1 --owner some-org --format json*	0	$FIXTURES/projects/field-list-with-blocked.json
ROUTESEOF
default_routes; } > "$ROUTES"
run_init "${PROJ_CMD[@]}" --owner some-org --dir "$TARGET"
assert_exit "projects-owner-flag: exit" 0
f="$(calls_of project field-list | head -n 1)"
if [ -n "$f" ] && file_has_pair "$f" --owner some-org; then
  pass "projects-owner-flag: field-list --owner some-org"
else
  fail "projects-owner-flag: field-list --owner some-org" "call: $(tr '\n' ' ' < "${f:-/dev/null}")"
fi
assert_cfg "projects-owner-flag: board.project_owner" board.project_owner "some-org"

# ---------------------------------------------------------------------------
# AC7.2 projects-missing-option
setup_case
{ cat << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list.json
ROUTESEOF
default_routes; } > "$ROUTES"
run_init "${PROJ_CMD[@]}" --dir "$TARGET"
assert_exit "projects-missing-option: exit" 1
assert_stderr_contains "projects-missing-option: stderr names Blocked" "Blocked"
assert_stderr_contains "projects-missing-option: stderr hint" "add it in the project's Status field or map it with --state blocked=<Name>"
assert_stderr_line "projects-missing-option: full message" \
  "fleet-board init: project 1 Status field lacks option(s): Blocked; add it in the project's Status field or map it with --state blocked=<Name>"
assert_no_config "projects-missing-option: no .fleet-board.yml written"
assert_dir_listing "projects-missing-option: no stray temp files" ""
assert_count "projects-missing-option: no label create calls" "$(calls_of label create | count_lines)" 0

# projects-no-status-field
setup_case
{ cat << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list-no-status.json
ROUTESEOF
default_routes; } > "$ROUTES"
run_init "${PROJ_CMD[@]}" --dir "$TARGET"
assert_exit "projects-no-status-field: exit" 1
assert_stderr_contains "projects-no-status-field: stderr" "has no Status field"
assert_no_config "projects-no-status-field: no .fleet-board.yml written"

# projects-field-list-fails
setup_case
{ cat << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
project field-list*	1	-
ROUTESEOF
default_routes; } > "$ROUTES"
run_init "${PROJ_CMD[@]}" --dir "$TARGET"
assert_exit "projects-field-list-fails: exit" 1
assert_stderr_contains "projects-field-list-fails: stderr" "cannot read the fields of project 1"
assert_no_config "projects-field-list-fails: no .fleet-board.yml written"
assert_count "projects-field-list-fails: no label create calls" "$(calls_of label create | count_lines)" 0

# ---------------------------------------------------------------------------
# AC7.3 missing-project-scope
setup_case
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-no-project.txt
ROUTESEOF
run_init "${PROJ_CMD[@]}" --dir "$TARGET"
assert_exit "missing-project-scope: exit" 1
assert_stderr_line "missing-project-scope: stderr has exactly 'Run: gh auth refresh -s project'" "Run: gh auth refresh -s project"
assert_stderr_line "missing-project-scope: names the missing scope" "fleet-board init: gh token is missing scope(s): project"
assert_no_config "missing-project-scope: no .fleet-board.yml written"
assert_dir_listing "missing-project-scope: no stray temp files" ""
assert_count "missing-project-scope: only gh auth status was called" "$(all_calls | count_lines)" 1

# ---------------------------------------------------------------------------
# AC7.3 missing-repo-scope
setup_case
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-no-repo.txt
ROUTESEOF
run_init "${LABELS_CMD[@]}" --dir "$TARGET"
assert_exit "missing-repo-scope: exit" 1
assert_stderr_contains "missing-repo-scope: stderr" "gh auth refresh -s repo"
assert_stderr_line "missing-repo-scope: exact refresh line" "Run: gh auth refresh -s repo"
assert_no_config "missing-repo-scope: no .fleet-board.yml written"
assert_dir_listing "missing-repo-scope: no stray temp files" ""
assert_count "missing-repo-scope: only gh auth status was called" "$(all_calls | count_lines)" 1

# missing-both-scopes: comma-joined refresh list
setup_case
sed -e "s/'project', //" -e "s/'repo', //" "$FIXTURES/projects/auth-status-ok.txt" > "$FAKE_GH_DIR/auth-none.txt"
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FAKE_GH_DIR/auth-none.txt
ROUTESEOF
run_init "${PROJ_CMD[@]}" --dir "$TARGET"
assert_exit "missing-both-scopes: exit" 1
assert_stderr_line "missing-both-scopes: refresh line" "Run: gh auth refresh -s repo,project"
assert_no_config "missing-both-scopes: no .fleet-board.yml written"

# gh-not-logged-in: gh auth status fails with no scopes line; stop with gh's message
setup_case
{ cat << ROUTESEOF
auth status	1	$FIXTURES/projects/auth-status-not-logged-in.txt
ROUTESEOF
default_routes; } > "$ROUTES"
run_init "${LABELS_CMD[@]}" --dir "$TARGET"
assert_exit "gh-not-logged-in: exit" 1
assert_stderr_contains "gh-not-logged-in: init message" "fleet-board init:"
assert_stderr_contains "gh-not-logged-in: gh's message" "You are not logged into any GitHub hosts"
assert_no_config "gh-not-logged-in: no .fleet-board.yml written"
assert_count "gh-not-logged-in: only gh auth status was called" "$(all_calls | count_lines)" 1

# multi-account: only the ACTIVE account's scopes count, in either listing order
for fx in auth-status-multi-active-first auth-status-multi-inactive-first; do
  setup_case
  cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/$fx.txt
ROUTESEOF
  run_init "${PROJ_CMD[@]}" --dir "$TARGET"
  assert_exit "multi-account $fx: exit" 1
  assert_stderr_line "multi-account $fx: refresh line" "Run: gh auth refresh -s project"
  assert_no_config "multi-account $fx: no .fleet-board.yml written"
  assert_count "multi-account $fx: only gh auth status was called" "$(all_calls | count_lines)" 1
done

# multi-account-active-ok: the active account has 'project', an inactive one lacks it
setup_case
{ cat << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-multi-active-ok.txt
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list-with-blocked.json
ROUTESEOF
default_routes; } > "$ROUTES"
run_init "${PROJ_CMD[@]}" --dir "$TARGET"
assert_exit "multi-account-active-ok: exit" 0

# auth-status-nonzero-but-scoped: gh exits 1 (e.g. another account's token is
# bad) yet shows the active account's scopes; the exit status alone is not fatal
setup_case
{ cat << ROUTESEOF
auth status	1	$FIXTURES/projects/auth-status-multi-active-ok.txt
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list-with-blocked.json
ROUTESEOF
default_routes; } > "$ROUTES"
run_init "${PROJ_CMD[@]}" --dir "$TARGET"
assert_exit "auth-status-nonzero-but-scoped: exit" 0
assert_cfg "auth-status-nonzero-but-scoped: config written" board.project_number "1"

# multi-host: only github.com's active account counts. Another host's active
# account, listed first, has 'project'; github.com's lacks it.
setup_case
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-multi-host.txt
ROUTESEOF
run_init "${PROJ_CMD[@]}" --dir "$TARGET"
assert_exit "multi-host: exit" 1
assert_stderr_line "multi-host: refresh line" "Run: gh auth refresh -s project"
assert_no_config "multi-host: no .fleet-board.yml written"
assert_count "multi-host: only gh auth status was called" "$(all_calls | count_lines)" 1

# multi-host-ok: github.com's active account has 'project'; the other host's,
# listed first, lacks it
setup_case
{ cat << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-multi-host-ok.txt
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list-with-blocked.json
ROUTESEOF
default_routes; } > "$ROUTES"
run_init "${PROJ_CMD[@]}" --dir "$TARGET"
assert_exit "multi-host-ok: exit" 0
assert_cfg "multi-host-ok: config written" board.project_number "1"

# legacy-unquoted: older gh lists scopes unquoted (Token scopes: repo, project)
setup_case
{ cat << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-legacy-unquoted.txt
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list-with-blocked.json
ROUTESEOF
default_routes; } > "$ROUTES"
run_init "${PROJ_CMD[@]}" --dir "$TARGET"
assert_exit "legacy-unquoted: exit" 0
assert_cfg "legacy-unquoted: config written" board.project_number "1"

# scope-listed-first: gh sorts scopes, so a minimal token lists the required one first
setup_case
sed "s/'gist', //" "$FIXTURES/projects/auth-status-ok.txt" > "$FAKE_GH_DIR/auth.txt"
{ cat << ROUTESEOF
auth status	0	$FAKE_GH_DIR/auth.txt
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list-with-blocked.json
ROUTESEOF
default_routes; } > "$ROUTES"
run_init "${PROJ_CMD[@]}" --dir "$TARGET"
assert_exit "scope-listed-first projects: exit" 0
assert_cfg "scope-listed-first projects: config written" board.project_number "1"
setup_case
sed "s/'gist', 'project', 'read:org', //" "$FIXTURES/projects/auth-status-ok.txt" > "$FAKE_GH_DIR/auth.txt"
{ cat << ROUTESEOF
auth status	0	$FAKE_GH_DIR/auth.txt
ROUTESEOF
default_routes; } > "$ROUTES"
run_init "${LABELS_CMD[@]}" --dir "$TARGET"
assert_exit "scope-listed-first labels: exit" 0
assert_cfg "scope-listed-first labels: config written" board.backend "github-labels"

# legacy-unquoted-no-repo: unquoted scopes without repo are refused
setup_case
sed 's/ repo,//' "$FIXTURES/projects/auth-status-legacy-unquoted.txt" > "$FAKE_GH_DIR/auth.txt"
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FAKE_GH_DIR/auth.txt
ROUTESEOF
run_init "${LABELS_CMD[@]}" --dir "$TARGET"
assert_exit "legacy-unquoted-no-repo: exit" 1
assert_stderr_line "legacy-unquoted-no-repo: refresh line" "Run: gh auth refresh -s repo"
assert_no_config "legacy-unquoted-no-repo: no .fleet-board.yml written"

# legacy-unquoted-read-project: read:project is not project
setup_case
sed 's/ project,/ read:project,/' "$FIXTURES/projects/auth-status-legacy-unquoted.txt" > "$FAKE_GH_DIR/auth.txt"
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FAKE_GH_DIR/auth.txt
ROUTESEOF
run_init "${PROJ_CMD[@]}" --dir "$TARGET"
assert_exit "legacy-unquoted-read-project: exit" 1
assert_stderr_line "legacy-unquoted-read-project: refresh line" "Run: gh auth refresh -s project"
assert_no_config "legacy-unquoted-read-project: no .fleet-board.yml written"

# no-scopes-line: fine-grained tokens print no scopes line; init continues
setup_case
grep -v 'Token scopes:' "$FIXTURES/projects/auth-status-ok.txt" > "$FAKE_GH_DIR/auth-noline.txt"
{ cat << ROUTESEOF
auth status	0	$FAKE_GH_DIR/auth-noline.txt
ROUTESEOF
default_routes; } > "$ROUTES"
run_init "${LABELS_CMD[@]}" --dir "$TARGET"
assert_exit "no-scopes-line: exit" 0
if [ -f "$TARGET/.fleet-board.yml" ]; then
  pass "no-scopes-line: config written"
else
  fail "no-scopes-line: config written" "no file"
fi

# ---------------------------------------------------------------------------
# AC7.3 unrenderable-value
setup_case
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
ROUTESEOF
run_init --backend github-labels --repo acme/toy --test-one "echo \"a\" 'b' {file}" --dir "$TARGET"
assert_exit "unrenderable-value: exit" 1
assert_stderr_contains "unrenderable-value: stderr names --test-one" "--test-one"
assert_no_config "unrenderable-value: no .fleet-board.yml written"
assert_dir_listing "unrenderable-value: no stray temp files" ""
assert_count "unrenderable-value: no label calls" "$(calls_of label create | count_lines)" 0

# unrenderable-newline
setup_case
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
ROUTESEOF
run_init --backend github-labels --repo acme/toy --lint "$(printf 'npm run lint\nrm -rf /')" --dir "$TARGET"
assert_exit "unrenderable-newline: exit" 1
assert_stderr_contains "unrenderable-newline: stderr names --lint" "--lint"
assert_no_config "unrenderable-newline: no .fleet-board.yml written"

# unrenderable-state: check_value covers --state values
setup_case
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
ROUTESEOF
run_init --backend github-labels --repo acme/toy --state "ready=a\"b'c" --dir "$TARGET"
assert_exit "unrenderable-state: exit" 1
assert_stderr_contains "unrenderable-state: check_value names --state" "--state value contains both"
assert_no_config "unrenderable-state: no .fleet-board.yml written"
assert_dir_listing "unrenderable-state: no stray temp files" ""
assert_count "unrenderable-state: no label calls" "$(calls_of label create | count_lines)" 0

# unrenderable-qa-path: check_value covers --human-qa-path values
setup_case
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
ROUTESEOF
run_init --backend github-labels --repo acme/toy --human-qa-path "$(printf 'src/ui/**\nsrc/x')" --dir "$TARGET"
assert_exit "unrenderable-qa-path: exit" 1
assert_stderr_contains "unrenderable-qa-path: check_value names --human-qa-path" "--human-qa-path value contains a newline"
assert_no_config "unrenderable-qa-path: no .fleet-board.yml written"
assert_dir_listing "unrenderable-qa-path: no stray temp files" ""
assert_count "unrenderable-qa-path: no label calls" "$(calls_of label create | count_lines)" 0

# renders-double-quote-value: a value with " is single-quoted
setup_case
{ cat << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
ROUTESEOF
default_routes; } > "$ROUTES"
run_init --backend github-labels --repo acme/toy --lint 'npm run lint -- --format "stylish"' --dir "$TARGET"
assert_exit "renders-double-quote-value: exit" 0
assert_cfg "renders-double-quote-value: commands.lint round-trips" commands.lint 'npm run lint -- --format "stylish"'
if grep -Fxq "  lint: 'npm run lint -- --format \"stylish\"'" "$TARGET/.fleet-board.yml" 2>/dev/null; then
  pass "renders-double-quote-value: single-quoted in the file"
else
  fail "renders-double-quote-value: single-quoted in the file" "$(cat "$TARGET/.fleet-board.yml" 2>/dev/null)"
fi

# renders-all-flags
setup_case
{ cat << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list-with-blocked.json
ROUTESEOF
default_routes; } > "$ROUTES"
run_init "${PROJ_CMD[@]}" --owner drothschild \
  --test-one "npm test -- {file}" --typecheck "npx tsc --noEmit" --lint "npm run lint" --qa-build "scripts/qa, build.sh" \
  --worktrees-dir "../.wt #1" --setup "npm ci" --human-qa-path "src/app/**" --human-qa-path "src/{a,b}/**" \
  --merge auto --dir "$TARGET"
assert_exit "renders-all-flags: exit" 0
assert_cfg "renders-all-flags: commands" commands \
  '{"test_one":"npm test -- {file}","typecheck":"npx tsc --noEmit","lint":"npm run lint","qa_build":"scripts/qa, build.sh"}'
assert_cfg "renders-all-flags: worktrees.dir" worktrees.dir "../.wt #1"
assert_cfg "renders-all-flags: worktrees.setup" worktrees.setup "npm ci"
assert_cfg "renders-all-flags: worktrees.mutate_on_copy default kept" worktrees.mutate_on_copy "false"
assert_cfg "renders-all-flags: human_qa_paths" human_qa_paths '["src/app/**","src/{a,b}/**"]'
assert_cfg "renders-all-flags: merge.policy" merge.policy "auto"
assert_cfg "renders-all-flags: board.project_owner" board.project_owner "drothschild"

# invalid-config-rejected: a rendered config config.sh --check refuses
setup_case
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
ROUTESEOF
run_init --backend github-labels --repo acme/toy --merge sometimes --dir "$TARGET"
assert_exit "invalid-config-rejected: exit" 1
assert_stderr_contains "invalid-config-rejected: shows config.sh's error" "merge.policy must be human or auto"
assert_no_config "invalid-config-rejected: no .fleet-board.yml written"
assert_dir_listing "invalid-config-rejected: no stray temp files" ""
assert_count "invalid-config-rejected: no label calls" "$(calls_of label create | count_lines)" 0

# ---------------------------------------------------------------------------
# refuses-overwrite
setup_case
{ cat << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
ROUTESEOF
default_routes; } > "$ROUTES"
printf 'board:\n  repo: old/repo\n' > "$TARGET/.fleet-board.yml"
cp "$TARGET/.fleet-board.yml" "$FAKE_GH_DIR/before.yml"
run_init "${LABELS_CMD[@]}" --dir "$TARGET"
assert_exit "refuses-overwrite: exit without --force" 1
assert_stderr_contains "refuses-overwrite: stderr mentions --force" "--force"
if cmp -s "$TARGET/.fleet-board.yml" "$FAKE_GH_DIR/before.yml"; then
  pass "refuses-overwrite: file byte-identical"
else
  fail "refuses-overwrite: file byte-identical" "file changed"
fi
assert_dir_listing "refuses-overwrite: no stray temp files" ".fleet-board.yml "
assert_count "refuses-overwrite: no label calls" "$(calls_of label create | count_lines)" 0
run_init "${LABELS_CMD[@]}" --dir "$TARGET" --force
assert_exit "refuses-overwrite: exit with --force" 0
assert_cfg "refuses-overwrite: --force replaced the file" board.repo "acme/toy"
assert_dir_listing "refuses-overwrite: no stray temp files after --force" ".fleet-board.yml "

# ---------------------------------------------------------------------------
# default-dir: without --dir, the config goes to the git root
setup_case
git init -q "$TARGET"
mkdir -p "$TARGET/sub/dir"
{ cat << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
ROUTESEOF
default_routes; } > "$ROUTES"
cd "$TARGET/sub/dir"
run_init "${LABELS_CMD[@]}"
cd "$FAKE_GH_DIR"
assert_exit "default-dir: exit" 0
if [ -f "$TARGET/.fleet-board.yml" ] && [ ! -e "$TARGET/sub/dir/.fleet-board.yml" ]; then
  pass "default-dir: written at the git root"
else
  fail "default-dir: written at the git root" "$(ls -A "$TARGET" "$TARGET/sub/dir" 2>&1 | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# cdpath-relative-dir: with CDPATH exported and a same-named directory in it,
# a relative --dir still means the directory under $PWD. (cd would go to the
# CDPATH one and echo its path, so a captured $(cd ... && pwd) had two lines.)
setup_case
mkdir -p "$TARGET/parent/proj" "$TARGET/decoy/proj"
{ cat << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
ROUTESEOF
default_routes; } > "$ROUTES"
cd "$TARGET/parent"
export CDPATH="$TARGET/decoy"
run_init "${LABELS_CMD[@]}" --dir proj
unset CDPATH
cd "$FAKE_GH_DIR"
assert_exit "cdpath-relative-dir: exit" 0
if [ -f "$TARGET/parent/proj/.fleet-board.yml" ]; then
  pass "cdpath-relative-dir: written in the relative --dir"
else
  fail "cdpath-relative-dir: written in the relative --dir" "no $TARGET/parent/proj/.fleet-board.yml"
fi
assert_count "cdpath-relative-dir: CDPATH directory untouched" "$(ls -A "$TARGET/decoy/proj" | count_lines)" 0
assert_stdout_exact "cdpath-relative-dir: stdout" "wrote $(cd "$TARGET/parent/proj" && pwd)/.fleet-board.yml"

# cdpath-relative-script: init.sh run by a relative path still finds its own
# directory when CDPATH holds a same-named "scripts" directory
setup_case
mkdir -p "$FAKE_GH_DIR/decoy/scripts"
{ cat << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
ROUTESEOF
default_routes; } > "$ROUTES"
cd "$SCRIPT_DIR/.."
export CDPATH="$FAKE_GH_DIR/decoy"
run_check scripts/init.sh "${LABELS_CMD[@]}" --dir "$TARGET"
unset CDPATH
cd "$FAKE_GH_DIR"
assert_exit "cdpath-relative-script: exit" 0
assert_cfg "cdpath-relative-script: config written" board.repo "acme/toy"

# ---------------------------------------------------------------------------
# env-not-inherited: init.sh reads only its flags. Every global name the script
# uses is preset in the environment with a poison value; none may reach the
# rendered file or change what init does.
POISON_ENV=(
  OWNER=POISON-owner TEST_ONE="POISON test" TYPECHECK="POISON tsc" LINT="rm -rf ~ POISON"
  QA_BUILD="POISON build" WT_DIR=/tmp/POISON-wt WT_SETUP="POISON setup" MERGE=auto
  BACKEND=POISON-backend REPO=POISON/repo PROJECT=99 DIR=/tmp/POISON-dir FORCE=1
  STATE_KEYS=ready STATE_VALS=POISON-col QA_PATHS="POISON/**" OWNER_EFF=POISON-owner-eff
  TARGET=/tmp/POISON-target TMP=/tmp/POISON-tmp ERR=POISON FLEET_CFG='{"board":{"project_owner":"POISON"}}'
  OUT=POISON RC=POISON SCOPES=POISON REQUIRED=POISON MISSING=POISON FIELDS=POISON HAS_STATUS=POISON
  OPTIONS=POISON LACKING=POISON HINT=POISON BUGS=POISON HAS_BUG=POISON FB_STATES=POISON
  CANONICAL=POISON HEADER=POISON NL=POISON HERE=/tmp/POISON-here
  FBI_OWNER=POISON-fbi-owner FBI_TEST_ONE="POISON fbi test" FBI_TYPECHECK="POISON fbi tsc"
  FBI_LINT="POISON fbi lint" FBI_QA_BUILD="POISON fbi build" FBI_WT_DIR=/tmp/POISON-fbi-wt
  FBI_WT_SETUP="POISON fbi setup" FBI_MERGE=auto
)

# run_init_poisoned <args>: run init.sh with POISON_ENV in its environment
run_init_poisoned() {
  local tmpout tmperr
  tmpout="$(mktemp)"
  tmperr="$(mktemp)"
  env "${POISON_ENV[@]}" "$BASH_EXE" "$SCRIPT" "$@" > "$tmpout" 2> "$tmperr"
  LAST_EXIT=$?
  LAST_OUT="$(cat "$tmpout")"
  LAST_ERR="$(cat "$tmperr")"
  rm -f "$tmpout" "$tmperr"
}

# env-not-inherited (labels): the file holds only what the flags gave
setup_case
{ cat << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
ROUTESEOF
default_routes; } > "$ROUTES"
run_init_poisoned --backend github-labels --repo acme/toy --dir "$TARGET"
assert_exit "env-not-inherited labels: exit" 0
want="$(printf '%s\n' "$HEADER" 'board:' '  backend: "github-labels"' '  repo: "acme/toy"')"
got="$(cat "$TARGET/.fleet-board.yml" 2>/dev/null)"
assert_count "env-not-inherited labels: file is exactly the flags' config" "$got" "$want"
assert_count "env-not-inherited labels: no POISON in the file" "$(grep -c POISON "$TARGET/.fleet-board.yml" 2>/dev/null)" 0
assert_count "env-not-inherited labels: 9 label creates with --force" "$(calls_of label create | with_arg --force | count_lines)" 9
assert_count "env-not-inherited labels: no POISON in any gh call" "$(cat "$FAKE_GH_DIR"/argv/* 2>/dev/null | grep -c POISON)" 0

# env-not-inherited (projects): field-list uses the repo owner, not $OWNER
setup_case
{ cat << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list-with-blocked.json
ROUTESEOF
default_routes; } > "$ROUTES"
run_init_poisoned "${PROJ_CMD[@]}" --dir "$TARGET"
assert_exit "env-not-inherited projects: exit" 0
f="$(calls_of project field-list | head -n 1)"
if [ -n "$f" ] && file_has_pair "$f" --owner drothschild; then
  pass "env-not-inherited projects: field-list --owner drothschild"
else
  fail "env-not-inherited projects: field-list --owner drothschild" "call: $(tr '\n' ' ' < "${f:-/dev/null}")"
fi
assert_cfg "env-not-inherited projects: no board.project_owner" board.project_owner ""
assert_cfg "env-not-inherited projects: board.states from flags only" board.states \
  '{"in_progress":"In progress","in_review":"In review","human_qa":"Require Human Inteteraction","wont_do":"Won'"'"'t Do"}'
assert_count "env-not-inherited projects: no POISON in the file" "$(grep -c POISON "$TARGET/.fleet-board.yml" 2>/dev/null)" 0
assert_count "env-not-inherited projects: no commands, worktrees, merge or human_qa_paths" \
  "$(grep -cE '^(commands|worktrees|merge|human_qa_paths):' "$TARGET/.fleet-board.yml" 2>/dev/null)" 0

# env-not-inherited (FORCE): FORCE=1 in the environment is not --force
setup_case
{ cat << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
ROUTESEOF
default_routes; } > "$ROUTES"
printf 'board:\n  repo: old/repo\n' > "$TARGET/.fleet-board.yml"
cp "$TARGET/.fleet-board.yml" "$FAKE_GH_DIR/before.yml"
run_init_poisoned --backend github-labels --repo acme/toy --dir "$TARGET"
assert_exit "env-not-inherited force: exit" 1
if cmp -s "$TARGET/.fleet-board.yml" "$FAKE_GH_DIR/before.yml"; then
  pass "env-not-inherited force: file byte-identical"
else
  fail "env-not-inherited force: file byte-identical" "file changed"
fi

# ---------------------------------------------------------------------------
# usage-errors: exit 2, no gh calls, nothing written
setup_case
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
ROUTESEOF
run_init --repo acme/toy --dir "$TARGET"
assert_exit "usage-errors: missing --backend" 2
run_init --backend github-labels --dir "$TARGET"
assert_exit "usage-errors: missing --repo" 2
run_init --backend github-projects --repo acme/toy --dir "$TARGET"
assert_exit "usage-errors: projects without --project" 2
run_init --backend jira --repo acme/toy --dir "$TARGET"
assert_exit "usage-errors: unknown backend" 2
run_init --backend github-labels --repo acme/toy --bogus --dir "$TARGET"
assert_exit "usage-errors: unknown flag" 2
run_init --backend github-labels --repo acme/toy --state "ready" --dir "$TARGET"
assert_exit "usage-errors: --state without =" 2
run_init --backend github-labels --repo acme/toy --state "ready: \"x\", done=Y" --dir "$TARGET"
assert_exit "usage-errors: --state with a non-canonical key" 2
run_init --backend github-projects --repo acme/toy --project one --dir "$TARGET"
assert_exit "usage-errors: non-numeric --project" 2
run_init --backend github-labels --repo acme/toy --state "ready=fleet:a" --state "ready=fleet:b" --dir "$TARGET"
assert_exit "usage-errors: duplicate --state key" 2
assert_stderr_contains "usage-errors: duplicate --state key named" "--state ready given more than once"
run_init --backend github-labels --repo acme/toy --state "ready=" --dir "$TARGET"
assert_exit "usage-errors: empty --state value" 2
assert_stderr_contains "usage-errors: empty --state value named" "--state ready needs a column name"
run_init --backend github-labels --repo acme/toy --lint
assert_exit "usage-errors: flag without a value" 2
run_init --backend github-labels --repo acme/toy --dir "$TARGET/nope"
assert_exit "usage-errors: --dir that does not exist" 2
assert_count "usage-errors: no gh calls" "$(all_calls | count_lines)" 0
assert_dir_listing "usage-errors: nothing written" ""

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
