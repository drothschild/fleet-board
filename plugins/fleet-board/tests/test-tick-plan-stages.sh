#!/usr/bin/env bash
#
# Plain-bash tests for tick-plan.sh: review stages: stage columns, advance_stage, review_stage and the gates
# (offline, fake gh; routes under fixtures/gh/tick/<case>/). One of the tick-plan suites
# split from the old single test-tick-plan.sh; the shared helpers are in tick-plan-lib.sh.
#
# Usage: bash plugins/fleet-board/tests/test-tick-plan-stages.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SCRIPT_DIR/tick-plan-lib.sh"

echo "Test: tick-plan.sh (review stages)"
echo ""

# ---------------------------------------------------------------------------
# Review stages: stage columns, advance_stage and review_stage. The config has
# the three stages of fixtures/config/stages.yml (security with max_rounds 2).

# in_review, clean current review, label needs-security-review -> advance_stage
splan stage-advance-from-review
assert_exit "stage-advance: exit" 0
assert_jq "stage-advance: in_review plans review_stage, not advance_stage" "$(card 12 action)" '"review_stage"'
assert_jq "stage-advance: no advance_stage row" "[.cards[] | select(.action == \"advance_stage\")] | length" '0'
assert_jq "stage-advance: entering security" "$(card 12 stage.name)" '"security"'
assert_jq "stage-advance: agent carried" "$(card 12 stage.agent)" '"acme:sec"'
assert_eq "stage-advance: one files lookup (match; no needs-human-qa)" "$(call_count pr view 34 --repo acme/toy --json files,changedFiles)" 1
assert_jq "stage-advance: dispatchable" '.dispatchable' 'true'
# in review_security, note stage security round 1, no last_review -> review_stage
splan stage-review-needed
assert_exit "stage-review: exit" 0
assert_jq "stage-review: action" "$(card 12 action)" '"move_to_review"'
assert_jq "stage-review: reason" "$(card 12 reason)" '"retired column review_security; move back to in_review, keeping reviewed_stages"'
assert_jq "stage-review: model" "$(card 12 stage.model)" '"opus"'
assert_jq "stage-review: dispatchable" '.dispatchable' 'true'
# agent_stage_plan_card_has_null_provider
assert_jq "agent_stage_plan_card_has_null_provider: provider" "$(card 12 stage.provider)" 'null'
assert_jq "agent_stage_plan_card_has_null_provider: agent" "$(card 12 stage.agent)" '"acme:sec"'
assert_jq "stage-review: stage object is the config stage whole" "$(card 12 stage) | keys" \
  '["advisory","agent","brief","label","max_diff_bytes","max_output_tokens","max_rounds","model","name","paths","provider","required_passes","timeout"]'
# no_warning_when_stage_not_acted_on: no card in the provider stage
assert_jq "no_warning_when_stage_not_acted_on: no card in the stage" '.warnings' '[]'
# last_review from in_review (stage null, round 1) does not count
splan stage-stale-record
assert_jq "stage-stale: action" "$(card 12 action)" '"move_to_review"'
assert_jq "stage-stale: reason" "$(card 12 reason)" '"retired column review_security; move back to in_review, keeping reviewed_stages"'
# findings in round 1 of 2 -> fix with stage
splan stage-fix
assert_jq "stage-fix: action" "$(card 12 action)" '"move_to_review"'
assert_jq "stage-fix: stage present" "$(card 12 stage.name)" '"security"'
# findings in round 2 of 2 -> block at the stage's max
splan stage-block
assert_jq "stage-block: action" "$(card 12 action)" '"move_to_review"'
assert_jq "stage-block: reason" "$(card 12 reason)" '"retired column review_security; move back to in_review, keeping reviewed_stages"'
# advisory stage with findings and no later label -> tail (draft PR -> mark_ready)
splan stage-advisory-tail
assert_jq "stage-advisory: action" "$(card 12 action)" '"move_to_review"'
assert_jq "stage-advisory: stage ux" "$(card 12 stage.name)" '"ux"'
# clean in security, ux label present -> advance to ux
splan stage-advance-next
assert_jq "stage-advance-next: action" "$(card 12 action)" '"move_to_review"'
assert_jq "stage-advance-next: ux" "$(card 12 stage.name)" '"security"'
assert_jq "stage-advance-next: reason" "$(card 12 reason)" '"retired column review_security; move back to in_review, keeping reviewed_stages"'
# clean in security, ux label present but reviewed_stages has ux -> tail
splan stage-skip-done
assert_jq "stage-skip-done: not revisited" "$(card 12 action)" '"move_to_review"'
# Re-matching: the PR's current files are matched against every stage's paths
# at each clean, current review, so a file added after routing still routes.
# in_review, no routing label, PR files now include src/auth/login.js
splan stage-rematch-in-review
assert_exit "rematch in_review: exit" 0
assert_jq "rematch in_review: review_stage" "$(card 12 action)" '"review_stage"'
assert_jq "rematch in_review: into security" "$(card 12 stage.name)" '"security"'
assert_eq "rematch in_review: adds no label" "$(grep -c $'\tissue edit' "$FAKE_GH_DIR/calls.log")" 0
# review_ux, clean, security never visited and now matched -> back to security
splan stage-rematch-earlier
assert_jq "rematch earlier stage: advance_stage" "$(card 12 action)" '"move_to_review"'
assert_jq "rematch earlier stage: into security" "$(card 12 stage.name)" '"ux"'
assert_jq "rematch earlier stage: reason" "$(card 12 reason)" '"retired column review_ux; move back to in_review, keeping reviewed_stages"'
# review_ux, clean, security already in reviewed_stages -> not revisited
splan stage-rematch-done
assert_jq "rematch done stage: not revisited" "$(card 12 action)" '"move_to_review"'
# head moved after a clean stage review -> review_stage
splan stage-head-moved
assert_jq "stage-head-moved: action" "$(card 12 action)" '"move_to_review"'
# a card labelled fleet:review_legacy with no such stage in the config: settle plan by number
ssettle stage-not-configured 12
assert_exit "stage-missing: exit 0" 0
assert_jq "stage-missing: action skip" "$(card 12 action)" '"skip"'
assert_jq "stage-missing: not dispatchable" '.dispatchable' 'false'
# settle keeps advance_stage, drops review_stage
ssettle stage-advance-from-review 12
assert_jq "settle: in_review stage review is not advance_stage" "$(card 12 action)" '"skip"'
ssettle stage-review-needed 12
assert_jq "settle: review_stage skipped" "$(card 12 action)" '"skip"'
assert_jq "settle: review_stage waits" "$(card 12 reason)" '"state none is not planned"'
# action_failures rule covers a stage column (note action_failures 3, review.max_rounds 3)
splan stage-action-failures-3
assert_jq "stage failures: block" "$(card 12 action)" '"move_to_review"'
assert_jq "stage failures: reason" "$(card 12 reason)" '"retired column review_security; move back to in_review, keeping reviewed_stages"'

