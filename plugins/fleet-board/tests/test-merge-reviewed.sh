#!/usr/bin/env bash
#
# Plain-bash tests for merge-reviewed.sh (offline: tests/fake-gh.sh answers
# every gh call from a routes file the test builds per case; real scripts do
# the rest). No framework, no dependencies beyond POSIX tools, jq and git.
#
# Usage: bash plugins/fleet-board/tests/test-merge-reviewed.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SCRIPT_DIR/store-sync.sh" # the local store, rebuilt from the routes before each run
SCRIPT="${SCRIPT_DIR}/../scripts/merge-reviewed.sh"
MARK='<!-- fleet-board:manager-note -->'

unset FLEET_BOARD_CONFIG FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT || true

PASS=0
FAIL=0
LAST_EXIT=0
LAST_ERR=""
CLEANUP_DIRS=()
ORIG_PATH="$PATH"
BASH_EXE="bash"; [ -x /bin/bash ] && BASH_EXE="/bin/bash"

cleanup() { for d in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do rm -rf "$d" 2>/dev/null || true; done; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }
assert_exit() { if [ "$LAST_EXIT" = "$2" ]; then pass "$1"; else fail "$1" "expected exit $2, got $LAST_EXIT (stderr: $LAST_ERR)"; fi; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi; }

run_merge() {
  store_sync
  cp "$REPO/.fleet-board/cards/12.json" "$FAKE_GH_DIR/card-12.before" 2>/dev/null || : > "$FAKE_GH_DIR/card-12.before"
  local e; e="$(mktemp)"
  "$BASH_EXE" "$SCRIPT" "$@" > /dev/null 2> "$e" </dev/null
  LAST_EXIT=$?
  LAST_ERR="$(cat "$e")"
  rm -f "$e"
}

# moved_done: 1 when the run moved card 12 to done on the local board, else 0
moved_done() { [ "$(jq -r .state "$REPO/.fleet-board/cards/12.json" 2>/dev/null)" = done ] && ! cmp -s "$REPO/.fleet-board/cards/12.json" "$FAKE_GH_DIR/card-12.before" && echo 1 || echo 0; }
# board_writes: 1 when the run changed card 12's file, else 0
board_writes() { cmp -s "$REPO/.fleet-board/cards/12.json" "$FAKE_GH_DIR/card-12.before" && echo 0 || echo 1; }

cnt() {
  if [ -f "$FAKE_GH_DIR/calls.log" ]; then grep -cF -- "$1" "$FAKE_GH_DIR/calls.log" || true; else echo 0; fi
}

