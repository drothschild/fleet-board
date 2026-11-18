#!/usr/bin/env bash
# epic.sh - the epic record: a change that spans several cards.
#
# Usage:
#   epic.sh create --title-file <f> [--intent-file <f>] [--design-file <f>] [--repo <r>]
#   epic.sh read <id>
#   epic.sh list [--all]
#   epic.sh set-intent <id> <file>
#   epic.sh set-state <id> open|closed
#   epic.sh clear-attention <id> <index>
#
# create prints {"id": <id>}. A non-empty design file becomes design.md (design_rev 1).
# read prints the stored epic plus design (text of design.md), log (the lines of log.jsonl),
# children (every card whose epic is this id, by number, each with a derived progress),
# progress (counts) and effective_state: closed when stored so; complete when there is at
# least one child, every child is done or dropped, and every Done child with a pr_url has a
# log line; else open. complete is derived and never stored. list prints the open epics
# (all with --all) as [{id, title, effective_state, progress, attention: <count>}].
#
# Exit codes: 0 done, 1 failure, 2 usage, 3 the epic does not exist.
set -uo pipefail
unset CDPATH
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

USAGE="usage: epic.sh create --title-file <f> [--intent-file <f>] [--design-file <f>] [--repo <r>] | read <id> | list [--all] | set-intent <id> <file> | set-state <id> open|closed | clear-attention <id> <index>"
[ $# -ge 1 ] || fb_die 2 "$USAGE"
VERB="$1"; shift

valid_id() { fb_valid_number "$1" && [ "$1" -gt 0 ] 2>/dev/null; }

TITLE_F=""; INTENT_F=""; DESIGN_F=""; REPO=""; ALL=0; ID=""; ARG=""
case "$VERB" in
  create)
    while [ $# -gt 0 ]; do
      [ $# -ge 2 ] || fb_die 2 "$USAGE"
      case "$1" in
        --title-file) TITLE_F="$2" ;;
        --intent-file) INTENT_F="$2" ;;
        --design-file) DESIGN_F="$2" ;;
        --repo) REPO="$2" ;;
        *) fb_die 2 "$USAGE" ;;
      esac
      shift 2
    done
    [ -n "$TITLE_F" ] || fb_die 2 "$USAGE"
    for f in "$TITLE_F" "$INTENT_F" "$DESIGN_F"; do
      [ -z "$f" ] || [ -f "$f" ] || fb_die 2 "cannot read $f"
    done
    ;;
  read)
    [ $# -eq 1 ] || fb_die 2 "$USAGE"
    valid_id "$1" || fb_die 2 "epic id must be a positive integer, got: $1"
    ID="$1"
    ;;
  list)
    case "${1:-}" in
      '') ;;
      --all) [ $# -eq 1 ] || fb_die 2 "$USAGE"; ALL=1 ;;
      *) fb_die 2 "$USAGE" ;;
    esac
    ;;
  set-intent|set-state|clear-attention)
    [ $# -eq 2 ] || fb_die 2 "$USAGE"
    valid_id "$1" || fb_die 2 "epic id must be a positive integer, got: $1"
    ID="$1"; ARG="$2"
    case "$VERB" in
      set-intent) [ -f "$ARG" ] || fb_die 2 "cannot read $ARG" ;;
      set-state) case "$ARG" in open|closed) ;; *) fb_die 2 "state must be open or closed, got: $ARG" ;; esac ;;
      clear-attention) fb_valid_number "$ARG" || fb_die 2 "index must be a non-negative integer, got: $ARG" ;;
    esac
    ;;
  *) fb_die 2 "$USAGE" ;;
esac

fb_load_config
. "$FB_SCRIPTS/adapters/local/local-lib.sh"
. "$FB_SCRIPTS/adapters/local/epic-lib.sh"