# Provider stages
# review_stage_plan_card_has_provider
splan stage-provider-review
assert_exit "review_stage_plan_card_has_provider: exit" 0
assert_jq "review_stage_plan_card_has_provider: provider" "$(card 12 stage.provider)" '"openai"'
assert_jq "review_stage_plan_card_has_provider: agent null" "$(card 12 stage.agent)" 'null'
assert_jq "review_stage_plan_card_has_provider: model" "$(card 12 stage.model)" '"gpt-test"'
assert_jq "review_stage_plan_card_has_provider: key unset holds as wait" "$(card 12 action)" '"move_to_review"'
assert_jq "review_stage_plan_card_has_provider: hold reason" "$(card 12 reason)" '"retired column review_compliance; move back to in_review, keeping reviewed_stages"'
assert_jq "review_stage_plan_card_has_provider: nothing else dispatchable" '.dispatchable' 'true'
assert_jq "review_stage_plan_card_has_provider: key unset warns" '.warnings' '[]'
# unset_key_warns_once: card 12 review_stage and card 13 fix, both in review_compliance
splan stage-provider-two
assert_jq "unset_key_warns_once: card 12 review_stage held" "$(card 12 action)" '"move_to_review"'
assert_jq "unset_key_warns_once: card 12 hold reason" "$(card 12 reason)" '"retired column review_compliance; move back to in_review, keeping reviewed_stages"'
assert_jq "unset_key_warns_once: dispatchable through the fix" '.dispatchable' 'true'
assert_jq "unset_key_warns_once: card 13 fix" "$(card 13 action)" '"move_to_review"'
assert_jq "unset_key_warns_once: one warning" '.warnings' '[]'
# set_key_no_warning
setup_case stage-provider-two "$STAGES_YAML"
OPENAI_API_KEY=x; export OPENAI_API_KEY
run_check "$SCRIPT"
unset OPENAI_API_KEY
assert_jq "set_key_no_warning: review_stage planned" "$(card 12 action)" '"move_to_review"'
assert_jq "set_key_no_warning: actions unchanged" '[.cards[].action]' '["move_to_review","move_to_review"]'
assert_jq "set_key_no_warning: no warning" '.warnings' '[]'
# an empty variable counts as unset
setup_case stage-provider-two "$STAGES_YAML"
OPENAI_API_KEY=; export OPENAI_API_KEY
run_check "$SCRIPT"
unset OPENAI_API_KEY
assert_jq "empty key warns" '.warnings' '[]'
# no_warning_when_stage_not_acted_on: a clean provider review plans the tail
splan stage-provider-clean
assert_jq "no_warning_when_stage_not_acted_on: action" "$(card 12 action)" '"move_to_review"'
assert_jq "no_warning_when_stage_not_acted_on: no warning" '.warnings' '[]'
# settle: review_stage is skipped there, so no warning
ssettle stage-provider-review 12
assert_jq "no_warning_when_stage_not_acted_on: settle skip" '.warnings' '[]'
# advance_into_provider_stage_warns: the manager runs review_stage right after
# advance_stage, so entering a provider stage with its key unset warns once
splan stage-advance-to-provider
assert_exit "advance_into_provider_stage_warns: exit" 0
assert_jq "advance_into_provider_stage_warns: in_review holds the parallel stage review (key unset), never advance_stage" "$(card 12 action)" '"wait"'
assert_jq "advance_into_provider_stage_warns: stage" "$(card 12 stage.name)" '"compliance"'
assert_jq "advance_into_provider_stage_warns: one warning" '.warnings' "$(warns_json "$COMPLIANCE_WARN")"
setup_case stage-advance-to-provider "$STAGES_YAML"
OPENAI_API_KEY=x; export OPENAI_API_KEY
run_check "$SCRIPT"
unset OPENAI_API_KEY
assert_jq "advance_into_provider_stage_warns: key set, no warning" '.warnings' '[]'
# a failed preflight holds a stage action too (advance_stage into a provider stage)
rm -f "$PRE_DIR/ran"
plan stage-advance-to-provider "$STAGES_YAML
$(printf 'commands:\n  preflight: bash %s/fail.sh' "$PRE_DIR")"
assert_jq "preflight-fail stage-advance-to-provider: held as wait" "$(card 12 action)" '"wait"'
assert_jq "preflight-fail stage-advance-to-provider: dispatchable is false" '.dispatchable' 'false'
assert_jq "preflight-fail stage-advance-to-provider: one preflight warning" '[.warnings[] | select(startswith("preflight failed:"))] | length' 1
# advance into an agent stage never warns
splan stage-advance-from-review
assert_jq "advance into an agent stage: no warning" '.warnings' '[]'

