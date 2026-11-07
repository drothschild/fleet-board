#!/usr/bin/env bash
# Checks the manager agent, the reporting skill and their specs carry the
# review-stage and provider-stage rules (clean-room Revision 17).
set -u
unset CDPATH
HERE="$(cd "$(dirname "$0")" && pwd)"
SPECS="${SPECS_DIR:-$HERE/../../../docs/implementation-plans/2026-09-28-fleet-board/specs}"
M="$HERE/../agents/manager.md"
R="$HERE/../skills/reporting/SKILL.md"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

# has LABEL FILE NEEDLE: the file holds the fixed string NEEDLE.
has() {
  if grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1"; fi
}

# line_has LABEL FILE LINE_PATTERN NEEDLE: a line matching LINE_PATTERN also holds NEEDLE.
line_has() {
  if grep -E -- "$3" "$2" | grep -qF -- "$4"; then ok "$1"; else bad "$1"; fi
}

check_manager() {
  local who="$1" f="$2" p
  for p in 'review-stages.sh route' 'advance_stage' 'review_stage' 'stage.agent' 'stage.model' \
    '--role stage-reviewer' 'reviewed_stages' 'stage-review.sh' 'stage.provider'; do
    has "$who names $p" "$f" "$p"
  done
  line_has "$who: an advance_stage table row" "$f" '^\| `advance_stage` ' 'review_<'
  line_has "$who: a review_stage table row runs stage-review.sh for a provider stage" "$f" '^\| `review_stage` ' 'stage-review.sh'
  line_has "$who: start_review routes before the move" "$f" '^\| `start_review` ' 'review-stages.sh route N <pr>` → `board-move.sh N in_review'
  line_has "$who: block may come from a stage column" "$f" '^\| `block` ' 'review_<name>'
  has "$who: never calls a provider except through stage-review.sh" "$f" 'other than `stage-review.sh`'
  has "$who: last_review records the provider" "$f" 'last_review.provider'
  has "$who: adds the provider cost to the cost line" "$f" 'cost_usd'
}

check_manager agent "$M"
if [ -f "$SPECS/manager.md" ]; then check_manager spec "$SPECS/manager.md"; else echo "skip - no spec at $SPECS (installed plugin)"; fi

check_reporting() {
  local who="$1" f="$2"
  has "$who names the stage-reviewer role" "$f" 'stage-reviewer'
  line_has "$who: the status row names the stage-reviewer" "$f" '^\| `role <role> does not allow status' 'stage-reviewer'
  line_has "$who: the role-sections row names the stage-reviewer" "$f" '^\| `role <role> requires ## <section>`' 'stage-reviewer'
}

check_reporting skill "$R"
if [ -f "$SPECS/reporting.md" ]; then check_reporting spec "$SPECS/reporting.md"; fi
exit $fail
