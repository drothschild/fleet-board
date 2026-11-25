#!/usr/bin/env bash
#
# Plain-bash tests for tick-plan.sh: a card of another repo (card 424). The planner looks its PR up
# in the card's repo and reads review stages from that repo's .fleet-board.yml, not the home repo's
# (offline, fake gh). One of the tick-plan suites; the shared helpers are in tick-plan-lib.sh.
#
# Usage: bash plugins/fleet-board/tests/test-tick-plan-repos.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SCRIPT_DIR/tick-plan-lib.sh"

echo "Test: tick-plan.sh (cards of another repo)"
echo ""

# other_repo_plan: the parallel-two-stages scenario (card 12, in review, PR 34, routed to the home
# repo's security and ux stages) with card 12 moved to repo other/toy. other/toy's own config has one
# stage, audit. The fake gh answers the PR lookups only for --repo other/toy.
other_repo_plan() {
  local other stub d
  other="$(mktemp -d)"; CLEANUP_DIRS+=("$other")
  other="$(cd "$other" && pwd -P)"
  {
    printf 'board:\n  repo: other/toy\n'
    no_builtin_stages "$(printf 'review:\n  stages:\n    - name: audit\n      agent: "acme:audit"\n      model: opus\n      paths: ["src/**"]')"
    printf '\n'
  } > "$other/.fleet-board.yml"
  setup_case parallel-two-stages "$STAGES_YAML" "$(printf '  repos:\n    - repo: other/toy\n      path: %s' "$other")"
  stub="$(mktemp -d)"; CLEANUP_DIRS+=("$stub")
  cp -R "$SCRIPT_DIR/../scripts/." "$stub/"
  printf '#!/usr/bin/env bash\nbash "%s/board-read.sh" "$@" | jq -c '"'"'.repo = "other/toy"'"'"'\n' "$SCRIPTS_ABS" > "$stub/board-read.sh"
  d="$FAKE_GH_DIR/routes.d"; mkdir -p "$d"
  sed -e "s#	\.\./#	$TICK/#" -e "s#	comments-#	$TICK/parallel-two-stages/comments-#" \
      -e '/^pr view/s# --repo acme/toy# --repo other/toy#' "$TICK/parallel-two-stages/routes" > "$d/routes"
  FAKE_GH_ROUTES="$d/routes"; export FAKE_GH_ROUTES
  run_check "$stub/tick-plan.sh"
}

other_repo_plan
assert_exit "other repo: exit" 0
assert_eq "A PR lookup for a card of another repo goes to that repo in the fake gh log" \
  "$(call_count pr view 34 --repo other/toy --json isDraft,state,mergedAt,statusCheckRollup,headRefOid)" 1
assert_eq "other repo: no PR lookup goes to the home repo" \
  "$(call_count pr view 34 --repo acme/toy --json isDraft,state,mergedAt,statusCheckRollup,headRefOid)" 0
assert_eq "other repo: the files lookup for the stages goes to that repo too" \
  "$(call_count pr view 34 --repo other/toy --json files,changedFiles)" 1
assert_jq "Review stages for a card of another repo come from that repo's review.stages" \
  "[.cards[] | select(.number == 12 and .action == \"review_stage\") | .stage.name]" '["audit"]'

# Per-repo merge policy and review limits (card 503). other_note <home yaml> <other yaml> <note json> <where>:
# the parallel-all-reported case (card 12, open green PR, routed to security) with the given manager note.
# where "other" moves card 12 to repo other/toy, whose config is <other yaml>; where "home" leaves it on the
# home board (the same board config, listing other/toy in board.repos).
other_note() {
  local other stub d repo=acme/toy
  other="$(mktemp -d)"; CLEANUP_DIRS+=("$other")
  other="$(cd "$other" && pwd -P)"
  { printf 'board:\n  repo: other/toy\n'; no_builtin_stages "$2"; printf '\n'; } > "$other/.fleet-board.yml"
  setup_case parallel-all-reported "$1" "$(printf '  repos:\n    - repo: other/toy\n      path: %s' "$other")"
  stub="$(mktemp -d)"; CLEANUP_DIRS+=("$stub")
  cp -R "$SCRIPT_DIR/../scripts/." "$stub/"
  if [ "$4" = other ]; then
    repo=other/toy
    printf '#!/usr/bin/env bash\nbash "%s/board-read.sh" "$@" | jq -c '"'"'.repo = "other/toy"'"'"'\n' "$SCRIPTS_ABS" > "$stub/board-read.sh"
  fi
  d="$FAKE_GH_DIR/routes.d"; mkdir -p "$d"
  jq -cn --arg note "$3" '[{id: 555, user: {login: "fleet-bot"},
    body: ("<!-- fleet-board:manager-note -->\n### fleet-board manager note\nState: x\n\n```json\n" + $note + "\n```\n"),
    created_at: "2026-09-28T00:01:00Z"}]' > "$d/comments.json"
  sed -e "s#	\.\./#	$TICK/#" -e "s#	comments-12.json#	$d/comments.json#" \
      -e "s#issue-12-in_review-security-ux#issue-12-in_review-security#" -e "s#pr-34-draft#pr-34-open-green#" \
      -e "/^pr view/s# --repo acme/toy# --repo $repo#" "$TICK/parallel-all-reported/routes" > "$d/routes"
  FAKE_GH_ROUTES="$d/routes"; export FAKE_GH_ROUTES
  run_check "$stub/tick-plan.sh"
}
SEC_STAGE="$(printf '  stages:\n    - name: security\n      agent: "acme:sec"\n      model: opus')"
PERF_STAGE="$(printf '  stages:\n    - name: perf\n      agent: "acme:perf"\n      model: opus\n      label: needs-security-review')"
mk_cfg() { printf 'merge:\n  policy: %s\nreview:\n  max_rounds: %s\n%s' "$1" "$2" "$3"; }
rec() { printf '{"round":%s,"sha":"abc1234","critical":0,"important":%s,%s"findings":[]}' "$1" "$2" "$3"; }
HEAD_NOTE='"state":"in_review","branch":"fleet/12-add-subtract","pr":34'
CLEAN_NOTE="{$HEAD_NOTE,\"round\":1,\"last_review\":$(rec 1 0 ''),\"reviews\":{\"evidence\":$(rec 1 0 ''),\"security\":$(rec 1 0 '"stage":"security",')}}"
ACT='[.cards[] | select(.number == 12) | .action]'

other_note "$(mk_cfg auto 3 "$SEC_STAGE")" "$(mk_cfg human 3 "$SEC_STAGE")" "$CLEAN_NOTE" other
assert_jq "A clean, reviewed card of another repo whose repo has merge.policy human plans no merge row while the home config is auto" \
  "$ACT | index(\"merge\")" 'null'
other_note "$(mk_cfg human 3 "$SEC_STAGE")" "$(mk_cfg auto 3 "$SEC_STAGE")" "$CLEAN_NOTE" other
assert_jq "A clean, reviewed card of another repo whose repo has merge.policy auto plans a merge row while the home config is human" \
  "$ACT" '["merge"]'

EV3="{$HEAD_NOTE,\"round\":3,\"last_review\":$(rec 3 1 ''),\"finding_rounds\":{\"evidence\":{\"count\":3,\"last_round\":3}},\"reviews\":{\"evidence\":$(rec 3 1 ''),\"security\":$(rec 3 0 '"stage":"security",')}}"
other_note "$(mk_cfg auto 5 "$SEC_STAGE")" "$(mk_cfg auto 3 "$SEC_STAGE")" "$EV3" other
assert_jq "A card of another repo with findings is escalated at that repo's review.max_rounds, not at the home config's (repo 3, home 5: block)" \
  "$ACT" '["block"]'
other_note "$(mk_cfg auto 3 "$SEC_STAGE")" "$(mk_cfg auto 5 "$SEC_STAGE")" "$EV3" other
assert_jq "A card of another repo with findings is escalated at that repo's review.max_rounds, not at the home config's (repo 5, home 3: fix)" \
  "$ACT" '["fix"]'

PERF1="{$HEAD_NOTE,\"round\":3,\"last_review\":$(rec 3 1 '"stage":"perf",'),\"finding_rounds\":{\"perf\":{\"count\":1,\"last_round\":3}},\"reviews\":{\"evidence\":$(rec 3 0 ''),\"perf\":$(rec 3 1 '"stage":"perf",')}}"
other_note "$(mk_cfg auto 3 "$PERF_STAGE")" "$(mk_cfg auto 1 "$PERF_STAGE")" "$PERF1" other
assert_jq "A stage of another repo's card without its own max_rounds falls back to that repo's review.max_rounds (repo 1, home 3: block)" \
  "$ACT" '["block"]'
other_note "$(mk_cfg auto 1 "$PERF_STAGE")" "$(mk_cfg auto 3 "$PERF_STAGE")" "$PERF1" other
assert_jq "A stage of another repo's card without its own max_rounds falls back to that repo's review.max_rounds (repo 3, home 1: fix)" \
  "$ACT" '["fix"]'

other_note "$(mk_cfg human 3 "$SEC_STAGE")" "$(mk_cfg auto 3 "$SEC_STAGE")" "$CLEAN_NOTE" home
assert_jq "A home-repo card on the same board still follows the home merge.policy (human: no merge)" "$ACT | index(\"merge\")" 'null'
other_note "$(mk_cfg auto 3 "$SEC_STAGE")" "$(mk_cfg human 3 "$SEC_STAGE")" "$CLEAN_NOTE" home
assert_jq "A home-repo card on the same board still follows the home merge.policy (auto: merge)" "$ACT" '["merge"]'
other_note "$(mk_cfg auto 5 "$SEC_STAGE")" "$(mk_cfg auto 3 "$SEC_STAGE")" "$EV3" home
assert_jq "A home-repo card on the same board still follows the home review.max_rounds (home 5, other 3: fix)" "$ACT" '["fix"]'
other_note "$(mk_cfg auto 3 "$SEC_STAGE")" "$(mk_cfg auto 5 "$SEC_STAGE")" "$EV3" home
assert_jq "A home-repo card on the same board still follows the home review.max_rounds (home 3, other 5: block)" "$ACT" '["block"]'

tp_finish