# scope overlap covers stage columns: a Ready card whose Scope names a path a
# card in review_security names waits, as it does for an in_review card
setup_case ready-start "$STAGES_YAML"
dir="$FAKE_GH_DIR/scope"; mkdir -p "$dir"
scope_issue "$dir" 12 review_security '- Modify `src/a.sh`: the change'
scope_issue "$dir" 14 ready '- Modify `src/a.sh`: another change'
scope_review_note "$dir" 12
scope_routes "$dir" "14" "" "review_security:12 review_ux: review_compliance:"
run_check "$SCRIPT"
assert_exit "scope-overlap stage column: exit" 0
assert_jq "scope-overlap stage column: the review_security card is planned" "$(card 12 action) != null" 'true'
assert_jq "scope-overlap stage column: the Ready card waits" "$(card 14 action)" '"wait"'
assert_jq "scope-overlap stage column: the reason names the stage card" "$(card 14 reason)" '"Scope overlaps #12 on src/a.sh"'

# no_stages_no_next_lookup: with no review stages configured, a clean, current
# in_review card never runs review-stages.sh next and plans the old tail. A
# copy of the scripts dir whose review-stages.sh records its call and fails
# stands in for it.
NEXT_STUB="$(mktemp -d)"
CLEANUP_DIRS+=("$NEXT_STUB")
cp -R "$SCRIPT_DIR/../scripts/." "$NEXT_STUB/"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/next-calls"\nexit 1\n' "$NEXT_STUB" > "$NEXT_STUB/review-stages.sh"
setup_case in-review-mark-ready-human
run_check "$NEXT_STUB/tick-plan.sh"
assert_exit "no_stages_no_next_lookup: exit" 0
assert_jq "no_stages_no_next_lookup: old tail" "$(card 12 action)" '"mark_ready"'
assert_eq "no_stages_no_next_lookup: review-stages.sh (match or next) not run" "$([ -e "$NEXT_STUB/next-calls" ] && echo called || echo none)" none
# control: with stages configured the same stub is run (and its failure skips the card)
setup_case stage-advance-from-review "$STAGES_YAML"
run_check "$NEXT_STUB/tick-plan.sh"
assert_jq "no_stages_no_next_lookup control: lookup failed (match runs first)" "$(card 12 reason)" '"lookup failed: review-stages.sh match 34"'
assert_eq "no_stages_no_match_lookup: the stub ran match first" "$(sed -n 1p "$NEXT_STUB/next-calls")" "match 34"
assert_eq "no_stages_no_next_lookup control: stub ran" "$([ -e "$NEXT_STUB/next-calls" ] && echo called || echo none)" called

provider_models='models:
  reviewer: { provider: codex, model: gpt-6-astra, price: { input: 0, output: 0 } }
  escalation: opus'
plan escalation-round2 "$provider_models"
assert_exit "provider reviewer: planner exits 0" 0
assert_jq "provider reviewer: passes merged object through" "$(card 12 models.reviewer)" '{"provider":"codex","model":"gpt-6-astra","timeout":1500}'
assert_jq "provider reviewer: escalation applies to both writers" "$(card 12 models) | [.implementor,.fixer]" '["opus","opus"]'
assert_jq "provider reviewer: no price warning (tokens only)" '.warnings' '[]'
plan escalation-round2 "$provider_models
  implementor: gpt-6-astra"
assert_jq "provider reviewer: shared implementor model warns" '[.warnings[] | select(startswith("implementor and reviewer share model gpt-6-astra"))] | length' 1
plan escalation-round2 "${provider_models/escalation: opus/escalation: gpt-6-astra}"
assert_jq "provider reviewer: shared escalation model warns" '[.warnings[] | select(startswith("escalation and reviewer share model gpt-6-astra"))] | length' 1

setup_case ready-start
candidate_empty_human_qa_route
run_check "$SCRIPT" --candidates
assert_exit "candidate mode: exit" 0
assert_jq "candidate mode: schema version" '.schema_version' '2'
assert_jq "candidate mode: action parity" '.candidates[0].action' '"start"'
assert_jq "candidate mode: preconditions and scope contract" '(.candidates[0] | [has("preconditions"), has("declared_paths"), has("actual_paths"), has("scope_complete"), has("dependencies"), has("stage"), has("head_sha"), has("round"), has("priority"), has("state_revision")])' '[true,true,true,true,true,true,true,true,true,true]'
assert_jq "candidate mode: declared paths" '.candidates[0].declared_paths' '["src/subtract.js"]'
assert_jq "candidate mode: empty actual paths are complete" '(.candidates[0] | [.actual_paths, .scope_complete])' '[[],true]'

