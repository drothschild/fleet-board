#!/usr/bin/env bash
# review-stages.sh - routes a card to review stages, picks the next one, and
# creates the stages' labels.
#
# Usage:
#   review-stages.sh route <card-n> <pr-n>
#   review-stages.sh next [--labels <json>] [--after <state>] [--done <json>] <card-n>
#   review-stages.sh setup
#
# route: a stage applies when the card carries its label, or when a file the
# PR changes matches one of its paths globs (same rule as needs-human-qa.sh).
# Adds each missing routing label (never removes one) and prints the JSON list
# of stage names whose label the card carries afterwards. When gh lists fewer
# files than the PR changes, every stage is routed, with a warning. With no
# stages configured it prints [] and calls nothing.
#
# next: prints the name of the next stage for the card, or nothing. A stage
# counts when its label is on the card (--labels, else read from the card), it
# comes after --after in config order (default in_review; or review_<name>),
# and its name is not in --done (JSON array of names, default []).
#
# setup: creates each stage's routing label on both backends, and its state
# label on github-labels; on github-projects it checks the Status field has a
# column for each stage and exits 1 naming the missing ones.
#
# Exit codes:
#   0 - done
#   1 - the card, the PR's files, or a gh call failed; or a Status column is missing
#   2 - usage error

set -uo pipefail
unset CDPATH # a relative cd must not follow CDPATH (it would also echo the path)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

