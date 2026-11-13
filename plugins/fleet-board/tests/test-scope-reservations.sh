#!/usr/bin/env bash
#
# Plain-bash tests for tick-plan.sh (offline, fake gh). One scenario per case;
# each has a committed routes file under fixtures/gh/tick/<case>/.
# No framework, no dependencies beyond POSIX tools, jq and git.
#
# Usage: bash plugins/fleet-board/tests/test-tick-plan.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SCRIPT_DIR/store-sync.sh" # the local store, rebuilt from the routes before each run
SCRIPT="${SCRIPT_DIR}/../scripts/tick-plan.sh"
NOTE_SH="${SCRIPT_DIR}/../scripts/note.sh"
TICK="$SCRIPT_DIR/../fixtures/gh/tick"
# The absolute scripts dir, as tick-plan.sh resolves its own (cd && pwd)
SCRIPTS_ABS="$(cd "$SCRIPT_DIR/../scripts" && pwd)"

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

assert_stderr_exact() {
  if [ "$LAST_ERR" = "$2" ]; then pass "$1"; else fail "$1" "expected exact stderr: '$2', got: '$LAST_ERR'"; fi
}

assert_stderr_not_contains() {
  case "$LAST_ERR" in
    *"$2"*) fail "$1" "did not expect '$2' in stderr" ;;
    *) pass "$1" ;;
  esac
}

assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}

run_check() {
  local script="$1"
  shift
  local tmpout tmperr
  store_sync
  tmpout="$(mktemp)"
  tmperr="$(mktemp)"
  "$BASH_EXE" "$script" "$@" > "$tmpout" 2> "$tmperr"
  LAST_EXIT=$?
  LAST_OUT="$(cat "$tmpout")"
  LAST_ERR="$(cat "$tmperr")"
  rm -f "$tmpout" "$tmperr"
}

# jq -c of the last stdout; INVALID when it does not parse
jqc() { jq -c "$1" <<<"$LAST_OUT" 2>/dev/null || echo INVALID; }

# assert_jq <desc> <filter> <expected compact JSON>
assert_jq() { assert_eq "$1" "$(jqc "$2")" "$3"; }

# setup_case <case> [extra YAML appended to the config]
setup_case() {
  REPO="$(mktemp -d)"
  git init -q "$REPO"
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test User"
  {
    printf 'board:\n  repo: acme/toy\n'
    [ -n "${3:-}" ] && printf '%s\n' "$3"
    printf 'worktrees:\n  dir: .fw\n'
    printf 'human_qa_paths: ["src/components/**"]\n'
    [ -n "${2:-}" ] && printf '%s\n' "$2"
  } > "$REPO/.fleet-board.yml"
  git -C "$REPO" add .fleet-board.yml
  git -C "$REPO" commit -q -m "initial"

  FAKE_GH_DIR="$(mktemp -d)"
  BIN="$FAKE_GH_DIR/bin"
  mkdir -p "$BIN"
  ln -s "$SCRIPT_DIR/fake-gh.sh" "$BIN/gh"

  # Reset environment between cases
  unset CDPATH FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT FLEET_BOARD_CONFIG || true
  PATH="$BIN:$ORIG_PATH"
  FAKE_GH_ROUTES="$TICK/$1/routes"
  export FAKE_GH_DIR FAKE_GH_ROUTES PATH

  cd "$REPO"
  BASE="$(mkdir -p "$REPO/.fw" && cd "$REPO/.fw" && pwd -P)"

  CLEANUP_DIRS+=("$REPO")
  CLEANUP_DIRS+=("$FAKE_GH_DIR")
}

# plan <case> [extra YAML]: set up and run tick-plan.sh
plan() { setup_case "$@"; run_check "$SCRIPT"; }

# warns_json <text>...: the compact JSON array of the given warnings
warns_json() { jq -cn '$ARGS.positional' --args "$@"; }

# card <n> <field>: jq path of one card in the plan
card() { printf '(.cards[] | select(.number == %d)).%s' "$1" "$2"; }