# epic_view <id>: prints the epic with design, log, children, progress and effective_state.
# One jq pass over the card files; never a process per card.
epic_view() {
  local id="$1" dir design log stages cards
  dir="$(fl_epic_dir "$id")"
  design="$(jq -Rs . < "$dir/design.md" 2>/dev/null)" || design='""'
  [ -f "$dir/design.md" ] || design='""'
  log="$(jq -cRn '[inputs | fromjson? | select(type == "object")]' < "$dir/log.jsonl" 2>/dev/null)" || log='[]'
  [ -n "$log" ] || log='[]'
  stages="$(fb_stage_states | jq -Rn '[inputs | select(length > 0)]')"
  cards="$(fl_cards_dir)"
  set -- "$cards"/*.json
  [ -e "$1" ] || set -- /dev/null
  jq -s -c --argjson id "$id" --argjson design "$design" --argjson log "$log" --argjson stages "$stages" \
    --slurpfile epic "$dir/epic.json" '
    [.[] | select(type == "object")] as $cards
    | ($cards | map({key: (.number | tostring), value: .state}) | from_entries) as $st
    | def prog:
        if .state == "backlog" then "waiting"
        elif .state == "ready" then
          (if any((.blocked_by // [])[]; $st[(. | tostring)] != "done") then "waiting" else "ready" end)
        elif .state == "in_progress" or .state == "in_review" or .state == "merging"
             or .state == "human_qa" or (.state as $s | $stages | index($s)) then "in_flight"
        elif .state == "blocked" then "blocked"
        elif .state == "done" then "done"
        elif .state == "wont_do" then "dropped"
        else "waiting" end;
      [$cards[] | select(.epic == $id)] | sort_by(.number)
      | map({number, title, state, pr_url: (.pr_url // null), repo: (.repo // null),
             blocked_by: (.blocked_by // []), progress: prog}) as $kids
    | ($log | map(.card)) as $logged
    | ($epic[0]) + {
        design: $design, log: $log, children: $kids,
        progress: ($kids | {waiting: 0, ready: 0, in_flight: 0, blocked: 0, done: 0, dropped: 0} as $z
                   | reduce .[] as $k ($z; .[$k.progress] += 1)),
        effective_state:
          (if $epic[0].state == "closed" then "closed"
           elif ($kids | length) > 0
                and all($kids[]; .progress == "done" or .progress == "dropped")
                and all($kids[]; ((.state == "done" and ((.pr_url // "") != "")) | not) or ((.number as $n | $logged | index($n)) != null))
           then "complete" else "open" end)}
    ' "$@"
}

require_epic() { fl_epic_exists "$1" || fb_die 3 "epic E$1 does not exist"; }

case "$VERB" in
  create)
    fl_require_store
    fl_check_repo "$REPO"
    ID="$(fl_next_epic_id)" || exit 1
    DIR="$(fl_epic_dir "$ID")"
    TMP="$(mktemp)" || fb_die 1 "cannot create a temporary file"
    trap 'rm -f "$TMP"; [ -z "${FB_EPIC_LOCK:-}" ] || fb_lock_release "$FB_EPIC_LOCK"' EXIT
    DESIGN_REV=0
    if [ -n "$DESIGN_F" ] && [ -s "$DESIGN_F" ]; then
      cat "$DESIGN_F" > "$DIR/design.md" || fb_die 1 "cannot write $DIR/design.md"
      DESIGN_REV=1
    fi
    NOW="$(fl_now)"
    jq -n --argjson id "$ID" --rawfile title "$TITLE_F" --arg repo "$REPO" --argjson rev "$DESIGN_REV" --arg now "$NOW" \
      --rawfile intent "${INTENT_F:-/dev/null}" '
      {id: $id, title: ($title | sub("\n+$"; "")), state: "open", repo: (if $repo == "" then null else $repo end),
       intent: $intent, design_rev: $rev, conversation: null, attention: [],
       created_at: $now, updated_at: $now, exported: null}' > "$TMP" || fb_die 1 "cannot build epic E$ID"
    fl_epic_lock "$ID"
    fl_write_epic "$ID" "$TMP"
    jq -nc --argjson id "$ID" '{id: $id}'
    ;;
  read)
    require_epic "$ID"
    epic_view "$ID" || fb_die 1 "cannot read the cards in $(fl_cards_dir)"
    ;;
  list)
    OUTS=""
    for d in "$(fl_epics_dir)"/*/; do
      [ -d "$d" ] || continue
      i="$(basename "$d")"
      fl_epic_exists "$i" || continue
      V="$(epic_view "$i")" || fb_die 1 "cannot read the cards in $(fl_cards_dir)"
      OUTS="$OUTS$V
"
    done
    printf '%s' "$OUTS" | jq -sc --argjson all "$ALL" '
      map(select($all == 1 or .effective_state != "closed" and .state == "open")
          | {id, title, effective_state, progress, attention: (.attention | length)})
      | sort_by(.id)'
    ;;
  set-intent|set-state|clear-attention)
    require_epic "$ID"
    TMP="$(mktemp)" || fb_die 1 "cannot create a temporary file"
    trap 'rm -f "$TMP"; fb_lock_release "$FB_EPIC_LOCK"' EXIT
    fl_epic_lock "$ID"
    require_epic "$ID"
    NOW="$(fl_now)"
    EJ="$(fl_epic_dir "$ID")/epic.json"
    case "$VERB" in
      set-intent) jq --rawfile v "$ARG" --arg now "$NOW" '.intent = $v | .updated_at = $now' "$EJ" > "$TMP" ;;
      set-state) jq --arg v "$ARG" --arg now "$NOW" '.state = $v | .updated_at = $now' "$EJ" > "$TMP" ;;
      clear-attention)
        jq -e --argjson i "$ARG" '(.attention // []) | $i < length' "$EJ" >/dev/null 2>&1 \
          || fb_die 1 "epic E$ID has no attention entry at index $ARG"
        jq --argjson i "$ARG" --arg now "$NOW" '.attention |= (to_entries | map(select(.key != $i) | .value)) | .updated_at = $now' "$EJ" > "$TMP"
        ;;
    esac || fb_die 1 "cannot update epic E$ID"
    fl_write_epic "$ID" "$TMP"
    ;;
esac
