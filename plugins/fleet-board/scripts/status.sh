#!/usr/bin/env bash
# status.sh - prints the board, one section per state.
#
# Usage: status.sh [--all | --forecast]
#
# Sections, in order: ready, in_progress, in_review, human_qa, blocked; with
# --all also backlog, done and wont_do. Each section is the state name on
# its own line, then one line per card:
#   #<n> <title> · round <r> · PR #<pr> · <implementor>/<reviewer>
# with the values from the card's manager note and "—" for a missing one
# ("PR —" when there is no PR). An empty section prints "(none)". A card
# whose note cannot be read prints "#<n> <title> · note unreadable".
# A ready card with acceptance items and unmet blockers (deps.sh)
# ends its line with " · waits for <ref> (<state or column>)[, ...]", the
# reason tick-plan.sh plans wait with; if they cannot be looked up, with
# " · dependencies unreadable" (exit 1).
# When any ready card waits, a dependency graph follows the sections, built
# from the same lookups (no extra listing calls):
#   dependency graph
#   blocker <ref>          one section per blocker, then its waiting cards
#     #<n>                 (refs in another repo keep their owner/repo prefix)
#   critical path: <ref> -> ... -> <ref>   the longest chain of unmet deps
#   can start now: #<n>, ...               ready cards with no unmet dep
# A board with no waiting card prints no graph.
#
# --forecast prints an overnight preflight instead of the board (not with
# --all). It reads every card in ready, in_progress, in_review, human_qa,
# blocked and backlog, and writes nothing. Its sections, each only when it has
# entries:
#   critical-path human gates         needs-human-qa cards another ready or
#     #<n> <title> · blocks #<m>, ...   backlog card depends on
#   dependencies needing a manual step  cards labelled needs-manual-step that
#     #<n> <title> · blocks #<m>, ...   another ready or backlog card depends on
#   ready cards waiting on Backlog
#     #<n> <title> · waits for #<m> (backlog), ...
# then "can finish unattended: #<n>, ..." (ready cards with no unmet
# dependency, or only unmet dependencies that are themselves in this list, and
# no needs-human-qa / needs-manual-step label, or "(none)") and
# "run stops at: #<n> (<reason>), ..." (the cards above, with needs-human-qa,
# needs-manual-step or backlog as the reason). With no entry in the first three
# sections it prints the one line "forecast: nothing to warn about". Exit codes
# are those below.
#
# Exit codes:
#   0 - board printed
#   1 - a column could not be listed, or a card's note could not be read
#   2 - usage error

set -uo pipefail
unset CDPATH # a relative cd must not follow CDPATH (it would also echo the path)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

ALL=""
FORECAST=""
case "$#:${1:-}" in
  0:) ;;
  1:--forecast) FORECAST=1 ;;
  1:--all) ALL=1 ;;
  *) fb_die 2 "usage: status.sh [--all | --forecast]" ;;
esac

fb_load_config

# The review stage columns (config order) sit between in_review and human_qa.
STAGE_STATES="$(fb_stage_states | tr '\n' ' ')"
STATES="ready in_progress in_review ${STAGE_STATES}human_qa blocked"
[ -z "$ALL" ] || STATES="$STATES backlog done wont_do"

DEPS_FILE="$(mktemp)" || fb_die 1 "cannot create a temp file"
EDGES_FILE="$(mktemp)" || fb_die 1 "cannot create a temp file"
START_FILE="$(mktemp)" || fb_die 1 "cannot create a temp file"
FC_FILE="$(mktemp)" || fb_die 1 "cannot create a temp file"
trap 'rm -f "$DEPS_FILE" "$EDGES_FILE" "$START_FILE" "$FC_FILE"' EXIT

# waits_for <n>: prints the waiting reason of a ready card ("waits for ..."),
# nothing when it has no unmet dependency; fails when they cannot be looked up
waits_for() {
  local card refs out
  card="$(bash "$FLEET_SCRIPTS/board-read.sh" "$1" </dev/null)" || return 1
  fb_card_has_acceptance "$card" || return 0
  # the blocked_by field is the dependency list
  printf '%s\n' "$card" > "$DEPS_FILE" || return 1
  refs="$(bash "$FLEET_SCRIPTS/deps.sh" parse-card "$DEPS_FILE" | jq -c .refs)" || return 1
  [ "$refs" != '[]' ] || return 0
  out="$(bash "$FLEET_SCRIPTS/deps.sh" check "$1" "$refs" 2>/dev/null)" || return 1
  jq -c --arg c "$1" --arg r "$FLEET_REPO" \
    'select((.unmet | length) > 0) | {card: ("#" + $c), blockers: [.unmet[].ref | if startswith($r + "#") then sub("^.*#"; "#") else . end]}' \
    <<<"$out" >> "$EDGES_FILE" 2>/dev/null
  jq -r 'if (.unmet | length) == 0 then empty
         else "waits for \([.unmet[] | "\(.ref) (\(.status | gsub("[[:cntrl:]]"; " ")))"] | join(", "))" end' <<<"$out"
}