# setup_case <policy> [extra YAML] : a repo whose config has merge.policy <policy>
setup_case() {
  REPO="$(mktemp -d)"
  git init -q "$REPO"
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test User"
  {
    printf 'board:\n  repo: acme/toy\n'
    printf 'worktrees:\n  dir: .fw\n'
    printf 'human_qa_paths: ["src/components/**"]\n'
    printf 'merge:\n  policy: %s\n' "$1"
    [ -n "${2:-}" ] && printf '%s\n' "$2"
  } > "$REPO/.fleet-board.yml"
  git -C "$REPO" add .fleet-board.yml
  git -C "$REPO" commit -q -m "initial"
  FAKE_GH_DIR="$(mktemp -d)"
  FX="$FAKE_GH_DIR/fx"
  mkdir -p "$FX" "$FAKE_GH_DIR/bin"
  FAKE_GH_REAL="$SCRIPT_DIR/fake-gh.sh"; export FAKE_GH_REAL
  unset FAKE_MERGE_QUEUED
  cat > "$FAKE_GH_DIR/bin/gh" <<'GH'
#!/usr/bin/env bash
bash "$FAKE_GH_REAL" "$@"
rc=$?
if [ "$rc" = 0 ] && [ "$1 $2" = 'pr merge' ] && [ "${FAKE_MERGE_QUEUED:-}" != 1 ]; then
  jq '.state="MERGED"' "$FAKE_GH_DIR/fx/pr-$3.json" > "$FAKE_GH_DIR/fx/merged.json"
  mv "$FAKE_GH_DIR/fx/merged.json" "$FAKE_GH_DIR/fx/pr-$3.json"
fi
exit "$rc"
GH
  chmod +x "$FAKE_GH_DIR/bin/gh"
  PATH="$FAKE_GH_DIR/bin:$ORIG_PATH"
  FAKE_GH_ROUTES="$FAKE_GH_DIR/routes"
  export FAKE_GH_DIR FAKE_GH_ROUTES PATH
  # a stand-in for verify-main.sh (it needs a real origin)
  printf '#!/usr/bin/env bash\nprintf '"'"'{"commit":"abc1234","ok":true,"results":[]}\\n'"'"'\n' > "$FX/verify-main.sh"
  FLEET_BOARD_VERIFY_MAIN="$FX/verify-main.sh"
  export FLEET_BOARD_VERIFY_MAIN
  cd "$REPO"
  CLEANUP_DIRS+=("$REPO" "$FAKE_GH_DIR")
  R="$FX/routes-main"
  : > "$R"
  INREV=()
  INSTG=()
  printf '{"login":"fleet-bot"}\n' > "$FX/user.json"
  printf '{"id":9001}\n' > "$FX/created.json"
  route 'issue edit *' 0 -
  route 'issue comment *' 0 -
  route 'api -X POST repos/acme/toy/issues/*/comments *' 0 "$FX/created.json"
  route 'api -X PATCH repos/acme/toy/issues/comments/* *' 0 -
  route 'api user' 0 "$FX/user.json"
  route 'pr merge *' 0 -
  route 'pr ready *' 0 -
}
route() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$R"; }

finalize() {
  local col items='[]' n
  for n in ${INREV[@]+"${INREV[@]}"}; do
    items="$(jq -c --argjson n "$n" '. + [{number:$n, title:"Add subtract", url:"u", labels:[{name:"fleet:in_review"}]}]' <<<"$items")"
  done
  printf '%s\n' "$items" > "$FX/list-in_review.json"
  for col in in_progress; do printf '[]\n' > "$FX/list-$col.json"; done
  local e
  for col in review_security; do
    items='[]'
    for e in ${INSTG[@]+"${INSTG[@]}"}; do
      [ "${e%%:*}" = "$col" ] || continue
      items="$(jq -c --argjson n "${e#*:}" '. + [{number:$n, title:"Add subtract", url:"u", labels:[{name:"fleet:'"$col"'"}]}]' <<<"$items")"
    done
    printf '%s\n' "$items" > "$FX/list-$col.json"
  done
  {
    printf 'issue list --repo acme/toy --label fleet:in_review *\t0\t%s\n' "$FX/list-in_review.json"
    printf 'issue list --repo acme/toy --label fleet:review_security *\t0\t%s\n' "$FX/list-review_security.json"
    cat "$R"
  } > "$FAKE_GH_ROUTES"
}

# card <n> <column> <note json> [listed in in_review: yes|no]
card() {
  local n="$1" col="$2" note="$3"
  jq -cn --argjson n "$n" --arg l "fleet:$col" \
    '{number:$n, title:"Add subtract", html_url:"https://github.com/acme/toy/issues/\($n)",
      body:"Subtract.\n\n## Acceptance\n- subtract(2,5) returns -3\n", labels:[{name:$l}]}' > "$FX/issue-$n.json"
  jq -cn --arg m "$MARK" --arg j "$note" '
    [{id:555,user:{login:"fleet-bot"},
      body:($m + "\n### fleet-board manager note\nState: x\n\n```json\n" + $j + "\n```\n"),
      created_at:"2026-09-28T00:01:00Z"}]' > "$FX/comments-$n.json"
  route "api repos/acme/toy/issues/$n" 0 "$FX/issue-$n.json"
  route "api --paginate repos/acme/toy/issues/$n/comments" 0 "$FX/comments-$n.json"
  case "$col" in review_*) INSTG+=("$col:$n"); return ;; esac
  case "$col:${4:-yes}" in in_review:*|*:yes) INREV+=("$n") ;; esac
}

