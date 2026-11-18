#!/usr/bin/env bash
#
# Plain-bash tests for tick-plan.sh: scope overlap, version bumps, base fetch and the candidates cost pass
# (offline, fake gh; routes under fixtures/gh/tick/<case>/). One of the tick-plan suites
# split from the old single test-tick-plan.sh; the shared helpers are in tick-plan-lib.sh.
#
# Usage: bash plugins/fleet-board/tests/test-tick-plan-scope.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SCRIPT_DIR/tick-plan-lib.sh"

echo "Test: tick-plan.sh (scope, version and fetch)"
echo ""





plan_scope '- Modify `src/a.sh`: another change'
assert_exit "scope-overlap: exit" 0
assert_jq "scope-overlap: a Ready card sharing a path with an in_review card waits" "$(card 14 action)" '"wait"'
assert_jq "scope-overlap: the reason names the other card" "$(card 14 reason | sed 's/^/(/; s/$/ | contains("#12"))/')" 'true'

plan_scope '- Modify `src/b.sh`: another change'
assert_exit "scope-disjoint: exit" 0
assert_jq "scope-disjoint: cards naming different paths start" "$(card 14 action)" '"start"'

plan_scope 'Everything in the card, no file named here.'
assert_exit "scope-none: exit" 0
assert_jq "scope-none: a card in Ready whose Scope yields no paths plans wait" "$(card 14 action)" '"wait"'
assert_jq "scope-none: the reason is Scope lists no paths" "$(card 14 reason)" '"Scope lists no paths"'

plan_scope NONE
assert_jq "scope-none: a card in Ready with no Scope section plans wait" "$(card 14 action)" '"wait"'
assert_jq "scope-none: no Scope section gives the reason Scope lists no paths" "$(card 14 reason)" '"Scope lists no paths"'

declared_14() { printf '(.candidates[] | select(.number == 14)).declared_paths'; }

cand_scope "$(printf -- '- plugins/fleet-board/scripts/a.sh\n- New plugins/fleet-board/tests/test-a.sh (runs the harness)')"
assert_exit "plain-scope: exit" 0
assert_jq "plain-scope: bullet lines with plain-text paths plan both declared_paths" "$(declared_14)" '["plugins/fleet-board/scripts/a.sh","plugins/fleet-board/tests/test-a.sh"]'

cand_scope "$(printf -- '- plugins/a/b.sh\n- c.json (notes)')"
assert_jq "plain-scope: unbackticked plugins/a/b.sh and c.json (notes) plan declared_paths c.json and plugins/a/b.sh" "$(declared_14)" '["c.json","plugins/a/b.sh"]'

cand_scope "$(printf -- '- `plugins/a/b.sh`\n- c.json (notes)')"
assert_jq "plain-scope: a Scope mixing a backticked path and a bare path shows both in declared_paths" "$(declared_14)" '["c.json","plugins/a/b.sh"]'

cand_scope 'plugins/x/a.sh, plugins/x/b.json'
assert_jq "plain-scope: a comma-separated line without a bullet yields both paths, no trailing comma" "$(declared_14)" '["plugins/x/a.sh","plugins/x/b.json"]'

cand_scope '- Version bump in plugins/fleet-board/.claude-plugin/plugin.json and .claude-plugin/marketplace.json'
assert_jq "plain-scope: a prose line yields exactly its two paths and no prose word" "$(declared_14)" '[".claude-plugin/marketplace.json","plugins/fleet-board/.claude-plugin/plugin.json"]'

cand_scope '- docs/x/specs/ (new spec)'
assert_jq "plain-scope: a token ending in / is a directory scope" "$(declared_14)" '["docs/x/specs/"]'

cand_scope '- Modify `src/a.sh`: the change
- Also `src/b.sh` and `docs/`'
assert_jq "plain-scope: a card with only backticked paths yields the same declared_paths" "$(declared_14)" '["docs/","src/a.sh","src/b.sh"]'

