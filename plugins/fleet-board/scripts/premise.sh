#!/usr/bin/env bash
# premise.sh - the commit a card last agreed with.
#
# Usage:
#   premise.sh stamp <n> --by create|edit|move|check|approve [--sha <40-hex>]
#   premise.sh show <n>
#   premise.sh moved <n>
#   premise.sh add-dep <n> <m>
#
# stamp writes the card's premise {sha, at, by}; the sha is --sha, else the local
# head of the default branch. show prints the stored premise, or null when it is
# absent or not shaped {sha: 40-hex, at, by: a known value}.
# moved prints {moved, reason, head, paths}: whether a file the card names changed on the
# default branch since its stamp. paths is the card's Scope paths plus every backticked span
# in its acceptance items that, taken whole, passes the Scope path rule; a directory covers
# its descendants. No readable default head: moved false (a project with no remote is never
# held). No stamp: moved true, "no premise stamp". A stamp commit the repository lacks:
# moved true, "premise stamp commit is unknown". Otherwise "ground moved: <path>" for the
# first changed file under a card path.
#
# add-dep appends <m> to card <n>'s blocked_by when absent, keeping the rest; <m> equal to <n>
# or a missing card exits 2.
#
# Exit codes: 0 done, 1 moved: the card cannot be read, 2 usage, 3 the card (or the default
# head) cannot be read.
set -uo pipefail
unset CDPATH
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

USAGE="usage: premise.sh stamp <n> --by <by> [--sha <40-hex>] | premise.sh show <n> | premise.sh moved <n> | premise.sh add-dep <n> <m>"
[ $# -ge 2 ] || fb_die 2 "$USAGE"
VERB="$1"; N="$2"; shift 2
fb_valid_number "$N" || fb_die 2 "card number must be numeric, got: $N"
BY=""; SHA=""

case "$VERB" in
  stamp)
    while [ $# -gt 0 ]; do
      [ $# -ge 2 ] || fb_die 2 "$USAGE"
      case "$1" in
        --by) BY="$2" ;;
        --sha) SHA="$2" ;;
        *) fb_die 2 "$USAGE" ;;
      esac
      shift 2
    done
    case "$BY" in
      create|edit|move|check|approve) ;;
      *) fb_die 2 "--by must be create, edit, move, check or approve, got: $BY" ;;
    esac
    if [ -n "$SHA" ]; then
      printf '%s' "$SHA" | grep -Eq '^[0-9a-f]{40}$' || fb_die 2 "--sha must be 40 lowercase hex characters, got: $SHA"
    fi
    ;;
  add-dep)
    [ $# -eq 1 ] || fb_die 2 "$USAGE"
    DEP="$1"
    fb_valid_number "$DEP" || fb_die 2 "card number must be numeric, got: $DEP"
    [ "$DEP" != "$N" ] || fb_die 2 "add-dep names #$DEP, the card itself"
    ;;
  show|moved) [ $# -eq 0 ] || fb_die 2 "$USAGE" ;;
  *) fb_die 2 "$USAGE" ;;
esac

fb_load_config
. "$FB_SCRIPTS/adapters/local/local-lib.sh"

if [ "$VERB" = add-dep ]; then
  [ -f "$(fl_card_file "$DEP")" ] || fb_die 2 "add-dep names #$DEP, which does not exist in $(fl_cards_dir)"
  [ -f "$(fl_card_file "$N")" ] || fb_die 3 "card #$N not found in $(fl_cards_dir)"
  fb_lock "$N"
  TMP="$(mktemp)" || fb_die 1 "cannot create a temporary file"
  trap 'rm -f "$TMP"; fb_lock_release "$FB_LOCK"' EXIT
  CARD="$(fl_read_card "$N")" || exit 3
  jq --argjson m "$DEP" '.blocked_by = ((.blocked_by // []) | if index($m) then . else . + [$m] end)' <<<"$CARD" > "$TMP" \
    || fb_die 1 "cannot update card #$N"
  fl_write_card "$N" "$TMP" || exit 1
  exit 0
fi

if [ "$VERB" = moved ]; then
  CARD="$(fl_read_card "$N")" || exit 1
  HEAD_SHA="$(fl_default_head)" || HEAD_SHA=""
  if [ -z "$HEAD_SHA" ]; then
    jq -nc '{moved: false, reason: null, head: null, paths: []}'
    exit 0
  fi
  # the card's paths: its Scope paths, and the backticked acceptance spans that pass the Scope rule
  SCOPE_PATHS="$(fb_card_scope_paths "$(jq -r '.body // ""' <<<"$CARD")")"
  ACC_BODY="$(jq -r '"## Scope\n" + ([(.acceptance // [])[] | strings | scan("`([^`]+)`") | "- `" + .[0] + "`"] | join("\n")) + "\n"' <<<"$CARD")"
  PATHS="$(jq -cn --argjson a "$SCOPE_PATHS" --argjson b "$(fb_card_scope_paths "$ACC_BODY")" '$a + $b | unique')"
  STAMP="$(jq -r '(.premise.sha // "") | if test("^[0-9a-f]{40}$") then . else "" end' <<<"$CARD" 2>/dev/null)"
  REASON=""
  if [ -z "$STAMP" ]; then
    REASON="no premise stamp"
  elif ! git -C "$FLEET_ROOT" cat-file -e "$STAMP^{commit}" 2>/dev/null; then
    REASON="premise stamp commit is unknown"
  elif CHANGED="$(git -C "$FLEET_ROOT" diff --name-only "$STAMP" "$HEAD_SHA" 2>/dev/null)"; then
    HIT="$(jq -nr --argjson p "$PATHS" --arg c "$CHANGED" '
      ($p | map(sub("^([.]/)+"; "") | sub("/+$"; ""))) as $ps
      | first(($c | split("\n")[] | select(length > 0)) as $f
              | select(any($ps[]; . as $q | $q != "" and ($f == $q or ($f | startswith($q + "/")))))
              | $f) // empty')"
    [ -z "$HIT" ] || REASON="ground moved: $HIT"
  else
    REASON="premise stamp commit is unknown"
  fi
  jq -nc --arg r "$REASON" --arg h "$HEAD_SHA" --argjson p "$PATHS" \
    '{moved: ($r != ""), reason: (if $r == "" then null else $r end), head: $h, paths: $p}'
  exit 0
fi

[ -f "$(fl_card_file "$N")" ] || fb_die 3 "card #$N not found in $(fl_cards_dir)"

if [ "$VERB" = show ]; then
  jq -c '(.premise as $p
      | if ($p | type) == "object" and ($p.sha | type) == "string" and ($p.sha | test("^[0-9a-f]{40}$"))
           and ($p.at | type) == "string"
           and (["create","edit","move","check","approve"] | index($p.by)) != null
        then $p else null end)' "$(fl_card_file "$N")" 2>/dev/null \
    || fb_die 3 "card #$N is not valid JSON"
  exit 0
fi

if [ -z "$SHA" ]; then
  SHA="$(fl_default_head)" || fb_die 3 "cannot read the default branch head"
fi
fb_lock "$N"
TMP="$(mktemp)" || fb_die 1 "cannot create a temporary file"
trap 'rm -f "$TMP"; fb_lock_release "$FB_LOCK"' EXIT
CARD="$(fl_read_card "$N")" || exit 3
jq --argjson p "$(fl_premise_json "$BY" "$SHA")" '.premise = $p' <<<"$CARD" > "$TMP" || fb_die 1 "cannot update card #$N"
fl_write_card "$N" "$TMP" || exit 1