# pr <pr> <draft> <rollup json> [changed file]
pr() {
  local p="$1" draft="$2" roll="$3" file="${4:-src/calc.js}"
  jq -cn --argjson d "$draft" --argjson r "$roll" \
    '{isDraft:$d, state:"OPEN", mergedAt:null, statusCheckRollup:$r, headRefOid:"abc1234"}' > "$FX/pr-$p.json"
  jq -cn --arg f "$file" '{files:[{path:$f},{path:"test/calc.test.js"}], changedFiles:2}' > "$FX/files-$p.json"
  jq -cn --argjson d "$draft" --argjson r "$roll" '{isDraft:$d, mergeable:"MERGEABLE", statusCheckRollup:$r}' > "$FX/handoff-$p.json"
  route "pr view $p --repo acme/toy --json isDraft,state,mergedAt,statusCheckRollup,headRefOid" 0 "$FX/pr-$p.json"
  route "pr view $p --repo acme/toy --json files*" 0 "$FX/files-$p.json"
  route "pr view $p --repo acme/toy --json isDraft,mergeable,statusCheckRollup" 0 "$FX/handoff-$p.json"
}

CLEAN='{"state":"in_review","branch":"fleet/12-add-subtract","pr":34,"round":1,"last_review":{"round":1,"sha":"abc1234","critical":0,"important":0,"findings":[]}}'
GREEN='[{"conclusion":"SUCCESS"}]'

setup_pair() {
  setup_case auto
  card 12 in_review "$CLEAN"
  card 13 in_review "$(jq -c '.pr=35 | .branch="fleet/13-next"' <<<"$CLEAN")"
  pr 34 false "$GREEN"
  pr 35 false "$GREEN"
  finalize
}

echo "Test: merge-reviewed.sh"
echo ""

if [ "${FLEET_BOARD_TEST_CASE:-}" != ambiguous ]; then
echo "usage"
setup_case auto
finalize
run_merge extra
assert_exit "an argument is a usage error" 2
assert_eq "usage: no gh call" "$(cnt "")" 0

echo "merge.policy auto: a reviewed, non-draft, green PR is merged and its card moves to done"
setup_case auto
card 12 in_review "$CLEAN"
pr 34 false "$GREEN"
finalize
run_merge
assert_exit "auto: exit 0" 0
assert_eq "auto: gh pr merge 34 --squash ran once" "$(cnt "pr merge 34 --repo acme/toy --squash")" 1
assert_eq "auto: never --admin" "$(cnt "--admin")" 0
assert_eq "auto: never --auto" "$(cnt "--auto")" 0
assert_eq "auto: the card moves to done" "$(moved_done)" 1

echo "merge.policy auto: a card in a review stage with a clean stage review is merged"
STAGE_CFG='review:
  stages:
    - name: security
      agent: "acme:security-reviewer"
      model: opus'
setup_case auto "$STAGE_CFG"
card 12 review_security '{"state":"review_security","stage":"security","branch":"fleet/12-add-subtract","pr":34,"round":1,"last_review":{"round":1,"stage":"security","sha":"abc1234","critical":0,"important":0,"findings":[]}}'
pr 34 false "$GREEN"
finalize
run_merge
assert_exit "stage: exit 0" 0
assert_eq "stage: gh pr merge 34 --squash ran once" "$(cnt "pr merge 34 --repo acme/toy --squash")" 1
assert_eq "stage: the card moves to done" "$(moved_done)" 1

echo "merge.policy human: nothing is merged"
setup_case human
card 12 in_review "$CLEAN"
pr 34 false "$GREEN"
finalize
run_merge
assert_exit "human: exit 0" 0
assert_eq "human: no gh pr merge" "$(cnt "pr merge")" 0
assert_eq "human: no board write" "$(board_writes)" 0