# The calls whose argv (one element per line) is exactly the given words
call_count() {
  local want f n=0
  want="$(printf '%s\n' "$@")"
  for f in "$FAKE_GH_DIR"/argv/*; do
    [ -f "$f" ] || continue
    [ "$(cat "$f")" = "$want" ] && n=$((n + 1))
  done
  echo "$n"
}

# scope_issue <dir> <n> <label> <scope section text, or NONE>: writes the issue
scope_issue() {
  local dir="$1" n="$2" label="$3" scope="$4" body
  body="Work."$'\n\n'
  if [ "$scope" != NONE ]; then body="$body## Scope"$'\n'"$scope"$'\n\n'; fi
  body="$body## Acceptance"$'\n'"- it works"$'\n'
  jq -n --argjson n "$n" --arg l "fleet:$label" --arg b "$body" \
    '{number: $n, title: "Card \($n)", html_url: "https://github.com/acme/toy/issues/\($n)", body: $b, labels: [{name: $l}]}' \
    > "$dir/issue-$n.json"
}

# scope_routes <dir> <ready numbers> <in_review numbers> [<stage columns>]:
# routes for those cards. <stage columns> is "review_<name>:<numbers> ...",
# one word per configured stage (cards in a stage column get PR routes too).
scope_routes() {
  local dir="$1" n pr stage_nums="" sc
  for sc in ${4:-}; do stage_nums="$stage_nums ${sc#*:}"; done
  {
    printf 'api user\t0\t%s/labels/user.json\n' "$TICK/.."
    for n in $2 $3 $stage_nums; do
      printf 'api repos/acme/toy/issues/%s\t0\t%s/issue-%s.json\n' "$n" "$dir" "$n"
      if [ -f "$dir/comments-$n.json" ]; then
        printf 'api --paginate repos/acme/toy/issues/%s/comments\t0\t%s/comments-%s.json\n' "$n" "$dir" "$n"
      else
        printf 'api --paginate repos/acme/toy/issues/%s/comments\t0\t%s/common/empty.json\n' "$n" "$TICK"
      fi
    done
    for n in $3 $stage_nums; do
      pr=$((n + 22))
      printf 'pr view %s --repo acme/toy --json isDraft,state,mergedAt,statusCheckRollup,headRefOid\t0\t%s/common/pr-34-open-green.json\n' "$pr" "$TICK"
      printf 'pr view %s --repo acme/toy --json files*\t0\t%s/common/files-plain.json\n' "$pr" "$TICK"
    done
    for st in ready:"$2" in_progress: in_review:"$3" ${4:-} blocked: human_qa:; do
      local col="${st%%:*}" nums="${st#*:}" arr="[]" x
      arr="$(for x in $nums; do jq -cn --argjson n "$x" --arg l "fleet:$col" '{number: $n, title: "Card \($n)", url: "u", labels: [{name: $l}]}'; done | jq -cs '.')"
      printf '%s\n' "$arr" > "$dir/list-$col.json"
      printf 'issue list --repo acme/toy --label fleet:%s *\t0\t%s/list-%s.json\n' "$col" "$dir" "$col"
    done
  } > "$dir/routes"
  FAKE_GH_ROUTES="$dir/routes"; export FAKE_GH_ROUTES
}

# scope_review_note <dir> <n>: a clean round 1 review note for card n, PR n+22
scope_review_note() {
  sed -e "s/fleet\\/12-add-subtract/fleet\\/$2-card/" -e "s/\\\\\"pr\\\\\":34/\\\\\"pr\\\\\":$(($2 + 22))/" \
    "$TICK/in-review-merge-auto/comments-12.json" > "$1/comments-$2.json"
}


echo "Test: scope reservations"
new_scope() {
  setup_case ready-start
  dir="$FAKE_GH_DIR/scope"; mkdir -p "$dir"
}
new_scope
scope_issue "$dir" 12 ready '- Modify `src/a.sh`'
scope_issue "$dir" 13 ready '- Modify `src/a.sh`'
scope_issue "$dir" 14 ready '- Modify `src/b.sh`'
scope_routes "$dir" '14 13 12' ''
run_check "$SCRIPT"
assert_exit "same batch" 0
assert_jq "lower card reserves shared scope" "$(card 12 action)" '"start"'
assert_jq "overlapping start waits" "$(card 13 action)" '"wait"'
assert_jq "reservation reason" "$(card 13 reason)" '"Scope overlaps #12 on src/a.sh"'
assert_jq "disjoint start stays concurrent" "$(card 14 action)" '"start"'

new_scope
scope_issue "$dir" 12 ready '- Modify `src/a.sh` and `src/b.sh`'
scope_issue "$dir" 13 ready '- Modify `src/b.sh` and `src/c.sh`'
scope_issue "$dir" 14 ready '- Modify `src/c.sh`'
scope_routes "$dir" '12 13 14' ''
run_check "$SCRIPT"
assert_jq "waiting card does not reserve additional scope" "$(card 14 action)" '"start"'

new_scope
scope_issue "$dir" 12 in_review '- Modify `src/a.sh`'
scope_review_note "$dir" 12
scope_issue "$dir" 14 ready '- Modify `src/calc.js`'
scope_routes "$dir" '14' '12'
run_check "$SCRIPT"
assert_jq "actual PR paths supplement declared scope" "$(card 14 action)" '"wait"'

new_scope
scope_issue "$dir" 12 in_review '- Modify `src/a.sh`'
scope_review_note "$dir" 12
scope_issue "$dir" 14 ready '- Modify `src/a.sh`'
scope_routes "$dir" '14' '12'
run_check "$SCRIPT"
assert_jq "declared scope remains reserved" "$(card 14 action)" '"wait"'

new_scope
scope_issue "$dir" 12 ready '- Modify `./src/`'
scope_issue "$dir" 13 ready '- Modify `src/nested/a.sh`'
scope_issue "$dir" 14 ready '- Modify `src-other/a.sh`'
scope_routes "$dir" '13 14 12' ''
run_check "$SCRIPT"
assert_jq "directory scope covers descendants" "$(card 13 action)" '"wait"'
assert_jq "directory scope respects path boundaries" "$(card 14 action)" '"start"'

for mode in failed truncated; do
  new_scope
  scope_issue "$dir" 12 in_review '- Modify `src/a.sh`'
  scope_review_note "$dir" 12
  scope_issue "$dir" 14 ready '- Modify `src/unrelated.sh`'
  scope_routes "$dir" '14' '12'
  printf '{"files":[],"changedFiles":2}\n' > "$dir/partial.json"
  code=0; [ "$mode" != failed ] || code=1
  printf 'pr view 34 --repo acme/toy --json files*\t%s\t%s\n' "$code" "$dir/partial.json" | cat - "$FAKE_GH_ROUTES" > "$dir/next-routes"
  mv "$dir/next-routes" "$FAKE_GH_ROUTES"
  run_check "$SCRIPT"
  assert_jq "$mode PR file lookup holds new starts" "$(card 14 action)" '"wait"'
done

# Candidate snapshots must retain Human-QA scope evidence without changing the
# legacy plan's Human-QA actions, and must mark incomplete PR file lists unsafe.
new_scope
scope_issue "$dir" 12 in_review '- Modify `src/a.sh`'
scope_review_note "$dir" 12
scope_issue "$dir" 14 ready '- Modify `src/unrelated.sh`'
scope_routes "$dir" '14' '12'
printf '{"files":[],"changedFiles":2}\n' > "$dir/partial.json"
printf 'pr view 34 --repo acme/toy --json files*\t0\t%s\n' "$dir/partial.json" | cat - "$FAKE_GH_ROUTES" > "$dir/next-routes"
mv "$dir/next-routes" "$FAKE_GH_ROUTES"
run_check "$SCRIPT" --candidates
assert_jq "candidate marks incomplete PR scope evidence" '.candidates[] | select(.number == 12) | .scope_complete' false

new_scope
scope_issue "$dir" 12 human_qa '- Modify `src/a.sh`'
scope_routes "$dir" '' ''
printf '[{"number":12,"title":"Card 12","url":"u","labels":[{"name":"fleet:human_qa"}]}]\n' > "$dir/list-human_qa.json"
printf 'api repos/acme/toy/issues/12\t0\t%s/issue-12.json\n' "$dir" >> "$FAKE_GH_ROUTES"
printf 'api --paginate repos/acme/toy/issues/12/comments\t0\t%s/common/empty.json\n' "$TICK" >> "$FAKE_GH_ROUTES"
printf 'issue list --repo acme/toy --label fleet:human_qa *\t0\t%s/list-human_qa.json\n' "$dir" >> "$FAKE_GH_ROUTES"
run_check "$SCRIPT"
assert_jq "legacy plan still omits Human-QA cards" '.cards | length' '0'
run_check "$SCRIPT" --candidates
assert_jq "candidate retains Human-QA declared scope" '.candidates[] | select(.number == 12) | .declared_paths' '["src/a.sh"]'


for root_first in yes no; do
  new_scope
  if [ "$root_first" = yes ]; then
    scope_issue "$dir" 12 ready '- Modify `./`'
    scope_issue "$dir" 13 ready '- Modify `src/a.sh`'
  else
    scope_issue "$dir" 12 ready '- Modify `src/a.sh`'
    scope_issue "$dir" 13 ready '- Modify `./`'
  fi
  scope_routes "$dir" '13 12' ''
  run_check "$SCRIPT"
  assert_jq "repository root overlap ($root_first)" "$(card 13 action)" '"wait"'
done
new_scope
scope_issue "$dir" 12 in_review '- Modify `./`'
scope_review_note "$dir" 12
scope_issue "$dir" 14 ready '- Modify `src/unrelated.sh`'
scope_routes "$dir" '14' '12'
run_check "$SCRIPT"
assert_jq "active repository root scope" "$(card 14 action)" '"wait"'


new_scope
scope_issue "$dir" 12 in_review '- Modify `src/a.sh`'
scope_issue "$dir" 14 ready '- Modify `src/unrelated.sh`'
jq -cn '[{id:555,user:{login:"fleet-bot"},body:"<!-- fleet-board:manager-note -->\n```json\n{\"state\":\"in_review\",\"branch\":\"fleet/12-card\",\"pr\":34,\"round\":1}\n```\n"}]' > "$dir/comments-12.json"
scope_routes "$dir" '14' '12'
printf 'pr view 34 --repo acme/toy --json files*\t1\t-\n' | cat - "$FAKE_GH_ROUTES" > "$dir/next-routes"
mv "$dir/next-routes" "$FAKE_GH_ROUTES"
run_check "$SCRIPT"
assert_jq "unknown scope holds starts" "$(card 14 action)" '"wait"'
assert_jq "unknown scope leaves existing review runnable" "$(card 12 action)" '"review"'
assert_jq "existing work remains dispatchable" '.dispatchable' true

printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