# A malformed labels payload from the board-read contract must not silently clear priority metadata.
setup_case ready-start
candidate_empty_human_qa_route
MALFORMED_STUB="$(mktemp -d)"
CLEANUP_DIRS+=("$MALFORMED_STUB")
cp -R "$SCRIPT_DIR/../scripts/." "$MALFORMED_STUB/"
cat > "$MALFORMED_STUB/board-read.sh" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"number":12,"title":"Add subtract","state":"ready","body":"Subtract two numbers.\n\n## Acceptance\n- subtract(2,5) returns -3\n","labels":"malformed","manager_note":null,"comments":[]}
JSON
EOF
chmod +x "$MALFORMED_STUB/board-read.sh"
run_check "$MALFORMED_STUB/tick-plan.sh" --candidates
assert_exit "candidate mode: malformed labels keep planner read successful" 0
assert_jq "candidate mode: malformed labels fail closed" '.candidates[0].action' '"skip"'
assert_jq "candidate mode: malformed labels report attention" '.candidates[0].reason' '"lookup failed: board-read.sh 12 (malformed labels)"'
assert_jq "candidate mode: malformed labels do not start work" '[.candidates[] | select(.action == "start")] | length' '0'

# Candidate rows carry the dispatch fields the full plan row has.
setup_case in-review-fix
candidate_empty_human_qa_route
run_check "$SCRIPT" --candidates
assert_exit "candidates_carry_dispatch_fields: exit" 0
assert_jq "candidates_carry_dispatch_fields: schema version" '.schema_version' '2'
assert_jq "candidates_carry_dispatch_fields: branch" '.candidates[0].branch' '"fleet/12-add-subtract"'
assert_jq "candidates_carry_dispatch_fields: pr" '.candidates[0].pr' '34'
assert_jq "candidates_carry_dispatch_fields: fixer model" '.candidates[0].models.fixer' '"sonnet"'
assert_jq "candidates_carry_dispatch_fields: every field present" '(.candidates[0] | [has("title"),has("state"),has("branch"),has("worktree"),has("pr"),has("models"),has("escalated"),has("findings"),has("waiting_on"),has("needs_human_qa"),has("comment_needed"),has("lint"),has("lint_marker")] | all)' 'true'

plan_note "$CONFLICT_NOTE"
candidate_empty_human_qa_route
run_check "$SCRIPT" --candidates
assert_exit "candidates_carry_conflict_findings: exit" 0
assert_jq "candidates_carry_conflict_findings: first finding" '.candidates[0].findings[0].text' '"merge conflict in src/calc.js"'

run_check "$SCRIPT" --unknown-mode
assert_exit "candidate mode: invalid mode rejected" 2
run_check "$SCRIPT" --candidates --settle-merge 12
assert_exit "candidate mode: cannot combine with settle" 2

# --candidates --card <n>: one card planned alone, the row the board-wide pass prints for it
setup_case in-review-merge-auto "$AUTO"
candidate_empty_human_qa_route
CARD_DIR="$FAKE_GH_DIR/onecard"; mkdir -p "$CARD_DIR"
scope_issue "$CARD_DIR" 14 ready "- src/other.js"
printf '[{"number":14,"title":"Card 14","url":"u","labels":[{"name":"fleet:ready"}]}]\n' > "$CARD_DIR/list-ready.json"
{
  awk -F '\t' -v OFS='\t' -v f="$CARD_DIR/list-ready.json" '$1 ~ /--label fleet:ready/ { $3 = f } { print }' "$FAKE_GH_ROUTES"
  printf 'api repos/acme/toy/issues/14\t0\t%s/issue-14.json\n' "$CARD_DIR"
  printf 'api --paginate repos/acme/toy/issues/14/comments\t0\t%s/common/empty.json\n' "$TICK"
} > "$CARD_DIR/routes"
FAKE_GH_ROUTES="$CARD_DIR/routes"; export FAKE_GH_ROUTES
run_check "$SCRIPT" --candidates
FULL_ROW="$(jq -c '.candidates[] | select(.number == 12)' <<<"$LAST_OUT")"
assert_eq "card mode: the board-wide pass plans the in-review card 12 to merge" "$(jq -r '.action' <<<"$FULL_ROW")" "merge"
CARD_STUB="$(mktemp -d)"
CLEANUP_DIRS+=("$CARD_STUB")
cp -R "$SCRIPT_DIR/../scripts/." "$CARD_STUB/"
READ_LOG="$CARD_STUB/reads.log"; : > "$READ_LOG"
printf '#!/usr/bin/env bash\necho "$1" >> "%s"\nexec bash "%s/board-read.sh" "$@"\n' "$READ_LOG" "$SCRIPTS_ABS" > "$CARD_STUB/board-read.sh"
run_check "$CARD_STUB/tick-plan.sh" --candidates --card 12
assert_exit "card mode: exit" 0
assert_eq "card mode: an in-review card with a clean review prints the row the board-wide pass prints" "$(jq -c '.candidates[] | select(.number == 12)' <<<"$LAST_OUT")" "$FULL_ROW"
assert_jq "card mode: only the named card is in the output" '[.candidates[].number]' '[12]'
assert_eq "card mode: the board-read count for other cards is 0" "$(grep -vcx 12 "$READ_LOG")" "0"
assert_eq "card mode: the named card is read" "$(grep -cx 12 "$READ_LOG")" "1"
run_check "$SCRIPT" --candidates --card
assert_exit "card mode: --card needs a number" 2
run_check "$SCRIPT" --candidates --card abc
assert_exit "card mode: --card needs a numeric card" 2
run_check "$SCRIPT" --candidates --card 12 14
assert_exit "card mode: one card only" 2
setup_case ready-start
candidate_empty_human_qa_route
run_check "$SCRIPT" --candidates
assert_jq "card mode: the board-wide pass plans the Ready card to start" '.candidates[0].action' '"start"'
run_check "$SCRIPT" --candidates --card 12
assert_exit "card mode: a Ready card exits 0" 0
assert_jq "card mode: a Ready card prints wait" '[.candidates[] | select(.number == 12) | .action]' '["wait"]'
assert_jq "card mode: a Ready card never prints start" '[.candidates[] | select(.action == "start")] | length' '0'