# forecast_card <state> <n> <title>: appends one JSON line for the card to
# FC_FILE: number, title, column, labels, dependency refs, unmet dependencies
forecast_card() {
  local st="$1" n="$2" title="$3" card labels refs="[]" unmet="[]" out
  card="$(bash "$FLEET_SCRIPTS/board-read.sh" "$n" </dev/null)" || return 1
  labels="$(jq -c '.labels // []' <<<"$card" 2>/dev/null)" || return 1
  if [ "$st" = ready ] || [ "$st" = backlog ]; then
    printf '%s\n' "$card" > "$DEPS_FILE" || return 1
    refs="$(bash "$FLEET_SCRIPTS/deps.sh" parse-card "$DEPS_FILE" | jq -c .refs)" || return 1
    if [ "$st" = ready ] && [ "$refs" != '[]' ] && fb_card_has_acceptance "$card"; then
      out="$(bash "$FLEET_SCRIPTS/deps.sh" check "$n" "$refs" 2>/dev/null)" || return 1
      unmet="$(jq -c .unmet <<<"$out")" || return 1
    fi
  fi
  jq -cn --argjson n "$n" --arg t "$title" --arg st "$st" --argjson l "$labels" \
    --argjson refs "$refs" --argjson unmet "$unmet" --arg r "$FLEET_REPO" '
    def short: if startswith($r + "#") then sub("^.*#"; "#") else . end;
    {n: $n, title: $t, col: $st, labels: $l, refs: [$refs[].ref | short],
     unmet: [$unmet[] | .ref |= short]}' >> "$FC_FILE"
}

if [ -n "$FORECAST" ]; then
  for st in ready in_progress in_review $STAGE_STATES human_qa blocked backlog; do
    LIST="$(bash "$FLEET_SCRIPTS/board-list.sh" "$st")" || fb_die 1 "cannot list the $st column"
    ROWS="$(jq -c 'if type == "array" then .[] | {number, title} else error("not a list") end' <<<"$LIST" 2>/dev/null)" \
      || fb_die 1 "cannot parse the $st column"
    [ -n "$ROWS" ] || continue
    while IFS= read -r row; do
      n="$(jq -r .number <<<"$row")"
      title="$(jq -r '.title // "" | gsub("[[:cntrl:]]"; " ")' <<<"$row")"
      fb_valid_number "$n" || fb_die 1 "the $st column lists a non-numeric card: $n"
      forecast_card "$st" "$n" "$title" || fb_die 1 "cannot read card #$n"
    done <<<"$ROWS"
  done
  jq -rs '
    . as $c
    | def key: "#\(.n)";
      def blocks($lbl):
        [$c[] | select(.labels | index($lbl)) | . as $b
         | [$c[] | select((.col == "ready" or .col == "backlog") and (.refs | index($b | key))) | key] as $d
         | select($d | length > 0) | {card: ($b | key), line: "  \($b | key) \($b.title) · blocks \($d | join(", "))"}];
      def clean: gsub("[[:cntrl:]]"; " ");
      ([$c[] | select(.col == "backlog") | key]) as $bl
    | blocks("needs-human-qa") as $gates
    | blocks("needs-manual-step") as $manual
    | [$c[] | select(.col == "ready") | . as $r
       | ([$r.refs[] | select(. as $x | $bl | index($x))]) as $w
       | select($w | length > 0)
       | {line: "  \($r | key) \($r.title) · waits for \([$w[] | "\(.) (backlog)"] | join(", "))", blockers: $w}] as $waits
    | ([$c[] | select(.col == "ready"
                      and ((.labels | index("needs-human-qa")) == null)
                      and ((.labels | index("needs-manual-step")) == null))
               | {k: key, unmet: [.unmet[].ref]}]) as $cand
    | ([$cand[] | select(.unmet | length == 0) | .k]) as $seed
    | ($seed | until(. as $f
          | [$cand[] | select(.k as $k | ($f | index($k)) == null)
             | select(.unmet | all(. as $u | $f | index($u) != null)) | .k] | length == 0;
        . as $f | $f + [$cand[] | select(.k as $k | ($f | index($k)) == null)
                        | select(.unmet | all(. as $u | $f | index($u) != null)) | .k])) as $freeset
    | [$c[] | select(.col == "ready") | key | select(. as $k | $freeset | index($k) != null)] as $free
    | ([$waits[].blockers[]] | unique) as $bls
    | if ($gates | length) + ($manual | length) + ($waits | length) == 0
      then "forecast: nothing to warn about"
      else "forecast",
        (if ($gates | length) > 0 then "critical-path human gates", $gates[].line else empty end),
        (if ($manual | length) > 0 then "dependencies needing a manual step", $manual[].line else empty end),
        (if ($waits | length) > 0 then "ready cards waiting on Backlog", $waits[].line else empty end),
        "can finish unattended: \(if ($free | length) == 0 then "(none)" else $free | join(", ") end)",
        "run stops at: \([($gates[].card | "\(.) (needs-human-qa)"), ($manual[].card | "\(.) (needs-manual-step)"), ($bls[] | "\(.) (backlog)")] | join(", "))"
      end' "$FC_FILE" || fb_die 1 "cannot build the forecast"
  exit 0