echo "a failed merge leaves the card where it is"
setup_case auto
card 12 in_review "$CLEAN"
pr 34 false "$GREEN"
printf 'pr merge *\t1\t-\n' | cat - "$R" > "$R.new" && mv "$R.new" "$R"
finalize
run_merge
assert_exit "failed merge: exit 1" 1
assert_eq "failed merge: no move to done" "$(moved_done)" 0

echo "cases that must never merge"
no_merge() { # <desc> ; the case is already finalized
  run_merge
  assert_eq "$1: no gh pr merge" "$(cnt "pr merge")" 0
  assert_eq "$1: no move to done" "$(moved_done)" 0
}
setup_case auto
card 12 in_review "$CLEAN"
pr 34 true "$GREEN"
finalize
no_merge "draft PR"

setup_case auto
card 12 in_review "$CLEAN"
pr 34 false '[{"conclusion":"FAILURE"}]'
finalize
no_merge "failing check"

setup_case auto
card 12 in_review "$CLEAN"
pr 34 false '[{"status":"IN_PROGRESS","conclusion":""},{"conclusion":"SUCCESS"}]'
finalize
no_merge "pending check"

setup_case auto
card 12 human_qa "$(jq -c '.state = "human_qa"' <<<"$CLEAN")"
pr 34 false "$GREEN"
finalize
no_merge "card in human_qa"

setup_case auto
card 12 human_qa "$(jq -c '.state = "human_qa"' <<<"$CLEAN")" yes
pr 34 false "$GREEN"
finalize
no_merge "card in human_qa even if listed in in_review"

setup_case auto
card 12 in_review "$CLEAN"
pr 34 false "$GREEN" src/components/Button.js
finalize
no_merge "card whose change needs human QA"

setup_case auto
card 12 in_review '{"state":"in_review","branch":"fleet/12-add-subtract","pr":34,"round":1}'
pr 34 false "$GREEN"
finalize
no_merge "PR not yet reviewed"

echo "drain two reviewed cards, replan and pin each merge head"

setup_pair
run_merge
assert_exit "drain: exit 0" 0
assert_eq "drain: first merged once" "$(cnt "pr merge 34 ")" 1
assert_eq "drain: second merged once" "$(cnt "pr merge 35 ")" 1
assert_eq "drain: exact planned heads bound" "$(cnt --match-head-commit)" 2

setup_pair
cat > "$FLEET_BOARD_VERIFY_MAIN" <<'VERIFY'
#!/usr/bin/env bash
# First integration changes the second PR: the old approval must not merge it.
jq '.headRefOid="def5678"' "$FAKE_GH_DIR/fx/pr-35.json" > "$FAKE_GH_DIR/fx/next.json"
mv "$FAKE_GH_DIR/fx/next.json" "$FAKE_GH_DIR/fx/pr-35.json"
printf '{"commit":"abc1234","ok":true,"results":[]}\n'
VERIFY
run_merge
assert_eq "drain: replan prevents stale second approval" "$(cnt "pr merge 35 ")" 0

setup_pair
printf 'pr merge 34 *\t1\t-\n' | cat - "$FAKE_GH_ROUTES" > "$FX/new-routes"
mv "$FX/new-routes" "$FAKE_GH_ROUTES"
run_merge
assert_exit "failed candidate: exit 1" 1
assert_eq "failed candidate: attempted once" "$(cnt "pr merge 34 ")" 1
assert_eq "failed candidate: unrelated merge proceeds" "$(cnt "pr merge 35 ")" 1

for result in false null '"true"'; do
  setup_pair
  cat > "$FLEET_BOARD_VERIFY_MAIN" <<VERIFY
#!/bin/sh
printf '%s\n' '{"commit":"abc1234","ok":$result,"results":[]}'
VERIFY
  run_merge
  assert_exit "verification $result: fatal stop" 3
  assert_eq "verification $result: no done" "$(moved_done)" 0
  assert_eq "verification $result: no second merge" "$(cnt 'pr merge 35 ')" 0
done

setup_pair
printf '#!/bin/sh\nexit 1\n' > "$FLEET_BOARD_VERIFY_MAIN"
run_merge
assert_exit "verification command error: fatal stop" 3
assert_eq "verification error: no second merge" "$(cnt 'pr merge 35 ')" 0