# merge.ignore_checks: a red check whose name matches an unexpired entry counts as green
IGN_YAML() { # IGN_YAML <until-lint> <until-legacy>
  printf 'merge:\n  policy: auto\n  ignore_checks:\n    - name: "lint-*"\n      reason: "docs lint is flaky"\n      until: %s\n    - name: "ci/legacy-?int"\n      reason: "legacy status"\n      until: %s\n' "$1" "$2"
}
export FLEET_BOARD_TODAY=2026-11-11
for row in in-review merging; do
  plan $row-ignore-red "$(IGN_YAML 2026-12-31 2026-11-11)"
  assert_jq "$row-ignore: unexpired entries (through today) plan merge" "$(card 12 action)" '"merge"'
  assert_jq "$row-ignore: the planner lists the checks it ignored" "$(card 12 ignored_checks)" \
    '[{"name":"lint-docs","reason":"docs lint is flaky","until":"2026-12-31","state":"red"},{"name":"ci/legacy-lint","reason":"legacy status","until":"2026-11-11","state":"red"}]'
  assert_jq "$row-ignore: no expiry warning" '.warnings' '[]'
  plan $row-ignore-red "$(IGN_YAML 2026-12-31 2026-11-10)"
  assert_jq "$row-ignore-expired: an expired entry no longer counts" "$(card 12 action)" "$([ $row = merging ] && echo '"skip"' || echo '"wait"')"
  assert_jq "$row-ignore-expired: warning names the entry and its date" '.warnings' '["merge.ignore_checks entry ci/legacy-?int expired 2026-11-10"]'
  plan $row-ignore-pending "$(IGN_YAML 2026-12-31 2026-12-31)"
  assert_jq "$row-ignore-pending: a pending check never counts as green" "$(card 12 action)" "$([ $row = merging ] && echo '"skip"' || echo '"wait"')"
  plan $row-ignore-other-red "$(IGN_YAML 2026-12-31 2026-12-31)"
  assert_jq "$row-ignore-other-red: a red check no entry matches still blocks" "$(card 12 action)" "$([ $row = merging ] && echo '"skip"' || echo '"wait"')"
done
# pending: true lets a matching check that is still running count as green
IGN_PENDING_YAML() { # IGN_PENDING_YAML <until>
  printf 'merge:\n  policy: auto\n  ignore_checks:\n    - name: "lint-*"\n      reason: "CI is asynchronous"\n      until: %s\n      pending: true\n    - name: "ci/legacy-?int"\n      reason: "legacy status"\n      until: 2026-12-31\n' "$1"
}
export FLEET_BOARD_TODAY=2026-11-11
for row in in-review merging; do
  plan $row-ignore-pending "$(IGN_PENDING_YAML 2026-12-31)"
  assert_jq "$row-ignore-pending: a pending check an entry with pending: true names counts as green" "$(card 12 action)" '"merge"'
  assert_jq "$row-ignore-pending: the planner lists the pending check it went past" "$(card 12 ignored_checks)" \
    '[{"name":"lint-docs","reason":"CI is asynchronous","until":"2026-12-31","state":"pending"},{"name":"ci/legacy-lint","reason":"legacy status","until":"2026-12-31","state":"red"}]'
  plan $row-ignore-pending "$(IGN_PENDING_YAML 2026-11-10)"
  assert_jq "$row-ignore-pending: an expired pending entry no longer counts" "$(card 12 action)" "$([ $row = merging ] && echo '"skip"' || echo '"wait"')"
  plan $row-ignore-other-red "$(IGN_PENDING_YAML 2026-12-31)"
  assert_jq "$row-ignore-pending: pending: true does not cover a red check it does not name" "$(card 12 action)" "$([ $row = merging ] && echo '"skip"' || echo '"wait"')"
  plan $row-ignore-red "$(IGN_PENDING_YAML 2026-12-31)"
  assert_jq "$row-ignore-pending: a pending: true entry also covers a red check of the same name" "$(card 12 action)" '"merge"'
  assert_jq "$row-ignore-pending: that red check is recorded as red" "$(card 12 ignored_checks)" \
    '[{"name":"lint-docs","reason":"CI is asynchronous","until":"2026-12-31","state":"red"},{"name":"ci/legacy-lint","reason":"legacy status","until":"2026-12-31","state":"red"}]'
done
# The check states are explicit sets: passed, red, pending; anything else is never green.
STAR_YAML() { # STAR_YAML [pending]: one "*" entry, with pending: true when asked
  printf 'merge:\n  policy: auto\n  ignore_checks:\n    - name: "*"\n      reason: "CI is asynchronous"\n      until: 2026-12-31\n'
  [ "${1:-}" = pending ] && printf '      pending: true\n'
  return 0
}
plan in-review-ignore-startup "$AUTO"
assert_jq "check-states: STARTUP_FAILURE and STALE are not green without an entry" "$(card 12 action)" '"wait"'
plan in-review-ignore-startup "$(STAR_YAML)"
assert_jq "check-states: a red-only entry covers STARTUP_FAILURE and STALE" "$(card 12 action)" '"merge"'
plan in-review-ignore-startup "$(STAR_YAML pending)"
assert_jq "check-states: under pending: true, STARTUP_FAILURE and STALE merge" "$(card 12 action)" '"merge"'
assert_jq "check-states: under pending: true, STARTUP_FAILURE and STALE are recorded as red" "$(card 12 ignored_checks)" \
  '[{"name":"e2e","reason":"CI is asynchronous","until":"2026-12-31","state":"red"},{"name":"deploy","reason":"CI is asynchronous","until":"2026-12-31","state":"red"}]'