USAGE="usage: review-stages.sh route <card-n> <pr-n> | next [--labels <json>] [--after <state>] [--done <json>] <card-n> | setup"
[ $# -ge 1 ] || fb_die 2 "$USAGE"
MODE="$1"
shift

# names_json_check <value> <what>: prints the value as compact JSON when it is
# an array of strings, else dies with 2.
names_json_check() {
  jq -c 'if type == "array" and all(.[]; type == "string") then . else error("not a list of names") end' <<<"$1" 2>/dev/null \
    || fb_die 2 "$2 must be a JSON array of strings"
}

card_labels() {
  local read
  read="$(bash "$FB_SCRIPTS/board-read.sh" "$1")" || fb_die 1 "cannot read card #$1"
  jq -c '.labels // []' <<<"$read" 2>/dev/null || fb_die 1 "cannot read the labels of card #$1"
}

case "$MODE" in
  route)
    [ $# -eq 2 ] || fb_die 2 "$USAGE"
    fb_valid_number "$1" || fb_die 2 "card number must be numeric, got: $1"
    fb_valid_number "$2" || fb_die 2 "PR number must be numeric, got: $2"
    CARD="$1"
    PR="$2"
    fb_load_config
    STAGES="$(jq -c '.review.stages // []' <<<"$FLEET_CFG")" || fb_die 1 "cannot read review.stages"
    if [ "$(jq 'length' <<<"$STAGES")" = 0 ]; then
      echo '[]'
      exit 0
    fi
    LABELS="$(card_labels "$CARD")" || exit $?

    FILES_JSON="$(gh pr view "$PR" --repo "$FLEET_REPO" --json files,changedFiles)" \
      || fb_die 1 "cannot list the files of PR #$PR"
    INFO="$(jq -r '
      if (.files | type) != "array" then error("no files") else . end
      | ((.changedFiles // 0) > (.files | length)), (.files[].path)' <<<"$FILES_JSON" 2>/dev/null)" \
      || fb_die 1 "cannot parse the files of PR #$PR"
    TRUNCATED="$(printf '%s\n' "$INFO" | sed -n 1p)"
    PATHS="$(printf '%s\n' "$INFO" | sed '1d')"
    if [ "$TRUNCATED" = true ]; then
      printf 'fleet-board: warning: PR #%s changes more files than gh listed; routing it to every review stage\n' "$PR" >&2
    fi

    ROUTED='[]'
    COUNT="$(jq 'length' <<<"$STAGES")"
    i=0
    while [ "$i" -lt "$COUNT" ]; do
      NAME="$(jq -r ".[$i].name" <<<"$STAGES")"
      LABEL="$(jq -r ".[$i].label" <<<"$STAGES")"
      HAVE="$(jq -r --arg l "$LABEL" 'index($l) != null' <<<"$LABELS")"
      MATCH=false
      if [ "$HAVE" = true ]; then
        MATCH=true
      elif [ "$TRUNCATED" = true ]; then
        MATCH=true
      else
        while IFS= read -r pat; do
          [ -n "$pat" ] || continue
          while IFS= read -r path; do
            [ -n "$path" ] || continue
            if fb_glob_match "$path" "$pat"; then MATCH=true; break; fi
          done <<<"$PATHS"
          [ "$MATCH" = true ] && break
        done <<<"$(jq -r ".[$i].paths // [] | .[]" <<<"$STAGES")"
      fi
      if [ "$MATCH" = true ]; then
        if [ "$HAVE" != true ]; then
          gh issue edit "$CARD" --repo "$FLEET_REPO" --add-label "$LABEL" >/dev/null \
            || fb_die 1 "cannot add label $LABEL to card #$CARD"
        fi
        ROUTED="$(jq -c --arg n "$NAME" '. + [$n]' <<<"$ROUTED")"
      fi
      i=$((i + 1))
    done
    echo "$ROUTED"
    ;;

  next)
    LABELS=""
    AFTER=in_review
    DONE='[]'
    while [ $# -gt 0 ]; do
      case "$1" in
        --labels)
          [ $# -ge 2 ] || fb_die 2 "$USAGE"
          LABELS="$(names_json_check "$2" --labels)" || exit $?
          shift 2
          ;;
        --done)
          [ $# -ge 2 ] || fb_die 2 "$USAGE"
          DONE="$(names_json_check "$2" --done)" || exit $?
          shift 2
          ;;
        --after)
          [ $# -ge 2 ] || fb_die 2 "$USAGE"
          AFTER="$2"
          shift 2
          ;;
        -*) fb_die 2 "$USAGE" ;;
        *) break ;;
      esac
    done
    [ $# -eq 1 ] || fb_die 2 "$USAGE"
    fb_valid_number "$1" || fb_die 2 "card number must be numeric, got: $1"
    CARD="$1"
    fb_load_config
    STATES="$(fb_stage_states)"
    if [ "$AFTER" != in_review ] && ! printf '%s\n' "$STATES" | grep -Fxq -- "$AFTER"; then
      fb_die 2 "--after must be in_review or a configured review stage state, got: $AFTER"
    fi
    [ -n "$STATES" ] || exit 0
    [ -n "$LABELS" ] || { LABELS="$(card_labels "$CARD")" || exit $?; }

    SEEN=false
    [ "$AFTER" = in_review ] && SEEN=true
    while IFS= read -r state; do
      if [ "$SEEN" = false ]; then
        [ "$state" = "$AFTER" ] && SEEN=true
        continue
      fi
      STAGE="$(fb_stage_of_state "$state")"
      NAME="$(jq -r .name <<<"$STAGE")"
      LABEL="$(jq -r .label <<<"$STAGE")"
      [ "$(jq -r --arg l "$LABEL" 'index($l) != null' <<<"$LABELS")" = true ] || continue
      [ "$(jq -r --arg n "$NAME" 'index($n) != null' <<<"$DONE")" = false ] || continue
      echo "$NAME"
      exit 0
    done <<<"$STATES"
    ;;

  setup)
    [ $# -eq 0 ] || fb_die 2 "$USAGE"
    fb_load_config
    BACKEND="$(jq -r '.board.backend' <<<"$FLEET_CFG")"
    STAGES="$(jq -c '.review.stages // []' <<<"$FLEET_CFG")" || fb_die 1 "cannot read review.stages"
    while IFS=$'\t' read -r name label; do
      [ -n "$name" ] || continue
      gh label create "$label" --repo "$FLEET_REPO" --color d93f0b \
        --description "fleet-board: route to review stage $name" --force >/dev/null \
        || fb_die 1 "cannot create label $label in $FLEET_REPO"
      if [ "$BACKEND" = github-labels ]; then
        sname="$(fb_state_name "review_$name")"
        gh label create "$sname" --repo "$FLEET_REPO" --color 5319e7 \
          --description "fleet-board state: review_$name" --force >/dev/null \
          || fb_die 1 "cannot create label $sname in $FLEET_REPO"
      fi
    done <<<"$(jq -r '.[] | [.name, .label] | @tsv' <<<"$STAGES")"

    if [ "$BACKEND" = github-projects ]; then
      PROJECT="$(jq -r '.board.project_number' <<<"$FLEET_CFG")"
      OWNER="$(fb_cfg board.project_owner)"
      [ -n "$OWNER" ] || OWNER="${FLEET_REPO%%/*}"
      FIELDS="$(gh project field-list "$PROJECT" --owner "$OWNER" --format json --limit 100)" \
        || fb_die 1 "cannot read the fields of project $PROJECT (owner $OWNER)"
      HAS_STATUS="$(jq -r 'any(.fields[]; .name == "Status")' <<<"$FIELDS" 2>/dev/null)" \
        || fb_die 1 "cannot parse the fields of project $PROJECT"
      [ "$HAS_STATUS" = true ] || fb_die 1 "project $PROJECT has no Status field"
      OPTIONS="$(jq -r 'first(.fields[] | select(.name == "Status")) | .options[].name' <<<"$FIELDS")" \
        || fb_die 1 "cannot parse the Status options of project $PROJECT"
      LACKING=""
      for s in $(fb_stage_states); do
        sname="$(fb_state_name "$s")"
        printf '%s\n' "$OPTIONS" | grep -Fxq -- "$sname" || LACKING="${LACKING:+$LACKING, }$sname"
      done
      [ -z "$LACKING" ] || fb_die 1 "project $PROJECT Status field lacks option(s): $LACKING; add it in the project's Status field or map it in board.states"
    fi
    ;;

  *) fb_die 2 "$USAGE" ;;
esac