fi

RC=0
for st in $STATES; do
  LIST="$(bash "$FLEET_SCRIPTS/board-list.sh" "$st")" || fb_die 1 "cannot list the $st column"
  ROWS="$(jq -c 'if type == "array" then .[] | {number, title} else error("not a list") end' <<<"$LIST" 2>/dev/null)" \
    || fb_die 1 "cannot parse the $st column"
  printf '%s\n' "$st"
  if [ -z "$ROWS" ]; then
    printf '  (none)\n'
    continue
  fi
  while IFS= read -r row; do
    n="$(jq -r .number <<<"$row")"
    title="$(jq -r '.title // "" | gsub("[[:cntrl:]]"; " ")' <<<"$row")"
    fb_valid_number "$n" || fb_die 1 "the $st column lists a non-numeric card: $n"
    if ! note="$(bash "$FLEET_SCRIPTS/note.sh" get "$n" </dev/null)"; then
      printf '  #%s %s · note unreadable\n' "$n" "$title"
      RC=1
      continue
    fi
    suffix=""
    if [ "$st" = ready ]; then
      if wf="$(waits_for "$n")"; then
        if [ -z "$wf" ]; then printf '#%s\n' "$n" >> "$START_FILE"; else suffix=" · $wf"; fi
      else
        suffix=" · dependencies unreadable"; RC=1
      fi
    fi
    stage="$(fb_stage_of_state "$st")"
    sagent=""; sprov=""; smodel=""
    if [ -n "$stage" ]; then
      sagent="$(jq -r '.agent // ""' <<<"$stage")"
      sprov="$(jq -r '.provider // ""' <<<"$stage")"
      smodel="$(jq -r '.model // ""' <<<"$stage")"
    fi
    jq -r --arg n "$n" --arg t "$title" --arg sfx "$suffix" --arg stage "$stage" \
      --arg sagent "$sagent" --arg sprov "$sprov" --arg smodel "$smodel" '
      def v: if . == null then "—" else tostring | gsub("[[:cntrl:]]"; " ") end;
      def m($k): if type == "object" then .[$k] | v else "—" end;
      "  #\($n) \($t) · round \(.round | v) · PR \(if .pr == null then "—" else "#\(.pr)" end) · \(if $stage == "" then "\(.models | m("implementor"))/\(.models | m("reviewer"))"
        elif $sprov != "" then "\(.models | m("fixer"))/\($sprov):\($smodel)"
        else "\(.models | m("fixer"))/\($sagent)@\($smodel)" end)\($sfx)"' \
      <<<"$note" || { printf '  #%s %s · note unreadable\n' "$n" "$title"; RC=1; }
  done <<<"$ROWS"
done

if [ -s "$EDGES_FILE" ]; then
  jq -rs --arg starts "$(paste -sd, "$START_FILE")" '
    . as $e
    | ($e | map(.card)) as $waiting
    | def nxt($n): [$e[] | select(.blockers | index($n)) | .card];
      def longest($n; $seen):
        [nxt($n)[] | . as $x | select($seen | index($x) | not) | longest($x; $seen + [$x])] as $subs
        | if ($subs | length) == 0 then [$n]
          else [$n] + ($subs | max_by(length)) end;
    ([$e[].blockers[]] | unique) as $blockers
    | "dependency graph",
      ($blockers[] as $b | "blocker \($b)", (nxt($b)[] | "  \(.)")),
      ([$blockers[] | . as $x | select($waiting | index($x) | not) | longest($x; [$x])] | max_by(length)) as $cp
      | "critical path: \(if $cp == null then "(none)" else ($cp | join(" -> ")) end)",
      "can start now: \(if $starts == "" then "(none)" else ($starts | split(",") | join(", ")) end)"' "$EDGES_FILE" || RC=1
fi
exit "$RC"