plan in-review-ignore-weird "$(STAR_YAML pending)"
assert_jq "check-states: an unknown conclusion never merges, even under * with pending: true" "$(card 12 action)" '"wait"'
plan in-review-ignore-noconclusion "$(STAR_YAML pending)"
assert_jq "check-states: COMPLETED with a null conclusion never merges, even under * with pending: true" "$(card 12 action)" '"wait"'
plan in-review-ignore-nameless "$(STAR_YAML pending)"
assert_jq "check-states: a red check with no name is never ignored, even under *" "$(card 12 action)" '"wait"'
unset FLEET_BOARD_TODAY
plan in-review-merge-auto "$AUTO"
assert_jq "ignore_checks: an ordinary merge ignores nothing" "$(card 12 ignored_checks)" '[]'
plan in-review-ignore-red "$(IGN_YAML 2026-12-31 2026-12-31)" 
assert_jq "ignore_checks: case-sensitive glob (unchanged config matches)" "$(card 12 action)" '"merge"'
plan in-review-ignore-red "$(printf 'merge:\n  policy: auto\n  ignore_checks:\n    - name: "LINT-*"\n      reason: r\n      until: 2026-12-31\n')"
assert_jq "ignore_checks: glob matching is case-sensitive" "$(card 12 action)" '"wait"'
export FLEET_BOARD_TODAY=2027-01-01
plan in-review-ignore-red "$(IGN_YAML 2026-12-31 2026-12-31)"
assert_jq "ignore_checks: today is injectable (FLEET_BOARD_TODAY)" "$(card 12 action)" '"wait"'
unset FLEET_BOARD_TODAY

# A keyed refusal leaves pending_merge at the same head: the planner must not re-plan merge every cycle
plan merging-refused "$AUTO"
assert_jq "merge_refusal: a refusal at the current head with no merger decision plans merge_refusal" "$(card 12 action)" '"merge_refusal"'
plan merging-refused-attention "$AUTO"
assert_jq "merge_refusal: a merger attention decision plans skip" "$(card 12 action)" '"skip"'
assert_jq "merge_refusal: attention reason" "$(card 12 reason)" '"merger needs attention; a person decides"'
plan merging-refused-after-retry "$AUTO"
assert_jq "merge_refusal: a refusal after a retry decision plans merge_refusal again" "$(card 12 action)" '"merge_refusal"'
# After a retry decision the merge is planned again, carrying the retry time for the supervisor to hold it
setup_case merging-retry "$AUTO"; run_check "$SCRIPT" --candidates
assert_jq "merge retry: the merge is planned again" '[.candidates[] | select(.number == 12) | .action]' '["merge"]'
assert_jq "merge retry: retry_after is carried" '[.candidates[] | select(.number == 12) | .retry_after]' '["2026-11-11T00:05:00Z"]'
setup_case merging-open-no-marker "$AUTO"; run_check "$SCRIPT" --candidates
assert_jq "merge retry: no marker carries retry_after null" '[.candidates[] | select(.number == 12) | .retry_after]' '[null]'
# Stages are routed per card: a merging card merges once no routed stage remains, and only on a review
# of its last routed (or visited) stage, or a stage-less review when it was routed to none
plan merging-stage-remaining "$(printf '%s\n%s' "$AUTO" "$STAGES_ADVISORY_YAML")"
assert_jq "merging routed stages: a card that visited only the first stage, routed to no other, merges" "$(card 12 action)" '"merge"'
plan merging-routed-first "$(printf '%s\n%s' "$AUTO" "$STAGES_ADVISORY_YAML")"
assert_jq "merging routed stages: a card routed to only the first of two stages merges" "$(card 12 action)" '"merge"'
plan merging-routed-both "$(printf '%s\n%s' "$AUTO" "$STAGES_ADVISORY_YAML")"
assert_jq "merging routed stages: a routed stage remaining plans skip" "$(card 12 action)" '"skip"'
assert_jq "merging routed stages: the remaining stage is named" "$(jq -r "$(card 12 reason)" <<<"$LAST_OUT" | grep -c 'stage ux')" '1'
assert_jq "merging routed stages: reason ends with supervisor decides" "$(jq -r "$(card 12 reason)" <<<"$LAST_OUT" | grep -c 'supervisor decides$')" '1'
plan merging-open-merge "$(printf '%s\n%s' "$AUTO" "$STAGES_ADVISORY_YAML")"
assert_jq "merging routed stages: a card routed to no stage merges on its in_review review" "$(card 12 action)" '"merge"'
setup_case merging-routed-first "$(printf '%s\n%s' "$AUTO" "$STAGES_ADVISORY_YAML")"; run_check "$SCRIPT" --settle-merge 12
assert_jq "merging routed stages: --settle-merge (merge-reviewed.sh) plans the same merge" "$(card 12 action)" '"merge"'
# The human-QA question is asked for every merging card with an open PR, not only after its head moved
plan merging-open-qa "$AUTO"
assert_jq "merging human QA: a PR needing human QA at the reviewed head plans skip" "$(card 12 action)" '"skip"'
assert_jq "merging human QA: needs_human_qa is asked" "$(card 12 needs_human_qa)" 'true'
assert_jq "merging human QA: reason ends with supervisor decides" "$(jq -r "$(card 12 reason)" <<<"$LAST_OUT" | grep -c 'supervisor decides$')" '1'
plan merging-open-merge "$AUTO"
assert_jq "merging human QA: a PR needing none is asked and answers false" "$(card 12 needs_human_qa)" 'false'
plan merging-stage-remaining "$AUTO"
assert_jq "merging last stage: a stage record with no stages configured plans skip" "$(card 12 action)" '"skip"'
plan merging-stage-remaining-evidence "$AUTO"
assert_jq "merging last stage: with no stages configured, a clean evidence record in reviews merges whatever last_review holds" "$(card 12 action)" '"merge"'
plan merging-advisory-last "$(printf '%s\n%s' "$AUTO" "$STAGES_ADVISORY_YAML")"
assert_jq "merging last stage: the last stage's review still merges" "$(card 12 action)" '"merge"'

