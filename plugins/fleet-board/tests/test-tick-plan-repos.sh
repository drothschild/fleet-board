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

tp_finish
