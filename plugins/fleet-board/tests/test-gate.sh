#!/usr/bin/env bash
#
# Plain-bash tests for hooks/gate.sh, the PreToolUse(Bash) gate (offline, fake gh).
# No framework, no dependencies beyond POSIX tools, jq and git.
#
# Usage: bash plugins/fleet-board/tests/test-gate.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
HOOK="${SCRIPT_DIR}/../hooks/gate.sh"
HOOK_FIXTURES="$SCRIPT_DIR/../fixtures/hooks"
CONFIG_FIXTURES="$SCRIPT_DIR/../fixtures/config"
FIXTURES="$SCRIPT_DIR/../fixtures/gh"

unset FLEET_BOARD_CONFIG FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT FLEET_BOARD_GATE_TIMEOUT CDPATH RUN_CWD GH_REPO GH_HOST || true

PASS=0
FAIL=0
LAST_OUT=""
LAST_ERR=""
LAST_EXIT=0
LAST_PAYLOAD=""
CLEANUP_DIRS=()
ORIG_PATH="$PATH"
REAL_JQ="$(command -v jq)"

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

assert_stderr_contains() {
  case "$LAST_ERR" in
    *"$2"*) pass "$1" ;;
    *) fail "$1" "expected to find '$2' in stderr, got: '$LAST_ERR'" ;;
  esac
}

assert_stderr_exact() {
  if [ "$LAST_ERR" = "$2" ]; then pass "$1"; else fail "$1" "expected exact stderr: '$2', got: '$LAST_ERR'"; fi
}

assert_equal() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}

# Exit 0, empty stdout, empty stderr
assert_silent_allow() {
  assert_exit "$1: exit 0" 0
  assert_stdout_exact "$1: no stdout" ""
  assert_stderr_exact "$1: no stderr" ""
}

# Exit 2 with the reason on stderr and nothing on stdout
assert_blocked() {
  assert_exit "$1: exit 2" 2
  assert_stderr_contains "$1: reason" "$2"
  assert_stdout_exact "$1: no stdout" ""
}

assert_no_calls() {
  if [ ! -e "$FAKE_GH_DIR/calls.log" ]; then
    pass "$1"
  else
    fail "$1" "expected no gh calls, got: $(tr '\n' ';' < "$FAKE_GH_DIR/calls.log")"
  fi
}

assert_log_has() {
  if grep -Fq -- "$2" "$FAKE_GH_DIR/calls.log" 2>/dev/null; then
    pass "$1"
  else
    fail "$1" "expected '$2' in calls.log, got: $(tr '\n' ';' 2>/dev/null < "$FAKE_GH_DIR/calls.log")"
  fi
}

assert_log_lacks() {
  if grep -Fq -- "$2" "$FAKE_GH_DIR/calls.log" 2>/dev/null; then
    fail "$1" "did not expect '$2' in calls.log, got: $(tr '\n' ';' < "$FAKE_GH_DIR/calls.log")"
  else
    pass "$1"
  fi
}

# run_hook FIXTURE CMD: build the PreToolUse payload with jq (so quotes in CMD
# stay valid JSON), feed it to the hook on stdin, capture stdout/stderr/exit.
# The payload's cwd is $RUN_CWD when set, else $REPO; PAYLOAD_EDIT is a jq
# filter applied last (del(.cwd)). The hook is killed after
# $HOOK_LIMIT seconds (default 30) so a hang fails the case instead of the
# suite; LAST_SECS is the wall time in whole seconds.
run_hook() {
  local fixture="$HOOK_FIXTURES/$1" cmd="$2" tmpout tmperr pid w start
  LAST_PAYLOAD="$(jq -c --arg c "$cmd" --arg d "${RUN_CWD:-$REPO}" ".cwd=\$d | .tool_input.command=\$c${PAYLOAD_EDIT:+ | $PAYLOAD_EDIT}" "$fixture")"
  tmpout="$(mktemp)"
  tmperr="$(mktemp)"
  start=$SECONDS
  PATH="${HOOK_PATH:-$PATH}" "$BASH_EXE" "$HOOK" > "$tmpout" 2> "$tmperr" <<<"$LAST_PAYLOAD" &
  pid=$!
  ( sleep "${HOOK_LIMIT:-30}" & s=$!; trap 'kill $s 2>/dev/null; exit 0' TERM; wait $s; kill -KILL $pid ) >/dev/null 2>&1 &
  w=$!
  wait $pid 2>/dev/null
  LAST_EXIT=$?
  kill -TERM $w 2>/dev/null; wait $w 2>/dev/null
  LAST_SECS=$((SECONDS - start))
  LAST_OUT="$(cat "$tmpout")"
  LAST_ERR="$(cat "$tmperr")"
  rm -f "$tmpout" "$tmperr"
}

assert_fast() {
  if [ "$LAST_SECS" -lt "$2" ]; then pass "$1"; else fail "$1" "took ${LAST_SECS}s, limit ${2}s (exit $LAST_EXIT)"; fi
}

# setup_case CONFIG: a fresh repo (the payload's cwd) and a fresh fake gh.
# CONFIG is one of: none, labels-human, labels-auto, hmb, bad-backend.
setup_case() {
  REPO="$(mktemp -d)"
  git init -q "$REPO"
  case "$1" in
    none) ;;
    labels-human|labels-auto)
      cat > "$REPO/.fleet-board.yml" << YML
board:
  backend: github-labels
  repo: acme/toy
merge:
  policy: ${1#labels-}
YML
      ;;
    hmb) cp "$CONFIG_FIXTURES/hmb.yml" "$REPO/.fleet-board.yml" ;;
    bad-backend) cp "$CONFIG_FIXTURES/bad-backend.yml" "$REPO/.fleet-board.yml" ;;
    *) echo "setup_case: unknown config $1" >&2; exit 1 ;;
  esac

  FAKE_GH_DIR="$(mktemp -d)"
  ROUTES="$FAKE_GH_DIR/routes.txt"
  BIN="$FAKE_GH_DIR/bin"
  mkdir -p "$BIN"
  ln -s "$SCRIPT_DIR/fake-gh.sh" "$BIN/gh"
  : > "$ROUTES"

  # Reset environment between cases
  unset FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT FLEET_BOARD_CONFIG FLEET_BOARD_GATE_TIMEOUT CDPATH RUN_CWD HOOK_PATH HOOK_LIMIT PAYLOAD_EDIT || true
  PATH="$BIN:$ORIG_PATH"
  export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH

  # Run from a neutral directory: the hook must use the payload's cwd
  cd "$FAKE_GH_DIR"

  CLEANUP_DIRS+=("$REPO")
  CLEANUP_DIRS+=("$FAKE_GH_DIR")
}