# --candidates carries the planner's warnings (schema stays 2)
export FLEET_BOARD_TODAY=2026-11-11
setup_case merging-ignore-red "$(IGN_YAML 2026-12-31 2026-11-10)"
run_check "$SCRIPT" --candidates
assert_jq "candidates warnings: schema stays 2" '.schema_version' '2'
assert_jq "candidates warnings: the expired-entry warning is carried" '.warnings' '["merge.ignore_checks entry ci/legacy-?int expired 2026-11-10"]'
setup_case merging-open-merge "$AUTO"
run_check "$SCRIPT" --candidates
assert_jq "candidates warnings: none is an empty list" '.warnings' '[]'
unset FLEET_BOARD_TODAY


# Parallel review: an in_review card with two routed stages plans the evidence
# reviewer and one review_stage per stage at the same head; no advance_stage.
splan parallel-two-stages
assert_exit "parallel: exit" 0
assert_jq "parallel: one review row for the evidence reviewer" "[.cards[] | select(.number == 12 and .action == \"review\")] | length" '1'
assert_jq "parallel: one review_stage row per routed stage" "[.cards[] | select(.number == 12 and .action == \"review_stage\") | .stage.name]" '["security","ux"]'
assert_jq "parallel: every row is at the same head SHA" "[.cards[] | select(.number == 12) | .head_sha] | unique" '["abc1234"]'
assert_jq "parallel: no row is advance_stage" "[.cards[] | select(.number == 12 and .action == \"advance_stage\")] | length" '0'
assert_jq "parallel: dispatchable" '.dispatchable' 'true'
# security already reported at this head: not planned again in the same round
splan parallel-reported-at-head
assert_jq "parallel reported: security is not planned again" "[.cards[] | select(.number == 12 and .action == \"review_stage\") | .stage.name]" '["ux"]'
assert_jq "parallel reported: the evidence reviewer is still planned" "[.cards[] | select(.number == 12 and .action == \"review\")] | length" '1'
assert_jq "parallel reported: no advance_stage" "[.cards[] | select(.number == 12 and .action == \"advance_stage\")] | length" '0'
# A clean evidence review at this head with two routed stages: both stages are planned, never advance_stage
splan parallel-evidence-at-head
assert_jq "parallel evidence: one review_stage row per routed stage" "[.cards[] | select(.number == 12 and .action == \"review_stage\") | .stage.name]" '["security","ux"]'
assert_jq "parallel evidence: no advance_stage row" "[.cards[] | select(.number == 12 and .action == \"advance_stage\")] | length" '0'
assert_jq "parallel evidence: every row is at the same head SHA" "[.cards[] | select(.number == 12) | .head_sha] | unique" '["abc1234"]'
# The loop case: the evidence reviewer reported clean at the head, then a stage did, so last_review
# holds the stage's record. note.reviews keeps both: the evidence reviewer is not planned again,
# and only the stage that has not reported at this head is
splan parallel-stage-after-evidence
assert_jq "stage after evidence: the evidence reviewer is not planned again" "[.cards[] | select(.number == 12 and .action == \"review\")] | length" '0'
assert_jq "stage after evidence: only the unreported stage is planned" "[.cards[] | select(.number == 12 and .action == \"review_stage\") | .stage.name]" '["ux"]'
# Every reviewer reported clean at the head: none is planned again
splan parallel-all-reported
assert_jq "all reported: no reviewer is planned again" "[.cards[] | select(.number == 12 and (.action == \"review\" or .action == \"review_stage\" or .action == \"advance_stage\"))] | length" '0'
assert_jq "all reported: the card still has a row" "[.cards[] | select(.number == 12)] | length" '1'
# An accept.sh baseline in last_review (round 0, stage null) is kept over a reviews.evidence with
# findings at the same head: the card is reviewed at the accepted head, never fixed or blocked on them
splan parallel-accepted-baseline
assert_jq "accepted baseline: the evidence reviewer is planned" "[.cards[] | select(.number == 12 and .action == \"review\")] | length" '1'
assert_jq "accepted baseline: no fix or block on the older findings" "[.cards[] | select(.number == 12 and (.action == \"fix\" or .action == \"block\"))] | length" '0'
# Leaving in_review: a card moves on only when every routed reviewer (the evidence reviewer and each
# routed stage) is clean at the current head. Card 12 routes security (blocking) and ux (advisory).
CARD12_GATED='[.cards[] | select(.number == 12 and (.action == "to_human_qa" or .action == "mark_ready" or .action == "merge" or .action == "advance_stage"))] | length'
splan parallel-all-reported
assert_jq "gate: the card moves to its next state when every routed reviewer is clean at the current head" "$(card 12 action)" '"mark_ready"'
splan gate-one-stage-unreported
assert_jq "gate: the card stays in in_review when the evidence report is clean but one stage has not reported" "[($CARD12_GATED), ([.cards[] | select(.number == 12 and .action == \"review_stage\") | .stage.name])]" '[0,["ux"]]'
splan gate-stage-stale-head
assert_jq "gate: the card stays in in_review when a stage's clean report is for an older head" "[($CARD12_GATED), ([.cards[] | select(.number == 12 and .action == \"review_stage\") | .stage.name])]" '[0,["security"]]'
splan gate-advisory-findings
assert_jq "gate: an advisory stage with findings counts as clean" "$(card 12 action)" '"mark_ready"'