# Two Ready cards naming the same file in plain text: one start, one wait
setup_case ready-start
dir="$FAKE_GH_DIR/scope"; mkdir -p "$dir"
scope_issue "$dir" 14 ready '- src/shared.sh'
scope_issue "$dir" 15 ready '- Modify src/shared.sh (again)'
scope_routes "$dir" "14 15" ""
run_check "$SCRIPT"
assert_jq "plain-scope: the lower card starts" "$(card 14 action)" '"start"'
assert_jq "plain-scope: the other card with the same plain-text file waits" "$(card 15 action)" '"wait"'
assert_jq "plain-scope: the wait reason names the overlap" "$(card 15 reason | sed 's/^/(/; s/$/ | contains("#14") and contains("src\/shared.sh"))/')" 'true'

plan_scope_ignore ""
assert_exit "scope-ignore unset: exit" 0
assert_jq "scope-ignore unset: the Ready card naming a manifest waits" "$(card 14 action)" '"wait"'
plan_scope_ignore "$(printf 'supervisor:\n  scope_ignore: [".claude-plugin/marketplace.json", "plugins/*/.claude-plugin/plugin.json"]')"
assert_exit "scope-ignore: exit" 0
assert_jq "scope-ignore: the Ready card naming only manifests starts" "$(card 14 action)" '"start"'
plan_scope_ignore "$(printf 'supervisor:\n  scope_ignore: ["*.json"]')"
assert_jq "scope-ignore: * does not cross /, so nested manifests still overlap" "$(card 14 action)" '"wait"'

# supervisor.version_files: a review or merge candidate whose PR head version is not
# strictly above the same line on the base plans update_branch
plan_version 0.28.4 "$VERSION_YAML"
assert_exit "version-stale: exit" 0
assert_jq "version-stale: an equal version on the base plans update_branch" "$(card 12 action)" '"update_branch"'
assert_jq "version-stale: the reason says so" "$(card 12 reason) | startswith(\"version not above base\")" 'true'
plan_version 0.29.0 "$VERSION_YAML"
assert_jq "version-stale: a base version above the head plans update_branch" "$(card 12 action)" '"update_branch"'
plan_version 0.28.3 "$VERSION_YAML"
assert_exit "version-above: exit" 0
assert_jq "version-above: a head version above the base is not held" "$(card 12 action) | . != \"update_branch\"" 'true'
plan_version 0.28.4 ""
assert_jq "version-stale without version_files: not checked" "$(card 12 action) | . != \"update_branch\"" 'true'
assert_eq "version-stale without version_files: no fetch" "$(fetch_count fetch)" 0

# supervisor.version_bump: merge - the merge lane raises the version, so a card bound for
# the lane never plans update_branch for "version not above base"; a card bound for Human QA does
plan_version 0.28.4 "$VERSION_MERGE_YAML"
assert_exit "version-bump merge: exit" 0
assert_jq "version-bump merge: a stale version on a lane card plans review or merge" "$(card 12 action) | . == \"review\" or . == \"merge\"" 'true'
plan_version 0.29.0 "$VERSION_MERGE_YAML"
assert_jq "version-bump merge: a base above the head never plans update_branch" "$(card 12 action) | . != \"update_branch\"" 'true'
PV_LABEL=needs-human-qa plan_version 0.28.4 "$VERSION_MERGE_YAML"
assert_jq "version-bump merge: a needs-human-qa card with a stale version plans update_branch" "$(card 12 action)" '"update_branch"'
plan_version 0.28.4 "$VERSION_YAML"
assert_jq "version-bump pr: a stale version still plans update_branch" "$(card 12 action)" '"update_branch"'

# The base is the PR's baseRefName, not origin's default branch
PV_BASE_BRANCH=release; export PV_BASE_BRANCH
plan_version 0.28.4 "$VERSION_YAML"
assert_jq "version-base: an equal version on the PR's base branch plans update_branch" "$(card 12 action)" '"update_branch"'
plan_version 0.28.3 "$VERSION_YAML"
assert_jq "version-base: above the PR's base branch is not held" "$(card 12 action) | . != \"update_branch\"" 'true'
unset PV_BASE_BRANCH

# An earlier merge of the base (with the same bump) does not hide the stale version
PV_EARLY_MERGE=1; export PV_EARLY_MERGE
plan_version 0.28.4 "$VERSION_YAML"
assert_jq "version-early-merge: the branch's own bump equal to the base plans update_branch" "$(card 12 action)" '"update_branch"'
unset PV_EARLY_MERGE

# A merge that took the base's side does not hide the branch's own bump
PV_TAKE_THEIRS=1; export PV_TAKE_THEIRS
plan_version 0.29.0 "$VERSION_YAML"
assert_jq "version-take-theirs: the head equal to the base plans update_branch" "$(card 12 action)" '"update_branch"'
unset PV_TAKE_THEIRS

# A version file the branch touched but removed holds the card (fail closed)
PV_DELETE=1; export PV_DELETE
plan_version 0.28.3 "$VERSION_YAML"
assert_jq "version-deleted file: the card waits" "$(card 12 action)" '"wait"'
assert_jq "version-deleted file: the reason names it" "$(card 12 reason) | contains(\"plugins/fb/.claude-plugin/plugin.json\")" 'true'
unset PV_DELETE

# A head that cannot be read holds the card (fail closed)
PV_HEAD=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef; export PV_HEAD
plan_version 0.28.3 "$VERSION_YAML"
assert_exit "version-unreadable head: exit" 0
assert_jq "version-unreadable head: the card waits" "$(card 12 action)" '"wait"'
assert_jq "version-unreadable head: the reason names what is missing" "$(card 12 reason) | startswith(\"version check needs \")" 'true'
unset PV_HEAD

# The base fetch: only origin <base>, at most once per 60 s
plan_version 0.28.4 "$VERSION_YAML"
assert_eq "version-fetch: the first plan fetches the base" "$(fetch_count '^fetch -q origin main')" 1
assert_eq "version-fetch: it fetches only origin <base>" "$(fetch_count '^fetch -q origin$')" 0
run_check "$SCRIPT"
assert_exit "version-fetch: second plan: exit" 0
assert_jq "version-fetch: second plan still holds the card" "$(card 12 action)" '"update_branch"'
assert_eq "version-fetch: two plans within 60 s fetch once" "$(fetch_count '^fetch -q origin main')" 1

# Three cards eligible to merge: exactly one merge, lowest number first
setup_case in-review-merge-auto "$(printf 'merge:\n  policy: auto')"
dir="$FAKE_GH_DIR/scope"; mkdir -p "$dir"
for n in 12 13 15; do
  scope_issue "$dir" "$n" in_review NONE
  scope_review_note "$dir" "$n"
done
scope_routes "$dir" "" "15 12 13"
run_check "$SCRIPT"
assert_exit "merge-one: exit" 0
assert_jq "merge-one: all three eligible cards plan merge" '[.cards[] | select(.action == "merge") | .number] | sort' '[12,13,15]'
assert_jq "merge-one: none waits with one merge per tick" '[.cards[] | select((.reason // "") | contains("one merge per tick"))] | length' 0

printf '#!/usr/bin/env bash\necho ran >> "%s/ran"\necho fine\nexit 0\n' "$PRE_DIR" > "$PRE_DIR/ok.sh"


for pcase in ready-start in-review-needs-review action-failures-ready-3; do
  plan "$pcase"
  UNSET_OUT="$LAST_OUT"
  rm -f "$PRE_DIR/ran"
  plan "$pcase" "$(printf 'commands:\n  preflight: bash %s/fail.sh' "$PRE_DIR")"
  assert_exit "preflight-fail $pcase: exit" 0
  assert_jq "preflight-fail $pcase: no start, review, fix or other dispatch action" \
    '[.cards[] | select(.action | IN("start","continue_implementor","start_review","review","fix","merge","block","unblock","file_pending","verify_main","finish","update_branch","mark_ready","to_human_qa"))] | length' 0
  assert_jq "preflight-fail $pcase: exactly one warning starts with 'preflight failed:'" \
    '[.warnings[] | select(startswith("preflight failed:"))] | length' 1
  assert_jq "preflight-fail $pcase: the warning holds the command" \
    '[.warnings[] | select(startswith("preflight failed:") and contains("fail.sh"))] | length' 1
  assert_jq "preflight-fail $pcase: the warning holds the last 20 lines of output" \
    '.warnings[] | select(startswith("preflight failed:")) | [contains("preflight line 25"), contains("preflight line 6"), contains("preflight line 5")]' '[true,true,false]'
  assert_jq "preflight-fail $pcase: dispatchable is false" '.dispatchable' 'false'
  assert_eq "preflight-fail $pcase: every card keeps its state" \
    "$(jq -c '[.cards[] | [.number, .state, .round]]' <<<"$LAST_OUT")" \
    "$(jq -c '[.cards[] | [.number, .state, .round]]' <<<"$UNSET_OUT")"
  assert_eq "preflight-fail $pcase: nothing is written to the board" "$(mutating_calls)" "0"
  assert_eq "preflight-fail $pcase: the preflight ran once" "$(wc -l < "$PRE_DIR/ran" | tr -d ' ')" "1"
done

# exit 0: the plan equals the plan with the key unset
for pcase in ready-start in-review-needs-review; do
  plan "$pcase"
  UNSET_OUT="${LAST_OUT//$BASE/BASE}" # the worktree base differs per run
  rm -f "$PRE_DIR/ran"
  plan "$pcase" "$(printf 'commands:\n  preflight: bash %s/ok.sh' "$PRE_DIR")"
  assert_exit "preflight-ok $pcase: exit" 0
  assert_eq "preflight-ok $pcase: plan equals the plan with the key unset" "${LAST_OUT//$BASE/BASE}" "$UNSET_OUT"
  assert_eq "preflight-ok $pcase: the preflight ran once" "$(wc -l < "$PRE_DIR/ran" | tr -d ' ')" "1"
done

# key unset: no preflight command runs (another commands key must not be run)
rm -f "$PRE_DIR/ran"
plan ready-start "$(printf 'commands:\n  test_one: bash %s/ok.sh {file}' "$PRE_DIR")"
assert_exit "preflight-unset: exit" 0
assert_eq "preflight-unset: no command ran" "$([ -e "$PRE_DIR/ran" ] && echo ran || echo none)" "none"
assert_jq "preflight-unset: no preflight warning" '[.warnings[] | select(startswith("preflight"))] | length' 0

# the docs name the key
grep -qF 'commands.preflight' "$SCRIPT_DIR/../docs/config.md" \
  && pass "preflight-docs: docs/config.md names commands.preflight" \
  || fail "preflight-docs: docs/config.md names commands.preflight" "grep -F found nothing"

# A --candidates pass over 20 Ready cards launches few jq processes (cost only: the plan is unchanged)
setup_case ready-start
dir="$FAKE_GH_DIR/perf"; mkdir -p "$dir"
for n in $(seq 21 40); do scope_issue "$dir" "$n" ready "- src/perf-$n.sh"; done
scope_routes "$dir" "$(seq 21 40 | tr '\n' ' ')" ""
candidate_empty_human_qa_route
REAL_JQ="$(command -v jq)"
JQ_SHIM="$FAKE_GH_DIR/jqshim"; mkdir -p "$JQ_SHIM"
JQ_COUNT="$FAKE_GH_DIR/jq-count"; : > "$JQ_COUNT"
printf '#!/bin/sh\necho x >> "%s"\nexec "%s" "$@"\n' "$JQ_COUNT" "$REAL_JQ" > "$JQ_SHIM/jq"
chmod +x "$JQ_SHIM/jq"
store_sync # build the card store first: only the planner pass is counted
PATH="$JQ_SHIM:$PATH"; export PATH
"$BASH_EXE" "$SCRIPT" --candidates > "$FAKE_GH_DIR/perf-out" 2> "$FAKE_GH_DIR/perf-err"
LAST_EXIT=$?
LAST_OUT="$(cat "$FAKE_GH_DIR/perf-out")"; LAST_ERR="$(cat "$FAKE_GH_DIR/perf-err")"
JQ_LAUNCHES="$(wc -l < "$JQ_COUNT" | tr -d ' ')"
PATH="${PATH#"$JQ_SHIM":}"; export PATH
assert_exit "jq launches: the 20-card pass exits 0" 0
assert_jq "jq launches: all 20 cards are planned to start" '[.candidates[] | select(.action == "start")] | length' '20'
if [ "$JQ_LAUNCHES" -le 145 ]; then pass "jq launches: one --candidates pass over 20 Ready cards launches at most 145 jq ($JQ_LAUNCHES)"; else fail "jq launches: one --candidates pass over 20 Ready cards launches at most 145 jq" "launched $JQ_LAUNCHES"; fi


# Card 425: a --candidates row carries the card's repo, else board.repo
cand_scope "- src/a.py"
assert_jq "candidate repo: a card without repo carries board.repo" "(.candidates[] | select(.number == 14)).repo" '"acme/toy"'
setup_case ready-start
dir="$FAKE_GH_DIR/scope"; mkdir -p "$dir"
scope_issue "$dir" 14 ready "- src/a.py"
scope_routes "$dir" "14" ""
candidate_empty_human_qa_route
store_sync
jq '. + {repo: "acme/other"}' "$REPO/.fleet-board/cards/14.json" > "$dir/card-14.tmp" && mv "$dir/card-14.tmp" "$REPO/.fleet-board/cards/14.json"
rm -f "$REPO/.fleet-board/.from-routes" # keep the edited card: store_sync must not rebuild it from the routes
run_check "$SCRIPT" --candidates
assert_jq "candidate repo: a card with repo set carries that repo" "(.candidates[] | select(.number == 14)).repo" '"acme/other"'

# Card 511: every plan row of a stacked card carries stack.ancestors, not only its start
SCRIPTS_ABS="$(cd "$SCRIPT_DIR/../scripts" && pwd)"
STK_START=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
# stk_note <dir> <n> <note JSON>: card n's comments hold that manager note
stk_note() {
  jq -n --arg b "<!-- fleet-board:manager-note -->"$'\n'"### fleet-board manager note"$'\n\n```json\n'"$3"$'\n```\n' \
    '[{id: 1, user: {login: "fleet-bot"}, body: $b, created_at: "2026-01-01T00:00:00Z"}]' > "$1/comments-$2.json"
}
# stk_chain <12's note extras> <10's note extras>: in_review cards 12 (note extras as given), 11 (stack parent 10) and 10
stk_chain() {
  setup_case ready-start "$(printf 'stacking:\n  enabled: true')"
  local dir="$FAKE_GH_DIR/stk" n; mkdir -p "$dir"
  for n in 10 11 12; do scope_issue "$dir" "$n" in_review "- src/c$n.sh"; done
  stk_note "$dir" 10 "$(printf '{"state":"in_review","branch":"fleet/10-card","pr":32,"round":1%s}' "$2")"
  stk_note "$dir" 11 "$(printf '{"state":"in_review","branch":"fleet/11-card","pr":33,"round":1,"stack":{"parent":10,"base":"fleet/10-card","start":"%s"}}' "$STK_START")"
  stk_note "$dir" 12 "$(printf '{"state":"in_review","branch":"fleet/12-card","pr":34,"round":1%s}' "$1")"
  scope_routes "$dir" "" "10 11 12"
  printf '{"state":"OPEN"}\n' > "$dir/pstate.json"
  printf 'pr view 33 --repo acme/toy --json state\t0\t%s/pstate.json\n' "$dir" >> "$dir/routes"
}
STK12=',"stack":{"parent":11,"base":"fleet/11-card","start":"'$STK_START'"}'
LR_FIX=',"last_review":{"round":1,"sha":"abc1234","critical":0,"important":1,"findings":[{"severity":"Important","text":"x"}]}'
LR_OK=',"last_review":{"round":1,"sha":"abc1234","critical":0,"important":0,"findings":[]}'
anc12() { printf '(.cards[] | select(.number == 12)) | (.action + " " + (.stack.ancestors | tostring))'; }

stk_chain "$STK12$LR_FIX" ""
run_check "$SCRIPT"
assert_exit "stack-rows: exit" 0
assert_jq "stack-rows: a stacked in_review card with findings plans fix with stack.ancestors [11,10]" "$(anc12)" '"fix [11,10]"'

stk_chain "$STK12" ""
run_check "$SCRIPT"
assert_jq "stack-rows: the review row carries stack.ancestors [11,10]" "$(anc12)" '"review [11,10]"'

stk_chain "$STK12$LR_OK" ""
d="$FAKE_GH_DIR/stk"; printf '{"mergeable":"CONFLICTING"}\n' > "$d/mergeable.json"
{ printf 'pr view 34 --repo acme/toy --json mergeable\t0\t%s/mergeable.json\n' "$d"; cat "$d/routes"; } > "$d/routes2"
FAKE_GH_ROUTES="$d/routes2"; export FAKE_GH_ROUTES
run_check "$SCRIPT"
assert_jq "stack-rows: the update_branch row carries stack.ancestors [11,10]" "$(anc12)" '"update_branch [11,10]"'

stk_chain "$STK12$LR_OK" ""
d="$FAKE_GH_DIR/stk"
jq -n '{number: 11, title: "Card 11", html_url: "u", body: "Work.\n\n## Acceptance\n- it works\n", labels: [{name: "fleet:done"}]}' > "$d/issue-11.json"
run_check "$SCRIPT"
assert_jq "stack-rows: the land row carries stack.ancestors [11,10]" "$(anc12)" '"land [11,10]"'

stk_chain "$LR_FIX" ""
run_check "$SCRIPT"
assert_jq "stack-rows: a card whose note has no stack plans stack null" "$(card 12 action)+\" \"+($(card 12 stack) | tostring)" '"fix null"'

stk_chain "$STK12$LR_FIX" ',"stack":{"parent":11,"base":"fleet/11-card","start":"'$STK_START'"}'
run_check "$SCRIPT"
assert_exit "stack-repeat: a chain that repeats a card exits 0" 0
assert_jq "stack-repeat: the chain stops at the repeat" "$(card 12 stack.ancestors)" '[11,10]'

py_check() {
  local desc="$1" out rc
  out="$(PYTHONDONTWRITEBYTECODE=1 python3 -B -c "$2" "$SCRIPTS_ABS" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then pass "$desc"; else fail "$desc" "$out"; fi
}
PY_FIX='
import sys
sys.path.insert(0, sys.argv[1])
from supervisor.scheduler import Scheduler
LIMITS = {"global": 4, "providers": {"claude": 4}, "per_card": 1}
def fix(n=12, anc=(11, 10)):
    return {"number": n, "action": "fix", "provider": "claude", "declared_paths": ["src/a.py"], "actual_paths": [],
            "scope_complete": True, "priority": "normal", "eligible_since": 0,
            "preconditions": {"state": "in_review", "head_sha": None},
            "stack": {"parent": 11, "base": "fleet/11-card", "ancestors": list(anc)}}
'
py_check "fix-scope: card 12's fix with ancestors [11,10] is not held by cards 11 and 10" "$PY_FIX"'
r = Scheduler(clock=lambda: 0).admit([fix()], reservations=[{"card": 11, "paths": ["src/a.py"]}, {"card": 10, "paths": ["src/a.py"]}], limits=LIMITS)
assert [x["number"] for x in r["admitted"]] == [12], r["waits"]
'
py_check "fix-scope: the same fix is still held by a card outside the chain, a sibling included" "$PY_FIX"'
for other in (20, 13):
    r = Scheduler(clock=lambda: 0).admit([fix()], reservations=[{"card": other, "paths": ["src/a.py"]}], limits=LIMITS)
    assert r["admitted"] == [] and r["waits"][0]["reason"] == "scope reserved by #%d" % other, r
'

tp_finish