# Routes every card read needs (G1a, G1b, G3)
card_routes() {
  cat << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
api repos/acme/toy/issues/12	0	$FIXTURES/labels/issue-12.json
api repos/acme/toy/issues/13	0	$FIXTURES/labels/issue-13-no-acceptance.json
api repos/acme/toy/issues/14	0	$FIXTURES/labels/issue-14-human-qa.json
api --paginate repos/acme/toy/issues/*/comments	0	$FIXTURES/labels/comments-none.json
ROUTESEOF
}

# Routes every PR lookup under merge.policy auto needs
pr_routes() {
  cat << ROUTESEOF
pr view 3 --json*	0	$FIXTURES/pr/pr-3-draft.json
pr view 4 -R other/repo --json*	0	$FIXTURES/pr/pr-4-green.json
pr view 4 --json*	0	$FIXTURES/pr/pr-4-green.json
pr view 5 --json*	0	$FIXTURES/pr/pr-5-red.json
pr view 6 --json*	0	$FIXTURES/pr/pr-6-nochecks.json
ROUTESEOF
}

# stall_gh GLOB SECS: gh calls whose arguments match GLOB answer SECS seconds
# late (logged at once, answered after the sleep); other calls are unchanged
stall_gh() {
  rm -f "$BIN/gh"
  cat > "$BIN/gh" << STALLEOF
#!/usr/bin/env bash
out="\$("$SCRIPT_DIR/fake-gh.sh" "\$@")"; rc=\$?
pat='$1'
case "\$*" in \$pat) sleep $2 ;; esac
printf '%s' "\$out"
exit \$rc
STALLEOF
  chmod +x "$BIN/gh"
}

# jq_fault MODE: the config read of merge.policy (fb_cfg merge.policy) fails
# (MODE fail) or prints nothing (MODE empty); every other jq call is real jq
jq_fault() {
  cat > "$BIN/jq" << JQEOF
#!/usr/bin/env bash
case "\$*" in *"--arg p merge.policy"*) [ "$1" = fail ] && exit 5; exit 0 ;; esac
exec "$REAL_JQ" "\$@"
JQEOF
  chmod +x "$BIN/jq"
}

echo "Test: hooks/gate.sh"
echo ""

# ---------------------------------------------------------------------------
# AC4.5 inert-no-config
setup_case none
card_routes > "$ROUTES"
pr_routes >> "$ROUTES"
for c in "gh pr merge 3" "bash scripts/board-move.sh 14 done" "ls -la"; do
  run_hook bash.json "$c"
  assert_silent_allow "inert-no-config: $c"
done
assert_no_calls "inert-no-config: calls.log does not exist"

# ---------------------------------------------------------------------------
# AC4.5 non-bash-tool (config present, merge.policy human, and a command that
# would be blocked if the tool were Bash)
setup_case labels-human
card_routes > "$ROUTES"
run_hook edit.json "gh pr merge 4"
assert_equal "non-bash-tool: payload tool_name is Edit" "$(jq -r .tool_name <<<"$LAST_PAYLOAD")" "Edit"
assert_silent_allow "non-bash-tool"
assert_no_calls "non-bash-tool: no gh calls"

# ---------------------------------------------------------------------------
# ordinary-command-fast-path
# FLEET_BOARD_CONFIG points at an invalid config: a hook that read the config
# for an ordinary command would block it. The gated command shows the
# sentinel is live.
setup_case labels-human
card_routes > "$ROUTES"
export FLEET_BOARD_CONFIG="$CONFIG_FIXTURES/bad-backend.yml"
run_hook bash.json "npm test -- --runTestsByPath a.test.ts"
assert_silent_allow "ordinary-command-fast-path"
assert_no_calls "ordinary-command-fast-path: no gh calls"
run_hook bash.json "gh pr merge 4"
assert_blocked "ordinary-command-fast-path: the invalid-config sentinel is read for a gated command" "invalid"
unset FLEET_BOARD_CONFIG

# ---------------------------------------------------------------------------
# AC4.1 move-out-of-human-qa
# (Plan deviation, review cycle 1: the plan's "cd /tmp && board-move.sh 14 done"
# became "cd sub && ...". The hook now evaluates a command in the directory a
# literal cd moves it to, and /tmp has no .fleet-board.yml, so board-move.sh
# could not move anything there. sub is inside the configured repo.)
setup_case labels-human
card_routes > "$ROUTES"
mkdir -p "$REPO/sub"
for c in "bash /x/scripts/board-move.sh 14 ready" \
         "cd sub && board-move.sh 14 done" \
         'FOO=1 bash -c "board-move 14 in_review"'; do
  run_hook bash.json "$c"
  assert_blocked "move-out-of-human-qa: $c" "Human QA"
  assert_stderr_contains "move-out-of-human-qa: $c: names #14" "#14"
  assert_stderr_contains "move-out-of-human-qa: $c: gate prefix" "fleet-board gate: "
done
run_hook bash.json "board-move.sh 14 human_qa"
assert_silent_allow "move-out-of-human-qa: board-move.sh 14 human_qa"

# ---------------------------------------------------------------------------
# AC4.1 + AC4.3 shell-syntax-cannot-bypass
setup_case labels-human
card_routes > "$ROUTES"
for c in "X=1 gh pr merge 4" \
         "if true; then gh pr merge 4; fi" \
         "{ gh pr merge 4; }" \
         "timeout 30 gh pr merge 4" \
         "! gh pr merge 4" \
         "env -i gh pr merge 4" \
         "nice -n 5 gh pr merge 4" \
         "timeout -s KILL 30 gh pr merge 4" \
         "sudo -u x gh pr merge 4" \
         "xargs -I{} gh pr merge 4" \
         "sudo -u gh gh pr merge 4" \
         "time -o /tmp/gh gh pr merge 4" \
         "curl -X PUT https://api.github.com/repos/acme/toy/pulls/4/merge"; do
  run_hook bash.json "$c"
  assert_exit "shell-syntax-cannot-bypass: $c: exit 2" 2
  assert_stderr_contains "shell-syntax-cannot-bypass: $c: reason" "merge.policy is human"
done
for c in "for i in 1; do board-move.sh 14 done; done" \
         "while false; do :; done; A=b B=c board-move.sh 14 ready"; do
  run_hook bash.json "$c"
  assert_exit "shell-syntax-cannot-bypass: $c: exit 2" 2
  assert_stderr_contains "shell-syntax-cannot-bypass: $c: reason" "Human QA"
done

# ---------------------------------------------------------------------------
# read-only-api-allowed
setup_case labels-human
card_routes > "$ROUTES"
run_hook bash.json "gh api repos/acme/toy/issues/14/labels"
assert_silent_allow "read-only-api-allowed"

# ---------------------------------------------------------------------------
# merge-repo-passthrough
setup_case labels-auto
pr_routes > "$ROUTES"
run_hook bash.json "gh pr merge 4 -R other/repo"
assert_log_has "merge-repo-passthrough: pr view carries -R other/repo" "pr view 4 -R other/repo --json"
assert_exit "merge-repo-passthrough: exit 0" 0

# ---------------------------------------------------------------------------
# AC4.1 issue-edit-state-label-on-qa-card
setup_case labels-human
card_routes > "$ROUTES"
run_hook bash.json "gh issue edit 14 --remove-label fleet:human_qa"
assert_blocked "issue-edit-state-label-on-qa-card: remove fleet:human_qa" "Human QA"
run_hook bash.json "gh issue edit 14 --add-label bug"
assert_silent_allow "issue-edit-state-label-on-qa-card: add bug"
run_hook bash.json "gh -R acme/toy issue edit 14 --add-label fleet:done,bug"
assert_blocked "issue-edit-state-label-on-qa-card: -R, add fleet:done,bug" "Human QA"

# ---------------------------------------------------------------------------
# AC4.1 project-item-edit-on-qa-item
ITEM_EDIT="gh project item-edit --id PVTI_14 --project-id P --field-id F --single-select-option-id O"
setup_case hmb
{ cat << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
api graphql*	0	$FIXTURES/pr/item-status-qa.json
ROUTESEOF
card_routes; } > "$ROUTES"
run_hook bash.json "$ITEM_EDIT"
assert_blocked "project-item-edit-on-qa-item: QA item" "project item PVTI_14 is in Human QA"
assert_log_has "project-item-edit-on-qa-item: item status read by id" "PVTI_14"

setup_case hmb
{ cat << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
api graphql*	0	$FIXTURES/pr/item-status-ready.json
ROUTESEOF
card_routes; } > "$ROUTES"
run_hook bash.json "$ITEM_EDIT"
assert_silent_allow "project-item-edit-on-qa-item: Ready item"

# ---------------------------------------------------------------------------
# AC4.1 raw-writes-blocked
setup_case labels-human
card_routes > "$ROUTES"
for c in "gh api graphql -f query='mutation{updateProjectV2ItemFieldValue(input:{})}'" \
         "gh api -X POST repos/acme/toy/issues/14/labels -f labels[]=fleet:done"; do
  run_hook bash.json "$c"
  assert_blocked "raw-writes-blocked: $c" "bypass the board adapter"
done

# ---------------------------------------------------------------------------
# AC4.1 read-failure-fails-closed
setup_case labels-human
{ printf 'api repos/acme/toy/issues/14\t1\t-\n'; card_routes; } > "$ROUTES"
run_hook bash.json "board-move.sh 14 done"
assert_blocked "read-failure-fails-closed" "blocking to be safe"
assert_log_has "read-failure-fails-closed: the card read was attempted" "api repos/acme/toy/issues/14"

# ---------------------------------------------------------------------------
# AC4.3 human-policy-blocks-all-merges
setup_case labels-human
{ card_routes; pr_routes; } > "$ROUTES"
for c in "gh pr merge 4 --squash" \
         "gh pr merge" \
         'bash -c "gh pr merge 4"' \
         "gh api -X PUT repos/acme/toy/pulls/4/merge"; do
  run_hook bash.json "$c"
  assert_blocked "human-policy-blocks-all-merges: $c" "merge.policy is human"
done
assert_log_lacks "human-policy-blocks-all-merges: no pr view" "pr view"

# ---------------------------------------------------------------------------
# AC4.2 draft-blocked
setup_case labels-auto
pr_routes > "$ROUTES"
run_hook bash.json "gh pr merge 3 --squash"
assert_blocked "draft-blocked" "draft"
assert_stderr_contains "draft-blocked: names PR #3" "PR #3"
assert_log_has "draft-blocked: pr view 3 --json" "pr view 3 --json number,isDraft,statusCheckRollup"

# ---------------------------------------------------------------------------
# AC4.4 auto-green-allowed
setup_case labels-auto
pr_routes > "$ROUTES"
run_hook bash.json "gh pr merge 4 --squash --delete-branch"
assert_silent_allow "auto-green-allowed: pr 4 green"
assert_log_has "auto-green-allowed: pr 4 was looked up" "pr view 4 --json"
run_hook bash.json "gh pr merge 6"
assert_silent_allow "auto-green-allowed: pr 6 no checks"

# ---------------------------------------------------------------------------
# AC4.4 auto-red-blocked
setup_case labels-auto
pr_routes > "$ROUTES"
run_hook bash.json "gh pr merge 5"
assert_blocked "auto-red-blocked" "not green"
assert_stderr_contains "auto-red-blocked: names PR #5" "PR #5"

# ---------------------------------------------------------------------------
# admin-blocked
setup_case labels-auto
pr_routes > "$ROUTES"
run_hook bash.json "gh pr merge 4 --admin"
assert_blocked "admin-blocked" "--admin bypasses branch protection"

# ---------------------------------------------------------------------------
# ready-needs-acceptance
setup_case labels-human
card_routes > "$ROUTES"
run_hook bash.json "board-move.sh 13 ready"
assert_blocked "ready-needs-acceptance: #13" "## Acceptance"
assert_stderr_contains "ready-needs-acceptance: names #13" "#13"
run_hook bash.json "board-move.sh 12 ready"
assert_silent_allow "ready-needs-acceptance: #12"

# ---------------------------------------------------------------------------
# AC4.6 subagent-payload-gated-identically: the same command from a subagent
# payload gives the same exit code and the same stderr as from the main session.
subagent_same() {
  local name="$1" cmd="$2" reason="$3" main_exit main_err
  run_hook bash.json "$cmd"
  main_exit="$LAST_EXIT"; main_err="$LAST_ERR"
  run_hook bash-subagent.json "$cmd"
  assert_equal "subagent-payload-gated-identically: $name: payload has agent_id" \
    "$(jq -r '.agent_id // empty' <<<"$LAST_PAYLOAD")" "a1"
  assert_blocked "subagent-payload-gated-identically: $name" "$reason"
  assert_equal "subagent-payload-gated-identically: $name: same exit as main" "$LAST_EXIT" "$main_exit"
  assert_equal "subagent-payload-gated-identically: $name: same stderr as main" "$LAST_ERR" "$main_err"
}
setup_case labels-human
card_routes > "$ROUTES"
subagent_same "move-out-of-human-qa" "bash /x/scripts/board-move.sh 14 ready" "Human QA"
subagent_same "human-policy" "gh pr merge 4 --squash" "merge.policy is human"
setup_case labels-auto
pr_routes > "$ROUTES"
subagent_same "draft" "gh pr merge 3 --squash" "draft"

# ---------------------------------------------------------------------------
# invalid-config-fails-closed
setup_case bad-backend
{ card_routes; pr_routes; } > "$ROUTES"
run_hook bash.json "gh pr merge 4"
assert_blocked "invalid-config-fails-closed: gh pr merge 4" "invalid"
run_hook bash.json "ls"
assert_silent_allow "invalid-config-fails-closed: ls"

# ---------------------------------------------------------------------------
# Hardening beyond the plan's case list: forms that would otherwise slip past
# the recognized shapes.

# quoting-cannot-hide-command-word: quote and backslash characters inside a
# word vanish in the shell, so they must not hide the keyword or the command word
setup_case labels-human
card_routes > "$ROUTES"
for c in "g''h pr merge 4" 'g\h pr merge 4' 'board-mo""ve.sh 14 done'; do
  run_hook bash.json "$c"
  assert_exit "quoting-cannot-hide-command-word: $c: exit 2" 2
done
assert_stderr_contains "quoting-cannot-hide-command-word: board-move reason" "Human QA"

# raw-merge-graphql-blocked: the GraphQL merge mutations are raw merges
setup_case labels-human
card_routes > "$ROUTES"
run_hook bash.json "gh api graphql -f query='mutation{mergePullRequest(input:{})}'"
assert_blocked "raw-merge-graphql-blocked: mergePullRequest" "merge.policy is human"
setup_case labels-auto
pr_routes > "$ROUTES"
run_hook bash.json "gh api graphql -f query='mutation{enablePullRequestAutoMerge(input:{})}'"
assert_blocked "raw-merge-graphql-blocked: enablePullRequestAutoMerge under auto" "use gh pr merge"

# raw-label-patch-blocked: PATCH on the issue itself with a labels field
setup_case labels-human
card_routes > "$ROUTES"
run_hook bash.json "gh api -X PATCH repos/acme/toy/issues/14 -f labels[]=fleet:done"
assert_blocked "raw-label-patch-blocked" "bypass the board adapter"
run_hook bash.json "gh api repos/acme/toy/issues/14"
assert_silent_allow "raw-label-patch-blocked: a read of the issue is allowed"

# variable-card-number-fails-closed: the hook cannot know what $N expands to
setup_case labels-human
card_routes > "$ROUTES"
run_hook bash.json 'board-move.sh $N done'
assert_blocked "variable-card-number-fails-closed" "blocking to be safe"
run_hook bash.json 'grep -n x scripts/board-move.sh'
assert_silent_allow "variable-card-number-fails-closed: a path mention is not a move"

# issue-edit-label-forms: a quoted list that quote stripping splits apart,
# flags before the number, and a state label on a card that is not in Human QA
setup_case labels-human
card_routes > "$ROUTES"
run_hook bash.json 'gh issue edit 14 --add-label "bug, fleet:done"'
assert_blocked "issue-edit-label-forms: quoted list split by stripping" "Human QA"
run_hook bash.json "gh issue edit --add-label fleet:done 14"
assert_blocked "issue-edit-label-forms: flags before the number" "#14"
run_hook bash.json "gh issue edit 12 --add-label fleet:done"
assert_silent_allow "issue-edit-label-forms: state label on a ready card"

# merge-body-cannot-stand-in: a split --body must not replace the real PR
setup_case labels-auto
pr_routes > "$ROUTES"
run_hook bash.json 'gh pr merge --body "ok 6" 5'
assert_blocked "merge-body-cannot-stand-in" "not green"
assert_stderr_contains "merge-body-cannot-stand-in: names PR #5" "PR #5"

# ---------------------------------------------------------------------------
# Review cycle 1: shapes split or hidden by shell syntax (C1-C4)

# The current branch's PR is green, so a merge that loses its ARG would pass
current_branch_green() {
  printf 'pr view --json*\t0\t%s\n' "$FIXTURES/pr/pr-4-green.json"
}

# C1 continuation-and-multiline: a backslash-newline, or a newline inside a
# quoted argument, must not split a shape across segments; neither may a
# separator character inside quotes
setup_case labels-human
card_routes > "$ROUTES"
for c in $'board-move.sh \\\n 14 done' \
         $'gh issue edit 14 --title x \\\n --remove-label fleet:human_qa' \
         'gh issue edit 14 --title "a; b" --remove-label fleet:human_qa' \
         'gh issue edit 14 --title "a (b)" --remove-label fleet:human_qa' \
         $'b\\\noard-move.sh 14 done'; do
  run_hook bash.json "$c"
  assert_blocked "continuation-and-multiline: $c" "Human QA"
done
for c in $'gh api graphql -f query=\'\n mutation {\n updateProjectV2ItemFieldValue(input:{}) { clientMutationId }\n}\'' \
         "gh api graphql -f query='mutation(\$id:ID!){updateProjectV2ItemFieldValue(input:{})}'" \
         $'gh api \\\n -X POST repos/acme/toy/issues/14/labels -f labels[]=fleet:done'; do
  run_hook bash.json "$c"
  assert_blocked "continuation-and-multiline: $c" "bypass the board adapter"
done
for c in $'gh api graphql -f query=\'\n mutation {\n mergePullRequest(input:{}) { clientMutationId }\n}\'' \
         $'gh api -X PUT \\\n repos/acme/toy/pulls/5/merge' \
         $'curl -X PUT \\\n https://api.github.com/repos/acme/toy/pulls/5/merge'; do
  run_hook bash.json "$c"
  assert_blocked "continuation-and-multiline: $c" "merge.policy is human"
done
setup_case labels-auto
{ pr_routes; current_branch_green; } > "$ROUTES"
run_hook bash.json $'gh pr merge \\\n 5'
assert_blocked "continuation-and-multiline: auto merge ARG on the next line" "not green"
assert_stderr_contains "continuation-and-multiline: names PR #5" "PR #5"

# C2 substitution-keeps-arguments: a command substitution stands in for an
# argument (and the hook cannot know its value); it must not drop the
# arguments after it, and its own text is still checked
setup_case labels-human
card_routes > "$ROUTES"
for c in 'board-move.sh $(echo 14) done' \
         'board-move.sh `echo 14` done' \
         'board-move.sh 14 $(echo done)' \
         'board-move.sh "$(echo 14)" done' \
         'gh issue edit $(echo 14) --remove-label fleet:human_qa'; do
  run_hook bash.json "$c"
  assert_blocked "substitution-keeps-arguments: $c" "blocking to be safe"
done
run_hook bash.json 'echo "$(gh pr merge 4)"'
assert_blocked "substitution-keeps-arguments: shape inside a substitution" "merge.policy is human"
setup_case labels-auto
{ pr_routes; current_branch_green; } > "$ROUTES"
run_hook bash.json 'gh pr merge `echo 5`'
assert_blocked "substitution-keeps-arguments: auto merge ARG from backquotes" "blocking to be safe"
run_hook bash.json 'gh pr merge $(echo 5)'
assert_blocked "substitution-keeps-arguments: auto merge ARG from \$()" "blocking to be safe"

# C3 repo-flag-before-verb: gh accepts -R between the group word and the verb
setup_case labels-human
card_routes > "$ROUTES"
for c in "gh pr -R acme/toy merge 4" \
         "gh pr --repo=acme/toy merge 4" \
         "gh pr --repo acme/toy merge 4" \
         "gh pr -Racme/toy merge 4"; do
  run_hook bash.json "$c"
  assert_blocked "repo-flag-before-verb: $c" "merge.policy is human"
done
run_hook bash.json "gh issue -R acme/toy edit 14 --remove-label fleet:human_qa"
assert_blocked "repo-flag-before-verb: issue -R X edit" "Human QA"
setup_case labels-auto
pr_routes > "$ROUTES"
run_hook bash.json "gh pr -R other/repo merge 4"
assert_log_has "repo-flag-before-verb: the repo reaches pr view" "pr view 4 -R other/repo --json"
assert_silent_allow "repo-flag-before-verb: auto, green PR in other/repo"

# C4 variable-label-values: a label the hook cannot read counts as a state label
setup_case labels-human
card_routes > "$ROUTES"
for c in 'gh issue edit 14 --remove-label $L' \
         'P=fleet; gh issue edit 14 --remove-label $P:human_qa' \
         'gh issue edit 14 --add-label=$L' \
         'gh issue edit 14 --remove-label "$(printf fleet:human_qa)"'; do
  run_hook bash.json "$c"
  assert_blocked "variable-label-values: $c" "Human QA"
done
run_hook bash.json 'gh issue edit $N --remove-label $L'
assert_blocked "variable-label-values: unknown card too" "blocking to be safe"
run_hook bash.json 'gh issue edit 12 --remove-label $L'
assert_silent_allow "variable-label-values: card 12 is not in Human QA"
assert_log_has "variable-label-values: card 12 was read" "api repos/acme/toy/issues/12"

# Shapes the old tokenizer mis-read: a redirection is not an argument, and a
# brace expansion or glob in the card number can expand to a real number
setup_case labels-human
card_routes > "$ROUTES"
for c in 'board-move.sh >/dev/null 14 done' \
         'board-move.sh 2>&1 14 done' \
         'board-move.sh 14 >&- done'; do
  run_hook bash.json "$c"
  assert_blocked "redirection-is-not-an-argument: $c" "Human QA"
done
for c in 'board-move.sh {14,} done' 'board-move.sh 1? done' 'board-move.sh 1* done'; do
  run_hook bash.json "$c"
  assert_blocked "expansion-in-card-number: $c" "blocking to be safe"
done

# ---------------------------------------------------------------------------
# Review cycle 1: important and minor findings (I1-I7, M2-M6)

# I1 merge-needs-explicit-pr: under auto, a merge without ARG would check
# whatever PR the hook's cwd resolves to, not the one the command merges
setup_case labels-auto
{ pr_routes; current_branch_green; } > "$ROUTES"
for c in "gh pr merge" \
         "gh pr merge --squash --delete-branch" \
         "echo 5 | xargs gh pr merge" \
         "git checkout red && gh pr merge" \
         "gh pr checkout 5 && gh pr merge"; do
  run_hook bash.json "$c"
  assert_blocked "merge-needs-explicit-pr: $c" "name the PR explicitly (gh pr merge <number>) so the gate can check it"
done
assert_log_lacks "merge-needs-explicit-pr: no pr view" "pr view"

# I2 gh-repo-env: GH_REPO/GH_HOST in the command change the repo gh acts on
setup_case labels-auto
pr_routes > "$ROUTES"
for c in "GH_REPO=evil/repo gh pr merge 4" \
         "export GH_REPO=evil/repo; gh pr merge 4" \
         "env GH_HOST=evil.example gh pr merge 4" \
         "GH_REPO=evil/repo gh issue edit 14 --add-label bug"; do
  run_hook bash.json "$c"
  assert_blocked "gh-repo-env: $c" "GH_REPO/GH_HOST in the command; blocking to be safe"
done
assert_log_lacks "gh-repo-env: no pr view" "pr view"

# config-env-in-command: FLEET_BOARD_CONFIG, GIT_DIR and GIT_WORK_TREE change
# which config applies, so a no-config cwd does not make the command inert
setup_case labels-human
card_routes > "$ROUTES"
CFG_REPO="$REPO"
NOCFG="$(mktemp -d)"; CLEANUP_DIRS+=("$NOCFG")
RUN_CWD="$NOCFG"
run_hook bash.json "FLEET_BOARD_CONFIG=$CFG_REPO/.fleet-board.yml board-move.sh 14 done"
assert_blocked "config-env-in-command: FLEET_BOARD_CONFIG" "FLEET_BOARD_CONFIG in the command"
run_hook bash.json "GIT_DIR=$CFG_REPO/.git gh pr merge 4"
assert_blocked "config-env-in-command: GIT_DIR" "GIT_DIR in the command"
run_hook bash.json "GH_REPO=acme/toy gh pr merge 4"
assert_silent_allow "config-env-in-command: GH_REPO in a no-config cwd is inert, like -R"

# I3 cd-target-decides-config: the hook evaluates a command in the directory
# it will run in
setup_case labels-human
card_routes > "$ROUTES"
CFG_REPO="$REPO"
mkdir -p "$CFG_REPO/sub"
NOCFG="$(mktemp -d)"; CLEANUP_DIRS+=("$NOCFG")
RUN_CWD="$NOCFG"
for c in "cd $CFG_REPO && gh pr merge 4" \
         "cd $CFG_REPO; gh pr merge 4" \
         "pushd $CFG_REPO && gh pr merge 4" \
         "if cd $CFG_REPO; then gh pr merge 4; fi" \
         "cd $CFG_REPO/sub && gh pr merge 4" \
         "cd $CFG_REPO && cd sub && gh pr merge 4" \
         "cd $CFG_REPO && bash -c 'gh pr merge 4'"; do
  run_hook bash.json "$c"
  assert_blocked "cd-target-decides-config: from a no-config cwd: $c" "merge.policy is human"
done
run_hook bash.json "cd $CFG_REPO && board-move.sh 14 done"
assert_blocked "cd-target-decides-config: board-move after cd into the board repo" "Human QA"
HOME_SAVE="$HOME"
HOME="$CFG_REPO"
for c in "cd ~ && gh pr merge 4" "cd ~/sub && gh pr merge 4" "cd && gh pr merge 4"; do
  run_hook bash.json "$c"
  assert_blocked "cd-target-decides-config: tilde: $c" "merge.policy is human"
done
HOME="$HOME_SAVE"
for c in "(cd $CFG_REPO && true); gh pr merge 4" \
         "bash -c 'cd $CFG_REPO' && gh pr merge 4" \
         "echo \$(cd $CFG_REPO) && gh pr merge 4"; do
  run_hook bash.json "$c"
  assert_silent_allow "cd-target-decides-config: a cd in a child does not move the parent: $c"
done
for c in 'cd "$D" && gh pr merge 4' \
         'cd $(git rev-parse --show-toplevel) && gh pr merge 4' \
         'cd ~nobody && gh pr merge 4' \
         'cd - && gh pr merge 4' \
         'popd && gh pr merge 4' \
         'eval "cd /x" && gh pr merge 4' \
         'source env.sh && gh pr merge 4'; do
  run_hook bash.json "$c"
  assert_blocked "cd-target-decides-config: unknown directory: $c" "could not tell which directory"
done
run_hook bash.json "cd /nonexistent-fleet-gate-dir && gh pr merge 4"
assert_blocked "cd-target-decides-config: missing directory" "directory /nonexistent-fleet-gate-dir does not exist; blocking to be safe"
RUN_CWD=""
rm -f "$FAKE_GH_DIR/calls.log"
for c in "cd $NOCFG && gh pr merge 4" "cd $NOCFG && board-move.sh 14 done"; do
  run_hook bash.json "$c"
  assert_silent_allow "cd-target-decides-config: from the board repo into a no-config dir: $c"
done
assert_no_calls "cd-target-decides-config: nothing read for a no-config target"
for c in "(cd $NOCFG && true); gh pr merge 4" \
         "cd $NOCFG || gh pr merge 4" \
         "cd $NOCFG | gh pr merge 4" \
         "true && cd $NOCFG; gh pr merge 4"; do
  run_hook bash.json "$c"
  assert_blocked "cd-target-decides-config: may still run in the board repo: $c" "merge.policy is human"
done

# M6 missing-cwd: a payload cwd that does not exist gets its own reason
setup_case labels-human
card_routes > "$ROUTES"
RUN_CWD=/nonexistent-fleet-gate-cwd
run_hook bash.json "gh pr merge 4"
assert_blocked "missing-cwd: gh pr merge 4" "cwd /nonexistent-fleet-gate-cwd does not exist; blocking to be safe"
run_hook bash.json "ls -la"
assert_silent_allow "missing-cwd: ls -la"

# I4 bounded-time: the hook must finish well inside the 60 s hook timeout
# (past it the call proceeds), whatever the command's size, and a stalled
# lookup blocks
WORDS="$(awk 'BEGIN { for (i = 1; i <= 10000; i++) printf "w%d ", i }')"
setup_case labels-human
card_routes > "$ROUTES"
# An ordinary command full of quotes takes the fast path, and fast
run_hook bash.json "printf '%s\\n' $(awk 'BEGIN { for (i = 1; i <= 8000; i++) printf "\"w%d\" '"'"'x'"'"' ", i }') > notes.txt"
assert_silent_allow "bounded-time: 8000 quoted words, no gated keyword"
assert_fast "bounded-time: 8000 quoted words, no gated keyword: fast" 3
run_hook bash.json "gh pr merge 4 --body $WORDS"
assert_exit "bounded-time: 10000 unquoted words: exit 2" 2
assert_fast "bounded-time: 10000 unquoted words: fast" 5
run_hook bash.json "gh pr merge 4 --body \"$WORDS\""
assert_blocked "bounded-time: 10000 quoted words" "merge.policy is human"
assert_fast "bounded-time: 10000 quoted words: fast" 5
run_hook bash.json "gh issue edit 14 --body \"$WORDS\" --remove-label fleet:human_qa"
assert_blocked "bounded-time: 10000-word body on an issue edit" "Human QA"
assert_fast "bounded-time: 10000-word body on an issue edit: fast" 5
run_hook bash.json "gh pr merge 4 # $(awk 'BEGIN { for (i = 0; i < 70000; i++) printf "x" }')"
assert_blocked "bounded-time: over 64 KiB" "too long to check"
assert_fast "bounded-time: over 64 KiB: fast" 5
run_hook bash.json "$(awk 'BEGIN { for (i = 0; i < 40; i++) printf "echo $("; printf "gh pr merge 4"; for (i = 0; i < 40; i++) printf ")" }')"
assert_blocked "bounded-time: nesting too deep" "nests too deeply"
setup_case labels-auto
pr_routes > "$ROUTES"
run_hook bash.json "$(awk 'BEGIN { for (i = 0; i < 33; i++) printf "gh pr merge 4; " }')"
assert_blocked "bounded-time: too many shapes" "too many"
setup_case labels-auto
pr_routes > "$ROUTES"
stall_gh "pr view*" 6
# 2 s: $SECONDS counts whole seconds, so a 1 s budget can be spent before the lookup starts
export FLEET_BOARD_GATE_TIMEOUT=2
run_hook bash.json "gh pr merge 4"
assert_blocked "bounded-time: stalled pr view" "could not verify PR 4"
assert_fast "bounded-time: stalled pr view: fast" 5
assert_log_has "bounded-time: the pr view was made" "pr view 4 --json"
setup_case labels-human
card_routes > "$ROUTES"
stall_gh "api repos/acme/toy/issues/14" 6
export FLEET_BOARD_GATE_TIMEOUT=2
run_hook bash.json "board-move.sh 14 done"
assert_blocked "bounded-time: stalled card read" "could not verify card #14"
assert_fast "bounded-time: stalled card read: fast" 5
unset FLEET_BOARD_GATE_TIMEOUT

# I5 label-case: GitHub label names are case-insensitive
setup_case labels-human
card_routes > "$ROUTES"
run_hook bash.json "gh issue edit 14 --remove-label FLEET:HUMAN_QA"
assert_blocked "label-case: FLEET:HUMAN_QA" "Human QA"

# I6 more-raw-writes: other writes that change a card's state or merge
setup_case labels-human
card_routes > "$ROUTES"
for c in "gh api graphql -f query='mutation{updateIssue(input:{id:\"I_1\",labelIds:[\"L_1\"]}){issue{id}}}'" \
         "gh api -X PATCH repos/acme/toy/labels/fleet:human_qa -f new_name=x" \
         "gh api -X DELETE repos/acme/toy/labels/fleet:done"; do
  run_hook bash.json "$c"
  assert_blocked "more-raw-writes: $c" "bypass the board adapter"
done
for c in "gh label edit fleet:human_qa --name fleet:qa_old" \
         "gh label delete FLEET:HUMAN_QA --yes" \
         "gh label edit bug --name fleet:done" \
         'gh label edit $L --name x'; do
  run_hook bash.json "$c"
  assert_blocked "more-raw-writes: $c" "state label"
done
for c in "gh label edit bug --color ff0000" "gh api repos/acme/toy/labels"; do
  run_hook bash.json "$c"
  assert_silent_allow "more-raw-writes: allowed: $c"
done
run_hook bash.json "gh api -X POST repos/acme/toy/merges -f base=main -f head=feature"
assert_blocked "more-raw-writes: merges endpoint under human" "merge.policy is human"
run_hook bash.json "FLEET_ROOT=. bash plugins/fleet-board/scripts/adapters/github-labels/move.sh 14 done"
assert_blocked "more-raw-writes: an adapter's move.sh" "Human QA"
setup_case labels-auto
pr_routes > "$ROUTES"
run_hook bash.json "gh api -X POST repos/acme/toy/merges -f base=main -f head=feature"
assert_blocked "more-raw-writes: merges endpoint under auto" "use gh pr merge"
setup_case hmb
{ cat << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
api graphql*	0	$FIXTURES/pr/item-status-qa.json
ROUTESEOF
card_routes; } > "$ROUTES"
for c in "gh project item-archive 1 --owner acme --id PVTI_14" \
         "gh project item-delete 1 --owner acme --id PVTI_14"; do
  run_hook bash.json "$c"
  assert_blocked "more-raw-writes: $c" "project item PVTI_14 is in Human QA"
done
for c in 'gh project item-edit --id $ID --project-id P --field-id F --single-select-option-id O' \
         "gh project item-edit --project-id P --field-id F --single-select-option-id O"; do
  run_hook bash.json "$c"
  assert_blocked "more-raw-writes: unknown item: $c" "could not verify project item"
done

# I7 lookup-failures-fail-closed: every unreadable answer blocks
setup_case labels-auto
{ printf 'pr view 7 --json*\t1\t-\n'
  printf 'pr view 8 --json*\t0\t%s\n' "$FIXTURES/projects/auth-status-ok.txt"
  printf 'pr view 9 --json*\t0\t%s\n' "$FIXTURES/pr/pr-9-no-isdraft.json"
  printf 'pr view 10 --json*\t0\t%s\n' "$FIXTURES/pr/pr-10-in-progress.json"
  printf 'pr view 11 --json*\t0\t%s\n' "$FIXTURES/pr/pr-11-status-pending.json"
  printf 'pr view 12 --json*\t0\t%s\n' "$FIXTURES/pr/pr-12-no-rollup.json"
  printf 'pr view 13 --json*\t0\t%s\n' "$FIXTURES/pr/pr-13-queued.json"
  pr_routes; } > "$ROUTES"
run_hook bash.json "gh pr merge 7"
assert_blocked "lookup-failures-fail-closed: pr view exits 1" "could not verify PR 7; blocking to be safe"
run_hook bash.json "gh pr merge 8"
assert_blocked "lookup-failures-fail-closed: pr view prints no JSON" "could not verify PR 8; blocking to be safe"
run_hook bash.json "gh pr merge 9"
assert_blocked "lookup-failures-fail-closed: no isDraft" "could not verify PR 9; blocking to be safe"
run_hook bash.json "gh pr merge 12"
assert_blocked "lookup-failures-fail-closed: no statusCheckRollup (M2)" "could not verify PR 12; blocking to be safe"
for n in 10 11 13; do
  run_hook bash.json "gh pr merge $n"
  assert_blocked "lookup-failures-fail-closed: pending checks on PR $n" "PR #$n checks are not green"
done
setup_case hmb
{ printf 'auth status\t0\t%s\n' "$FIXTURES/projects/auth-status-ok.txt"
  printf 'api graphql*\t1\t-\n'; card_routes; } > "$ROUTES"
run_hook bash.json "$ITEM_EDIT"
assert_blocked "lookup-failures-fail-closed: item status query exits 1" "could not verify project item PVTI_14; blocking to be safe"
setup_case hmb
{ printf 'auth status\t0\t%s\n' "$FIXTURES/projects/auth-status-ok.txt"
  printf 'api graphql*\t0\t%s\n' "$FIXTURES/pr/item-status-null.json"; card_routes; } > "$ROUTES"
run_hook bash.json "$ITEM_EDIT"
assert_blocked "lookup-failures-fail-closed: item node is null" "could not verify project item PVTI_14; blocking to be safe"
for mode in fail empty; do
  setup_case labels-human
  card_routes > "$ROUTES"
  jq_fault "$mode"
  run_hook bash.json "gh pr merge 4"
  assert_blocked "lookup-failures-fail-closed: config read of merge.policy: $mode" "could not verify the board config; blocking to be safe"
done

# M3 no-jq-or-bad-payload: without jq, or with a payload that is not JSON,
# there is no Bash command to read; the hook stays silent (exit 0)
setup_case labels-human
card_routes > "$ROUTES"
NOJQ_BIN="$(mktemp -d)"; CLEANUP_DIRS+=("$NOJQ_BIN")
ln -s "$(command -v cat)" "$NOJQ_BIN/cat"
HOOK_PATH="$NOJQ_BIN"
run_hook bash.json "gh pr merge 4"
assert_silent_allow "no-jq-or-bad-payload: jq missing"
unset HOOK_PATH
tmperr="$(mktemp)"
LAST_OUT="$(printf 'not json {' | "$BASH_EXE" "$HOOK" 2>"$tmperr")"; LAST_EXIT=$?
LAST_ERR="$(cat "$tmperr")"; rm -f "$tmperr"
assert_silent_allow "no-jq-or-bad-payload: payload is not JSON"

# M5 obfuscated-command-word: forms that name gh without writing gh
setup_case labels-human
card_routes > "$ROUTES"
for c in "\$'\\x67h' pr merge 5" \
         'G=gh; $G pr merge 5' \
         '$(which gh) pr merge 5' \
         'g${x}h pr merge 5' \
         'f() { gh "$@"; }; f pr merge 5'; do
  run_hook bash.json "$c"
  assert_exit "obfuscated-command-word: $c: exit 2" 2
done
# macOS file systems are case-insensitive by default: GH runs gh there
for c in "GH pr merge 4" "/usr/local/bin/Gh pr merge 4" "BOARD-MOVE.SH 14 done"; do
  run_hook bash.json "$c"
  assert_exit "obfuscated-command-word: case-insensitive: $c: exit 2" 2
done

# ---------------------------------------------------------------------------
# Review cycle 1 re-check: holes left in the cycle 1 fixes

# empty-argument-keeps-position: "" and '' are words; dropping them lets a
# flag take the next word as its value and hides the flag after it
setup_case labels-human
card_routes > "$ROUTES"
for c in 'gh issue edit 14 --title "" --remove-label fleet:human_qa' \
         "gh issue edit 14 --body '' --add-label fleet:done"; do
  run_hook bash.json "$c"
  assert_blocked "empty-argument-keeps-position: $c" "card #14 is in Human QA"
done
CFG_REPO="$REPO"
NOCFG="$(mktemp -d)"; CLEANUP_DIRS+=("$NOCFG")
HOME_SAVE="$HOME"
HOME="$NOCFG"
# cd "" stays where it is (bash 3.2 and later); it is not cd $HOME
run_hook bash.json 'cd "" && gh pr merge 4'
assert_blocked "empty-argument-keeps-position: cd \"\" stays in the board repo" "merge.policy is human"
HOME="$HOME_SAVE"
setup_case labels-auto
pr_routes > "$ROUTES"
run_hook bash.json 'gh pr merge --subject "" 5'
assert_blocked "empty-argument-keeps-position: merge --subject \"\" 5" "PR #5 checks are not green"

# conditional-cd-keeps-old-directory: a cd inside if/while/until/for/select,
# a { } group or a function body may not run, so the old directory stays
# possible; after the compound command closes, a cd is definite again
setup_case labels-human
card_routes > "$ROUTES"
NOCFG="$(mktemp -d)"; CLEANUP_DIRS+=("$NOCFG")
HOME_SAVE="$HOME"
HOME="$NOCFG"
for c in "if false; then cd $NOCFG; fi; gh pr merge 4" \
         "if false; then :; else cd $NOCFG; fi; gh pr merge 4" \
         "while false; do cd $NOCFG; done; gh pr merge 4" \
         "until true; do cd $NOCFG; done; gh pr merge 4" \
         "for d in; do cd $NOCFG; done; gh pr merge 4" \
         "select d in; do cd $NOCFG; done; gh pr merge 4" \
         "false && { :; cd $NOCFG; }; gh pr merge 4" \
         "f() { :; cd $NOCFG; }; gh pr merge 4" \
         $'if false\nthen\n  cd '"$NOCFG"$'\nfi\ngh pr merge 4' \
         "bash -c 'if false; then cd $NOCFG; fi; gh pr merge 4'" \
         "pushd; gh pr merge 4"; do
  run_hook bash.json "$c"
  assert_blocked "conditional-cd-keeps-old-directory: $c" "merge.policy is human"
done
HOME="$HOME_SAVE"
rm -f "$FAKE_GH_DIR/calls.log"
for c in "if true; then :; fi; cd $NOCFG && gh pr merge 4" \
         "while false; do :; done
cd $NOCFG && board-move.sh 14 done"; do
  run_hook bash.json "$c"
  assert_silent_allow "conditional-cd-keeps-old-directory: after the compound closes: $c"
done
assert_no_calls "conditional-cd-keeps-old-directory: nothing read after a definite cd"

# cd-environment-in-command: CDPATH and HOME in the command change where a
# relative, bare or ~ cd goes, so the hook cannot tell the directory
setup_case labels-human
card_routes > "$ROUTES"
CFG_REPO="$REPO"
NOCFG="$(mktemp -d)"; CLEANUP_DIRS+=("$NOCFG")
mkdir -p "$NOCFG/$(basename "$CFG_REPO")" # a decoy without config
RUN_CWD="$NOCFG"
HOME_SAVE="$HOME"
HOME="$NOCFG"
for c in "CDPATH=$(dirname "$CFG_REPO") cd $(basename "$CFG_REPO") && gh pr merge 4" \
         "export CDPATH=$(dirname "$CFG_REPO"); cd $(basename "$CFG_REPO") && gh pr merge 4" \
         "HOME=$CFG_REPO; cd && gh pr merge 4" \
         "export HOME=$CFG_REPO; cd ~ && gh pr merge 4"; do
  run_hook bash.json "$c"
  assert_blocked "cd-environment-in-command: $c" "could not tell which directory"
done
run_hook bash.json "cd ./$(basename "$CFG_REPO") && CDPATH=x gh pr merge 4"
assert_silent_allow "cd-environment-in-command: ./ is never looked up in CDPATH"
HOME="$HOME_SAVE"
RUN_CWD=""

# substitution-in-parameter-expansion: ${x:-$(...)} runs the substitution
setup_case labels-human
card_routes > "$ROUTES"
for c in 'echo ${x:-$(gh pr merge 4)}' \
         'echo ${x:-`gh pr merge 4`}' \
         'echo "${x:-$(gh pr merge 4)}"'; do
  run_hook bash.json "$c"
  assert_blocked "substitution-in-parameter-expansion: $c" "merge.policy is human"
done
run_hook bash.json ': ${x:=$(board-move.sh 14 done)}'
assert_blocked "substitution-in-parameter-expansion: board-move" "card #14 is in Human QA"

# pattern-command-word: a glob or brace in the command word can expand to gh
# or board-move.sh
setup_case labels-human
card_routes > "$ROUTES"
for c in '/usr/bin/g? pr merge 4' 'g[h] pr merge 4' '{gh,} pr merge 4'; do
  run_hook bash.json "$c"
  assert_blocked "pattern-command-word: $c" "merge.policy is human"
done
run_hook bash.json 'bash scripts/board-mov?.sh 14 done'
assert_blocked "pattern-command-word: board-mov?.sh" "card #14 is in Human QA"
run_hook bash.json 'grep -rn merge *.md'
assert_silent_allow "pattern-command-word: a glob argument is not a command word"

# ---------------------------------------------------------------------------
# Review cycle 1 re-check, part 2: holes found while fixing the five above

# a directory really named "" is not an empty word: cd '""' goes there
setup_case labels-human
card_routes > "$ROUTES"
CFG_REPO="$REPO"
NOCFG="$(mktemp -d)"; CLEANUP_DIRS+=("$NOCFG")
ln -s "$CFG_REPO" "$NOCFG/\"\""
RUN_CWD="$NOCFG"
run_hook bash.json "cd '\"\"' && gh pr merge 4"
assert_blocked "empty-argument-keeps-position: cd '\"\"' is a directory named \"\"" "merge.policy is human"
RUN_CWD=""

# gh pr merge "" is a merge of the current branch's PR, like no ARG
setup_case labels-auto
pr_routes > "$ROUTES"
run_hook bash.json 'gh pr merge "" --squash'
assert_blocked "empty-argument-keeps-position: gh pr merge \"\"" "name the PR explicitly"

# pattern-command-word: a brace or bracket that splits the keyword, so the
# text never spells board-move or move.sh
setup_case labels-human
card_routes > "$ROUTES"
for c in 'bash scripts/board-{m,}ove.sh 14 done' 'bash scripts/board-mo[v]e.sh 14 done'; do
  run_hook bash.json "$c"
  assert_blocked "pattern-command-word: $c" "card #14 is in Human QA"
done

# pattern-command-word: a glob that cannot expand to a gated command word is
# an ordinary command (the invalid-config sentinel is never read)
setup_case labels-human
card_routes > "$ROUTES"
export FLEET_BOARD_CONFIG="$CONFIG_FIXTURES/bad-backend.yml"
for c in 'ls *.md && [ -f x ] && echo {a,b}.txt' 'ls scripts/*.sh tests/*.sh' 'wc -l *.sh *.md'; do
  run_hook bash.json "$c"
  assert_silent_allow "pattern-command-word: ordinary globs: $c"
done
run_hook bash.json 'bash scripts/board-mov?.sh 14 done'
assert_blocked "pattern-command-word: the sentinel is read for board-mov?.sh" "invalid"
unset FLEET_BOARD_CONFIG
# a card number with no digit in it: ? can expand to a file named 7
run_hook bash.json 'bash scripts/board-mov?.sh ? done'
assert_blocked "pattern-command-word: board-mov?.sh ? done" "could not verify card"

# pattern-command-word: board-move reached through a substitution or a
# variable in the command word, with a card number
setup_case labels-human
card_routes > "$ROUTES"
for c in '"$(command -v board-move.sh)" 14 done' '${D}board-mov?.sh 14 done' '`which board-move.sh` 14 done'; do
  run_hook bash.json "$c"
  assert_blocked "pattern-command-word: $c" "card #14 is in Human QA"
done

# word-in-pieces-is-a-script: a word written in pieces (escaped blanks,
# adjacent quoted parts) is one script for bash -c or sh; lexing the pieces
# alone misses the command or the cd before it
setup_case labels-human
card_routes > "$ROUTES"
CFG_REPO="$REPO"
NOCFG="$(mktemp -d)"; CLEANUP_DIRS+=("$NOCFG")
for c in 'bash -c gh\ pr\ merge\ 4' 'echo gh\ pr\ merge\ 4 | sh'; do
  run_hook bash.json "$c"
  assert_blocked "word-in-pieces-is-a-script: $c" "merge.policy is human"
done
RUN_CWD="$NOCFG"
for c in "bash -c \"cd $CFG_REPO\""\''; gh pr merge 4'\' \
         "bash -c 'cd '\"$CFG_REPO\"'; gh pr merge 4'"; do
  run_hook bash.json "$c"
  assert_blocked "word-in-pieces-is-a-script: $c" "merge.policy is human"
done
RUN_CWD=""

# compound-closer-must-be-real: only a real, unquoted closer ends an if/while/
# case/{ } in the hook's reading, so a cd after a word that merely looks like
# one is still conditional (the old directory stays possible)
setup_case labels-human
card_routes > "$ROUTES"
NOCFG="$(mktemp -d)"; CLEANUP_DIRS+=("$NOCFG")
for c in "if false; then \"fi\"; cd $NOCFG; fi; gh pr merge 4" \
         "if false; then x=1 fi; cd $NOCFG; fi; gh pr merge 4" \
         "if false; then case x in a|fi) :;; esac; cd $NOCFG; fi; gh pr merge 4" \
         "if false; then [[ x && fi ]]; cd $NOCFG; fi; gh pr merge 4" \
         $'if false; then : # ; fi\ncd '"$NOCFG"$'; fi; gh pr merge 4' \
         $'if false; then cat <<E\nfi\nE\ncd '"$NOCFG"$'; fi; gh pr merge 4' \
         "if false; then coproc x { :; }; cd $NOCFG; fi; gh pr merge 4" \
         "if false; then function g { :; }; cd $NOCFG; fi; gh pr merge 4"; do
  run_hook bash.json "$c"
  assert_blocked "compound-closer-must-be-real: $c" "merge.policy is human"
done

# compound-closer-must-be-real: a comment, here-document or [[ spelled with
# $'...' escapes is a comment for the bash -c that runs it
setup_case labels-human
card_routes > "$ROUTES"
NOCFG="$(mktemp -d)"; CLEANUP_DIRS+=("$NOCFG")
for c in "bash -c \$'if false; then : \\x23 ; fi\\ncd $NOCFG; fi; gh pr merge 4'" \
         "bash -c \$'if false; then cat \\x3c\\x3cE\\nfi\\nE\\ncd $NOCFG; fi; gh pr merge 4'"; do
  run_hook bash.json "$c"
  assert_blocked "compound-closer-must-be-real: $c" "merge.policy is human"
done

# repeated-cd: a relative cd in a loop, or anywhere once a function is
# defined, can run any number of times; a function or trap body runs later,
# after the cds that follow it. The directory is unknown.
setup_case labels-human
card_routes > "$ROUTES"
CFG_REPO="$REPO"
NOCFG="$(mktemp -d)"; CLEANUP_DIRS+=("$NOCFG")
mkdir -p "$NOCFG/sub"
ln -s "$CFG_REPO" "$NOCFG/sub/sub" # two cds down is the board repo
RUN_CWD="$NOCFG"
for c in "for i in 1 2; do cd sub; done; gh pr merge 4" \
         "while cd sub; do :; done; gh pr merge 4" \
         "f() { cd sub; }; f; f; gh pr merge 4" \
         "f() { gh pr merge 4; }; cd $CFG_REPO && f" \
         "function f { gh pr merge 4; }; cd $CFG_REPO && f" \
         "trap 'gh pr merge 4' EXIT; cd $CFG_REPO"; do
  run_hook bash.json "$c"
  assert_blocked "repeated-cd: $c" "could not tell which directory"
done
RUN_CWD=""

# cd-command-word: cd reached through a prefix the hook must skip, or through
# a command word it cannot read
setup_case labels-human
card_routes > "$ROUTES"
CFG_REPO="$REPO"
NOCFG="$(mktemp -d)"; CLEANUP_DIRS+=("$NOCFG")
RUN_CWD="$NOCFG"
for c in "time -p cd $CFG_REPO && gh pr merge 4" \
         "command -p cd $CFG_REPO && gh pr merge 4" \
         "builtin -- cd $CFG_REPO && gh pr merge 4"; do
  run_hook bash.json "$c"
  assert_blocked "cd-command-word: $c" "merge.policy is human"
done
for c in "c=cd; \$c $CFG_REPO && gh pr merge 4" \
         "\${x:-cd} $CFG_REPO && gh pr merge 4" \
         "c? $CFG_REPO && gh pr merge 4"; do
  run_hook bash.json "$c"
  assert_blocked "cd-command-word: $c" "could not tell which directory"
done
RUN_CWD=""
run_hook bash.json "command -v cd $NOCFG; gh pr merge 4"
assert_blocked "cd-command-word: command -v does not run cd" "merge.policy is human"
rm -f "$FAKE_GH_DIR/calls.log"
RUN_CWD="$NOCFG"
run_hook bash.json "\"\$S/board-move.sh\" 14 in_progress && \"\$S/board-move.sh\" 14 ready"
assert_silent_allow "cd-command-word: a script path from a variable is not cd"
RUN_CWD=""

# possible-directories-are-bounded: each cd that may or may not run doubles
# the possible directories; past a limit the hook blocks at once instead of
# running into the 60 s hook timeout (past which the call would proceed)
setup_case labels-human
card_routes > "$ROUTES"
NOCFG="$(mktemp -d)"; CLEANUP_DIRS+=("$NOCFG")
mkdir -p "$NOCFG/a"
c="cd a"; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do c="$c | cd a"; done
RUN_CWD="$NOCFG"
HOOK_LIMIT=10
run_hook bash.json "$c; gh pr merge 4"
assert_blocked "possible-directories-are-bounded: 21 piped cds" "could not tell which directory"
assert_fast "possible-directories-are-bounded: decided in time" 5
RUN_CWD=""
HOOK_LIMIT=""

# cd-environment-outside-command: CDPATH from the session, HOME unset, and
# BASH_ENV (a file bash runs first, which may cd)
setup_case labels-human
card_routes > "$ROUTES"
CFG_REPO="$REPO"
NOCFG="$(mktemp -d)"; CLEANUP_DIRS+=("$NOCFG")
mkdir -p "$NOCFG/$(basename "$CFG_REPO")"
RUN_CWD="$NOCFG"
export CDPATH="$(dirname "$CFG_REPO")"
run_hook bash.json "cd $(basename "$CFG_REPO") && gh pr merge 4"
assert_blocked "cd-environment-outside-command: CDPATH in the session" "could not tell which directory"
unset CDPATH
HOME_SAVE="$HOME"
unset HOME
run_hook bash.json "cd && gh pr merge 4"
assert_blocked "cd-environment-outside-command: HOME unset" "could not tell which directory"
export HOME="$HOME_SAVE" # unset dropped the export
printf 'cd %s\n' "$CFG_REPO" > "$NOCFG/env.sh"
run_hook bash.json "BASH_ENV=$NOCFG/env.sh bash -c 'gh pr merge 4'"
assert_blocked "cd-environment-outside-command: BASH_ENV" "BASH_ENV in the command"
RUN_CWD=""

# cd-environment-in-command: HOME set under a name the hook cannot read, or
# spelled with $'...'
setup_case labels-human
card_routes > "$ROUTES"
CFG_REPO="$REPO"
NOCFG="$(mktemp -d)"; CLEANUP_DIRS+=("$NOCFG")
RUN_CWD="$NOCFG"
HOME_SAVE="$HOME"
HOME="$NOCFG"
for c in 'v=HO; export "${v}ME='"$CFG_REPO"'"; cd && gh pr merge 4' \
         "export \$'\\x48OME'=$CFG_REPO; cd ~ && gh pr merge 4"; do
  run_hook bash.json "$c"
  assert_blocked "cd-environment-in-command: $c" "could not tell which directory"
done
HOME="$HOME_SAVE"
RUN_CWD=""

# cd-environment-in-command: a value the hook cannot read is not a name, so
# export PATH="$PATH:..." and printf "$x" do not make a relative cd unknown
setup_case labels-human
card_routes > "$ROUTES"
NOCFG="$(mktemp -d)"; CLEANUP_DIRS+=("$NOCFG")
mkdir -p "$NOCFG/sub"
RUN_CWD="$NOCFG"
run_hook bash.json 'export PATH="$PATH:/x"; local y="$1"; cd sub && printf "%s\n" "$x" && gh pr merge 4'
assert_silent_allow "cd-environment-in-command: values the hook cannot read"
run_hook bash.json 'printf -v "$v" %s x; cd sub && gh pr merge 4'
assert_blocked "cd-environment-in-command: printf -v with a name the hook cannot read" "could not tell which directory"
RUN_CWD=""

# default-value-as-command: the text of ${x:-...} is a command when the
# expansion is a command word or a bash -c script
setup_case labels-human
card_routes > "$ROUTES"
for c in 'echo; ${x:-gh pr merge 4}' 'bash -c "${x:-gh pr merge 4}"' 'eval ${x:+board-move.sh 14 done}'; do
  run_hook bash.json "$c"
  assert_exit "default-value-as-command: $c: exit 2" 2
done

# ---------------------------------------------------------------------------
# Review cycle 2
# xargs-supplies-move-and-label-words: xargs may supply the card, the state or
# the label name, so the hook cannot read them
setup_case labels-human
card_routes > "$ROUTES"
for c in 'echo 14 | xargs -I% board-move.sh % done' \
         'xargs -I CARD board-move.sh CARD done' \
         'echo ready | xargs -I% board-move.sh 13 %' \
         'echo 13 | xargs -I% board-move.sh % ready' \
         'echo 14 | xargs -I 13 board-move.sh 13 done'; do
  run_hook bash.json "$c"
  assert_blocked "xargs-supplies-move-and-label-words: $c" "could not verify"
done
for c in 'echo fleet:human_qa | xargs gh label delete' \
         'xargs -I% gh label edit % --name x' \
         'gh label list | xargs -n1 gh label delete --yes'; do
  run_hook bash.json "$c"
  assert_blocked "xargs-supplies-move-and-label-words: $c" "state label"
done
run_hook bash.json 'echo x | xargs -I% board-move.sh 14 human_qa'
assert_blocked "xargs-supplies-move-and-label-words: even a literal card and state" "could not verify"

# xargs-supplies-issue-edit-words: the label or the flag comes from xargs
setup_case labels-human
card_routes > "$ROUTES"
for c in 'echo fleet:human_qa | xargs gh issue edit 14 --remove-label' \
         'xargs gh issue edit 14 <<< "--remove-label fleet:human_qa"'; do
  run_hook bash.json "$c"
  assert_blocked "xargs-supplies-issue-edit-words: $c" "could not verify the card gh issue edit changes"
done

# xargs-supplies-merge-words: under auto, xargs may name or append the PR,
# so the PR the hook would check is not the PR that gets merged
setup_case labels-auto
pr_routes > "$ROUTES"
for c in 'echo 14 | xargs -I 4 gh pr merge 4' \
         'echo --admin | xargs gh pr merge 4' \
         'printf "4\n5\n" | xargs -n1 -I% gh pr merge %'; do
  run_hook bash.json "$c"
  assert_blocked "xargs-supplies-merge-words: $c" "under xargs"
done
setup_case labels-human
card_routes > "$ROUTES"
run_hook bash.json 'echo 14 | xargs -I 4 gh pr merge 4'
assert_blocked "xargs-supplies-merge-words: human policy keeps its reason" "merge.policy is human"

# missing-cwd: a payload without an absolute cwd cannot place a gated command
setup_case labels-human
card_routes > "$ROUTES"
for e in 'del(.cwd)' '.cwd=null' '.cwd="."' '.cwd="sub"'; do
  PAYLOAD_EDIT="$e"
  run_hook bash.json "gh pr merge 4"
  case "$e" in
    del*|*null) assert_blocked "missing-cwd: $e" "cwd (none)" ;;
    *) assert_blocked "missing-cwd: $e" "is not absolute" ;;
  esac
  run_hook bash.json "ls -la"
  assert_silent_allow "missing-cwd: $e: ordinary command"
done
unset PAYLOAD_EDIT

# lookup-budget-capped: FLEET_BOARD_GATE_TIMEOUT cannot push the lookup
# budget past 50 s, inside Claude Code's 60 s hook timeout. bash takes
# SECONDS from the environment, so a hook started at SECONDS=48 has 2 s left
# of a 50 s budget: a lookup stalled for 6 s times out at once, where a 999 s
# budget would wait for it and let the merge through.
SECS_BASH="$(mktemp -d)"; CLEANUP_DIRS+=("$SECS_BASH")
setup_case labels-auto
pr_routes > "$ROUTES"
stall_gh "pr view*" 6
for v in "999 48" "59 48" "99999999999999999999 48" "abc 43" "0 43"; do
  export FLEET_BOARD_GATE_TIMEOUT="${v% *}"
  printf '#!/bin/sh\nSECONDS=%s exec %s "$@"\n' "${v#* }" "$BASH_EXE" > "$SECS_BASH/bash"
  chmod +x "$SECS_BASH/bash"
  SAVED_BASH="$BASH_EXE"; BASH_EXE="$SECS_BASH/bash"
  run_hook bash.json "gh pr merge 4"
  BASH_EXE="$SAVED_BASH"
  assert_blocked "lookup-budget-capped: FLEET_BOARD_GATE_TIMEOUT=${v% *} at SECONDS=${v#* }" "timed out"
  assert_fast "lookup-budget-capped: FLEET_BOARD_GATE_TIMEOUT=${v% *}: fast" 5
done
# a leading zero is not octal: 08 once made the budget arithmetic fail and
# the hook exit 0 before any check
setup_case labels-auto
pr_routes > "$ROUTES"
export FLEET_BOARD_GATE_TIMEOUT=08
run_hook bash.json "gh pr merge 5"
assert_blocked "lookup-budget-capped: FLEET_BOARD_GATE_TIMEOUT=08" "checks are not green"
unset FLEET_BOARD_GATE_TIMEOUT

# hooks.json wiring: the harness runs the command string through a shell, so an
# unquoted ${CLAUDE_PLUGIN_ROOT} word-splits on a space in the install path,
# the hook exits 127, and a non-2 PreToolUse exit does not block: every gate
# fails open. Run the literal command string from a plugin root with a space.
HOOKS_JSON="$SCRIPT_DIR/../hooks/hooks.json"
HOOK_CMD="$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[0].command' "$HOOKS_JSON")"
case "$HOOK_CMD" in
  *'"${CLAUDE_PLUGIN_ROOT}/hooks/gate.sh"'*) pass "hooks.json: the gate path is double-quoted" ;;
  *) fail "hooks.json: the gate path is double-quoted" "command is: $HOOK_CMD" ;;
esac
setup_case labels-human
SPACE_ROOT="$(mktemp -d)"
CLEANUP_DIRS+=("$SPACE_ROOT")
mkdir -p "$SPACE_ROOT/plugin cache"
cp -R "$SCRIPT_DIR/.." "$SPACE_ROOT/plugin cache/fleet-board"
LAST_PAYLOAD="$(jq -c --arg c "gh pr merge 4" --arg d "$REPO" '.cwd=$d | .tool_input.command=$c' "$HOOK_FIXTURES/bash.json")"
LAST_OUT="$(CLAUDE_PLUGIN_ROOT="$SPACE_ROOT/plugin cache/fleet-board" sh -c "$HOOK_CMD" 2>"$FAKE_GH_DIR/space.err" <<<"$LAST_PAYLOAD")"
LAST_EXIT=$?
LAST_ERR="$(cat "$FAKE_GH_DIR/space.err")"
assert_blocked "hooks.json: command blocks from a plugin root containing a space" "merge.policy"

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