setup_pair
# Recovery must verify an earlier merged PR before admitting another merge.
jq '.state="MERGED"' "$FX/pr-34.json" > "$FX/merged.json"
mv "$FX/merged.json" "$FX/pr-34.json"
cat > "$FLEET_BOARD_VERIFY_MAIN" <<VERIFY
#!/bin/sh
printf '%s\n' '{"commit":"abc1234","ok":false,"results":[]}'
VERIFY
run_merge
assert_exit "pending verification: fatal stop" 3
assert_eq "pending verification: no new merge" "$(cnt 'pr merge ')" 0

setup_pair
FLEET_BOARD_MERGE_LIMIT=1 run_merge
assert_eq "merge budget: one merge" "$(cnt 'pr merge ')" 1


setup_case auto
card 12 in_review "$(jq -c '.main_check={commit:"abc1234",ok:false,results:[]}' <<<"$CLEAN")"
pr 34 false "$GREEN"
jq '.state="MERGED"' "$FX/pr-34.json" > "$FX/merged.json"
mv "$FX/merged.json" "$FX/pr-34.json"
finalize
store_sync
plan="$(bash "$SCRIPT_DIR/../scripts/tick-plan.sh" --settle-merge 12)"
assert_eq "failed recorded verification: recover rather than finish" "$(jq -r '.cards[0].action' <<<"$plan")" verify_main

fi
echo "ambiguous merge failure recovers before another merge"
setup_pair
rm "$FAKE_GH_DIR/bin/gh"
cat > "$FAKE_GH_DIR/bin/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1 $2 ${3:-}" = 'pr merge 34' ]; then
  jq '.state="MERGED"' "$FAKE_GH_DIR/fx/pr-34.json" > "$FAKE_GH_DIR/fx/merged.json"
  mv "$FAKE_GH_DIR/fx/merged.json" "$FAKE_GH_DIR/fx/pr-34.json"
fi
exec bash "$FAKE_GH_REAL" "$@"
GH
chmod +x "$FAKE_GH_DIR/bin/gh"
printf 'pr merge 34 *\t1\t-\n' | cat - "$FAKE_GH_ROUTES" > "$FX/new-routes"
mv "$FX/new-routes" "$FAKE_GH_ROUTES"
cat > "$FLEET_BOARD_VERIFY_MAIN" <<'VERIFY'
#!/bin/sh
printf '%s\n' '{"commit":"abc1234","ok":false,"results":[]}'
VERIFY
FAKE_GH_REAL="$SCRIPT_DIR/fake-gh.sh" run_merge
assert_exit "ambiguous merge: red main stops" 3
assert_eq "ambiguous merge: no second merge" "$(cnt 'pr merge 35 ')" 0

setup_pair
FAKE_MERGE_QUEUED=1 run_merge
assert_exit "queue acceptance is not a completed merge" 3
assert_eq "queued PR never marked done" "$(moved_done)" 0
assert_eq "queued PR stops later merges" "$(cnt 'pr merge 35 ')" 0

setup_case auto
card 12 in_review "$(jq -c '.action_failures=10 | .main_check={commit:"abc1234",ok:false,results:[]} | .pending_followups={pr:34,bugs:[],out_of_scope:[]}' <<<"$CLEAN")"
pr 34 false "$GREEN"
jq '.state="MERGED"' "$FX/pr-34.json" > "$FX/merged.json"
mv "$FX/merged.json" "$FX/pr-34.json"
finalize
store_sync
plan="$(bash "$SCRIPT_DIR/../scripts/tick-plan.sh" --settle-merge 12)"
assert_eq "verification precedes failure blocks and followups" "$(jq -r '.cards[0].action' <<<"$plan")" verify_main

run_merge
assert_exit "recovered followups: verification succeeds" 0
assert_eq "recovered followups: no duplicate merge" "$(cnt 'pr merge ')" 0
assert_eq "recovered followups: stay in review for filing" "$(moved_done)" 0

echo ""
echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