# Card 289: a card found in a retired review_<name> state is planned back to in_review
splan stage-review-needed
assert_exit "retired column: exit" 0
assert_jq "A card found in a review_<name> state is planned back to in_review" "$(card 12 action)" '"move_to_review"'
assert_jq "retired column: dispatchable" '.dispatchable' 'true'

# required_passes: a stage asks for N clean reports at one head. The cases are built here from
# parallel-all-reported: the security stage asks for 3 passes, the PR is open and green, the head is HEAD40.
TICK_REAL="$TICK"
RPT="$(mktemp -d)"; CLEANUP_DIRS+=("$RPT")
ln -s "$TICK_REAL/common" "$RPT/common"
HEAD40=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OLD40=0123456789abcdef0123456789abcdef01234567
rp_rec() { jq -cn --arg s "$1" --argjson p "$2" --argjson i "${3:-0}" '{pass:$p,round:1,sha:$s,critical:0,important:$i,findings:[],stage:"security"}'; }
rp_case() { # <name> <sha of the security records> <passes json array> (the last one is reviews.security)
  local d="$RPT/rp-$1" ev ux note
  mkdir -p "$d"
  sed -e "s/parallel-all-reported/rp-$1/" -e 's|../common/pr-34-draft.json|pr-34.json|' -e "s|../../labels/|$TICK_REAL/../labels/|" "$TICK_REAL/parallel-all-reported/routes" > "$d/routes"
  jq -c --arg h "$HEAD40" '.headRefOid = $h' "$TICK_REAL/common/pr-34-open-green.json" > "$d/pr-34.json"
  ev="$(jq -cn --arg s "$HEAD40" '{round:1,sha:$s,critical:0,important:0,stage:null}')"
  ux="$(jq -cn --arg s "$HEAD40" '{round:1,sha:$s,critical:0,important:0,stage:"ux"}')"
  note="$(jq -cn --argjson ev "$ev" --argjson ux "$ux" --argjson ps "$3" \
    '{state:"in_review",branch:"fleet/12-add-subtract",pr:34,round:1,last_review:$ev,
      reviews:({evidence:$ev,ux:$ux} + (if ($ps | length) > 0 then {security: $ps[-1]} else {} end)),
      review_passes:(if ($ps | length) > 0 then {security:$ps} else {} end)}')"
  jq -cn --arg n "$note" '[{id:501,user:{login:"alice"},body:"Looks good to me.",created_at:"2026-09-28T00:00:00Z"},
       {id:555,user:{login:"fleet-bot"},body:("<!-- fleet-board:manager-note -->\n### fleet-board manager note\nState: x\n\n```json\n"+$n+"\n```\n"),created_at:"2026-09-28T00:01:00Z"}]' \
    > "$d/comments-12.json"
}
RP_YAML="$(printf '%s\n%s' "$AUTO" "$(sed 's/^      max_rounds: 2$/      max_rounds: 2\n      required_passes: 3/' <<<"$STAGES_YAML")")"
rp_plan() { TICK="$RPT"; plan "rp-$1" "$RP_YAML"; TICK="$TICK_REAL"; }
SEC_ROWS='[.cards[] | select(.number == 12 and .action == "review_stage" and .stage.name == "security") | .pass]'
rp_case none "$HEAD40" '[]'
rp_case two "$HEAD40" "[$(rp_rec "$HEAD40" 1),$(rp_rec "$HEAD40" 2)]"
rp_case three "$HEAD40" "[$(rp_rec "$HEAD40" 1),$(rp_rec "$HEAD40" 2),$(rp_rec "$HEAD40" 3)]"
rp_case finding "$HEAD40" "[$(rp_rec "$HEAD40" 1 1)]"
rp_case old "$OLD40" "[$(rp_rec "$OLD40" 1),$(rp_rec "$OLD40" 2),$(rp_rec "$OLD40" 3)]"
rp_plan none
assert_exit "required_passes none: exit" 0
assert_jq "required_passes: a stage with required_passes 3 and no pass at the head plans three review_stage rows, passes 1, 2 and 3" "$SEC_ROWS" '[1,2,3]'
rp_plan two
assert_jq "required_passes: clean passes 1 and 2 at the head plan one review_stage row with pass 3" "$SEC_ROWS" '[3]'
assert_jq "required_passes: two clean passes of three do not plan merge" '[.cards[] | select(.number == 12 and .action == "merge")] | length' '0'
rp_plan three
assert_jq "required_passes: three clean pass records at the head count the stage as met and plan merge" "$(card 12 action)" '"merge"'
rp_plan finding
assert_jq "required_passes: one pass with an Important finding plans fix" "$(card 12 action)" '"fix"'
assert_jq "required_passes: a finding plans no further review_stage row for the stage" '[.cards[] | select(.number == 12 and .action == "review_stage" and .stage.name == "security")] | length' '0'
rp_plan old
assert_jq "required_passes: three clean pass records at an older head do not count; three new rows at the current head" "$SEC_ROWS" '[1,2,3]'

tp_finish
