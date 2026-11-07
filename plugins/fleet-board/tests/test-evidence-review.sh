#!/usr/bin/env bash
set -eu
unset CDPATH
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${EVIDENCE_REVIEW_SCRIPT:-$HERE/../scripts/evidence-review.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export FLEET_BOARD_LOG_DIR="$TMP/log" FAKE_REVIEWER_SEED="$TMP/seed"
export FAKE_REVIEWER_DIR="$TMP/case" FAKE_REVIEWER_SCRIPT="$TMP/case/actions"
mkdir "$TMP/bin"
cat > "$TMP/bin/gh" <<'GH'
#!/bin/bash
printf 'unexpected gh command: %s\n' "$*" >&2
exit 99
GH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
git init -q --bare "$TMP/origin"
git clone -q "$TMP/origin" "$FAKE_REVIEWER_SEED" 2>/dev/null
git -C "$FAKE_REVIEWER_SEED" checkout -qb main
git -C "$FAKE_REVIEWER_SEED" config user.email test@example.com
git -C "$FAKE_REVIEWER_SEED" config user.name Test
echo base > "$FAKE_REVIEWER_SEED/feature"
git -C "$FAKE_REVIEWER_SEED" add feature
git -C "$FAKE_REVIEWER_SEED" commit -qm base
base="$(git -C "$FAKE_REVIEWER_SEED" rev-parse HEAD)"
git -C "$FAKE_REVIEWER_SEED" push -q origin main
git --git-dir="$TMP/origin" symbolic-ref HEAD refs/heads/main
echo PR > "$FAKE_REVIEWER_SEED/feature"
git -C "$FAKE_REVIEWER_SEED" commit -qam review
head="$(git -C "$FAKE_REVIEWER_SEED" rev-parse HEAD)"
git -C "$FAKE_REVIEWER_SEED" push -q origin HEAD:refs/pull/7/head
git clone -q "$TMP/origin" "$TMP/repo"
cd "$TMP/repo"

config() {
  cat > .fleet-board.yml <<YAML
board: { backend: local, repo: test/toy }
worktrees: { dir: .trees${3:-} }
review: { mutation: true }
models:
  reviewer: $1
  escalation: opus
providers:
  fake: { review_command: "$2" }
YAML
}
reviewer='{ provider: fake, model: test-model, price: { input: 0, output: 0 } }'
command="bash '$HERE/fake-reviewer-cmd.sh' {dir} {model}"
printf '.trees/\n.fleet-board/\n.fleet-board.yml\n' >> .git/info/exclude
printf 'CARD BODY\n' > "$TMP/card"
printf 'PR DIFF\n' > "$TMP/diff"
printf 'IMPLEMENTOR REPORT\n' > "$TMP/impl"
printf '[{"severity":"Important","text":"PRIOR FINDING"},{"severity":"Minor","text":"MINOR FINDING"}]\n' > "$TMP/findings"

report() {
  cat <<REPORT
## Status
clean

## Findings
- none

## For the card
reviewed head: $1

## Acceptance map
- behavior -> test.sh::behavior

## Mutation
$2

## Claim check
skipped: review.verify_claim is off

VERIFIED: \`bash test.sh\` -> 1 test passed
REPORT
}

setup() {
  rm -rf "$FAKE_REVIEWER_DIR" "$FLEET_BOARD_LOG_DIR"
  mkdir -p "$FAKE_REVIEWER_DIR"
  config "$reviewer" "$command"
  report "$head" 'killed: 1 survived: 0 invalid: 0' > "$FAKE_REVIEWER_DIR/good"
  report "$base" 'killed: 1 survived: 0 invalid: 0' > "$FAKE_REVIEWER_DIR/wrong"
  report "$head" 'skipped: review.mutation is off' > "$FAKE_REVIEWER_DIR/skipped"
  printf 'reply good\n' > "$FAKE_REVIEWER_SCRIPT.1"
}
passed=0 failed=0
check() {
  local label="$1"; shift
  if "$@"; then
    printf '  ok   %s\n' "$label"
    passed=$((passed + 1))
  else
    printf '  FAIL %s\n' "$label"
    failed=$((failed + 1))
  fi
}
run() {
  rc=0
  bash "$SCRIPT" "$card" 7 --round 1 --card-file "$TMP/card" --diff-file "$TMP/diff" \
    --impl-report "$TMP/impl" "$@" > "$TMP/out" 2> "$TMP/err" || rc=$?
}
output() { jq -e --arg head "$head" "$1" "$TMP/out" >/dev/null; }
attempts() { [ "$(cat "$FAKE_REVIEWER_DIR/attempt" 2>/dev/null)" = "$1" ]; }
clone_removed() {
  local dir
  dir="$(cat "$FAKE_REVIEWER_DIR/clone")" && [ -n "$dir" ] && [ ! -e "$dir" ]
}

# Seed the local card through the normal board adapter.
mkdir -p .fleet-board/cards
printf "12\n" > .fleet-board/next
config "$reviewer" "$command"
printf '## Acceptance\n- behavior\n' > "$TMP/body"
card="$(bash "$HERE/../scripts/board-create.sh" 'Evidence review fixture' "$TMP/body" | jq -r .number)"
comments() {
  bash "$HERE/../scripts/board-read.sh" "$card" | jq -r '.comments | length'
}

setup
run
check "good report posts the expected head and model" output '.status == "posted" and .sha == $head and .provider == "fake" and .model == "test-model" and .attempts == 1'
check "good report was posted" test "$(comments)" = 1
check "ledger records reviewer" jq -e '.role == "reviewer" and .input_tokens == null and .cost_usd == 0' "$FLEET_BOARD_LOG_DIR/provider-spend.jsonl"
check "provider receives the working directory as dir" test "$(cat "$FAKE_REVIEWER_DIR/cwd")" = "$(cat "$FAKE_REVIEWER_DIR/clone")"
check "round 1 reference is the merge-base" grep -Fq "Review round 1. Reference SHA $base." "$FAKE_REVIEWER_DIR/prompt.1"
check "review prompt requires non-login command tools" grep -Fq 'login=false on every call' "$FAKE_REVIEWER_DIR/prompt.1"
check "review prompt verifies temp helper resolution" grep -Fq 'command -v mktemp' "$FAKE_REVIEWER_DIR/prompt.1"
check "review prompt verifies process helper resolution" grep -Fq 'command -v ps' "$FAKE_REVIEWER_DIR/prompt.1"
check "provider temp directory is inside clone" test "$(cat "$FAKE_REVIEWER_DIR/tmpdir")" = "$(cat "$FAKE_REVIEWER_DIR/clone")/.fleet-board-tmp"
check "provider mktemp file is inside clone" test "$(dirname "$(cat "$FAKE_REVIEWER_DIR/temp-file")")" = "$(cat "$FAKE_REVIEWER_DIR/tmpdir")"
check "provider mktemp directory is inside clone" test "$(dirname "$(cat "$FAKE_REVIEWER_DIR/temp-dir")")" = "$(cat "$FAKE_REVIEWER_DIR/tmpdir")"
check "scratch clone removed" clone_removed

setup
printf 'reply wrong\n' > "$FAKE_REVIEWER_SCRIPT.1"
cp "$FAKE_REVIEWER_SCRIPT.1" "$FAKE_REVIEWER_SCRIPT.2"
run
check "wrong reviewed head exits 6" test "$rc" = 6
check "wrong reviewed head is named" grep -Fq "reviewed head $base is not the PR head $head" "$TMP/err"
check "wrong reviewed head was retried once" attempts 2

setup
printf 'reply skipped\n' > "$FAKE_REVIEWER_SCRIPT.1"
cp "$FAKE_REVIEWER_SCRIPT.1" "$FAKE_REVIEWER_SCRIPT.2"
run
check "skipped mutation exits 6" test "$rc" = 6
check "skipped mutation diagnostic" grep -Fq 'review.mutation is on but the report skipped mutation' "$TMP/err"
check "skipped mutation was retried once" attempts 2

setup
cp "$FAKE_REVIEWER_SCRIPT.1" "$FAKE_REVIEWER_SCRIPT.2"
printf 'reply wrong\n' > "$FAKE_REVIEWER_SCRIPT.1"
run --no-post --round 2 --prev-sha "$head" --findings "$TMP/findings"
check "corrected reply passes on attempt two" output '.status == "checked" and .attempts == 2'
check "re-ask quotes the rejection" grep -Fq 'is not the PR head' "$FAKE_REVIEWER_DIR/prompt.2"
for input in 'CARD BODY' 'PR DIFF' 'IMPLEMENTOR REPORT' 'PRIOR FINDING' "Review round 2. Reference SHA $head."; do
  check "round 2 prompt includes $input" grep -Fq "$input" "$FAKE_REVIEWER_DIR/prompt.1"
done

setup
printf 'write %s/feature\nreply good\n' "$PWD" > "$FAKE_REVIEWER_SCRIPT.1"
run
check "write in main checkout exits 1" test "$rc" = 1
check "tripwire names main checkout" grep -Fq 'changed during the review' "$TMP/err"
git checkout -- feature

setup
printf 'write feature\ncommit\nreply good\n' > "$FAKE_REVIEWER_SCRIPT.1"
run --no-post
check "commit in the scratch clone passes" test "$rc" = 0
check "review worktree stays on reviewed head" test "$(git -C ".trees/$card-review" rev-parse HEAD 2>/dev/null || true)" = "$head"
check "clone with committed change is removed" clone_removed

for action in 'exit 9' 'exit 0' 'sleep 5'; do
  setup
  printf '%s\n' "$action" > "$FAKE_REVIEWER_SCRIPT.1"
  config "${reviewer/model: test-model/model: test-model, timeout: 1}" "$command"
  run
  check "$action exits 1" test "$rc" = 1
  check "$action removes scratch clone" clone_removed
done

setup
sed -i.bak '/^reviewed head: /a\
<!-- fleet-board:manager-note -->
' "$FAKE_REVIEWER_DIR/good"
check "marker fixture passes the report parser" bash -c 'bash "$1" --role reviewer "$2" >/dev/null' _ \
  "$HERE/../scripts/parse-report.sh" "$FAKE_REVIEWER_DIR/good"
run
check "marker in reply exits 1" test "$rc" = 1
check "marker rejected by runner guard" grep -Fq 'reply contains a fleet-board marker' "$TMP/err"
check "failed and checked reviews did not post" test "$(comments)" = 1

setup
config "${reviewer/model: test-model/model: test-model, timeout: 4}" "$command"
printf 'pause 2\nreply wrong\n' > "$FAKE_REVIEWER_SCRIPT.1"
printf 'sleep 6\n' > "$FAKE_REVIEWER_SCRIPT.2"
run
check "retry deadline exits 1" test "$rc" = 1
check "retry shares the first attempt deadline" grep -Eq 'timed out after [12]s|review timeout exhausted' "$TMP/err"
check "retry deadline removes scratch clone" clone_removed
check "retry deadline posts nothing" test "$(comments)" = 1

setup
config "$reviewer" 'fleet-board-missing-reviewer {dir}'
run
check "missing program exits 3" test "$rc" = 3
check "missing program diagnostic" grep -Fq 'fleet-board-missing-reviewer is not on PATH' "$TMP/err"
check "missing program never called" test ! -e "$FAKE_REVIEWER_DIR/clone"

setup
config "$reviewer" "$command" ', setup: "exit 9"'
run
check "setup failure exits 1" test "$rc" = 1
check "setup failure diagnostic" grep -Fq 'evidence-review: setup failed' "$TMP/err"
check "setup failure prevents provider call" test ! -e "$FAKE_REVIEWER_DIR/clone"

setup
config opus "$command"
run
check "string reviewer exits 2" test "$rc" = 2

setup
echo advanced > "$FAKE_REVIEWER_SEED/feature"
git -C "$FAKE_REVIEWER_SEED" commit -qam advance
printf 'push-pr-head\nreply good\n' > "$FAKE_REVIEWER_SCRIPT.1"
run --no-post
check "mid-review push preserves original reviewed sha" output '.sha == $head'
check "fixture pushed a new head" test "$(git --git-dir="$TMP/origin" rev-parse refs/pull/7/head)" != "$head"

printf 'passed: %d   failed: %d\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
