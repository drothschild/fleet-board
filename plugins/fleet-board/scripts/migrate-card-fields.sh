#!/usr/bin/env bash
# migrate-card-fields.sh [--dry-run]
# Gives every local card file that lacks them the first-class fields
# acceptance, blocked_by, pr_url and pr_url_source: the "## Acceptance" and
# "## Depends on" sections move out of body into the fields (fl_split_body),
# and pr_url comes from the "pr" of the manager note written by the local login
# (fb_login; source "note"). A dependency
# that is not a card on this board (outside, missing, or the card itself) stays
# in the body as a prose line and is
# warned about on stderr. updated_at is left alone. Idempotent: a card that
# has all four fields is skipped. Prints one line per changed card.
set -uo pipefail
unset CDPATH
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

DRY=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY=1 ;;
  *) fb_die 2 "usage: migrate-card-fields.sh [--dry-run]" ;;
esac
[ $# -le 1 ] || fb_die 2 "usage: migrate-card-fields.sh [--dry-run]"
fb_load_config
. "$FB_SCRIPTS/adapters/local/local-lib.sh"
fl_require_store

REPO_SLUG="$(fb_cfg board.repo)"
ME="$(fb_login)" || exit 1
BODYF="$(mktemp)" || fb_die 1 "cannot create a temporary file"
OUTF="$(mktemp)" || fb_die 1 "cannot create a temporary file"
trap 'rm -f "$BODYF" "$OUTF"' EXIT

# migrate_one <n>: with the card lock held for a real run.
migrate_one() {
  local n="$1" f card split pr line
  f="$(fl_card_file "$n")"
  card="$(fl_read_card "$n")" || exit 1
  jq -e 'has("acceptance") and has("blocked_by") and has("pr_url") and has("pr_url_source")' <<<"$card" >/dev/null && return 0
  jq -j '.body // ""' <<<"$card" > "$BODYF"
  if jq -e 'has("acceptance") or has("blocked_by")' <<<"$card" >/dev/null; then
    split='{"body":null,"acceptance":[],"blocked_by":[],"outside":[]}'
    jq -j '.body // ""' <<<"$card" > "$BODYF"
  else
    split="$(fl_split_body "$BODYF")" || exit 1
  fi
  # a dependency on a card that is missing or the card itself would wait
  # forever: it stays in the body as prose, like an outside one
  for b in $(jq -r '.blocked_by[]' <<<"$split"); do
    if [ "$b" = "$n" ] || [ ! -f "$(fl_card_file "$b")" ]; then
      split="$(jq -c --argjson b "$b" '.blocked_by -= [$b] | .outside += ["#" + ($b | tostring)]' <<<"$split")"
    fi
  done
  jq -r '.outside[]' <<<"$split" | while IFS= read -r line; do
    printf 'fleet-board: warning: card #%s: dependency %s is outside this board; kept in the body as prose\n' "$n" "$line" >&2
  done
  jq --argjson sp "$split" --arg repo "$REPO_SLUG" --arg m "$FB_MARKER" --arg me "$ME" '
    def note_pr:
      [(.comments // [])[] | select((.body // "") | startswith($m)) | select(.author == $me)] | last
      | if . == null then null
        else (.body | split("\n") | reduce .[] as $l ({on: false, buf: [], done: false};
                if .done then .
                elif .on and ($l | test("^```")) then .done = true
                elif .on then .buf += [$l]
                elif ($l | test("^```json")) then .on = true
                else . end) | .buf | join("\n"))
             | (try fromjson catch null) | if type == "object" then .pr else null end
        end;
    (note_pr) as $pr
    | (($pr | type) == "number" and $pr == ($pr | floor) and $pr > 0) as $has_pr
    | (if $sp.body != null then
         .body = ($sp.body | sub("\n+$"; "") | if . == "" then "" else . + "\n" end)
         | if ($sp.outside | length) > 0 then
             .body = (.body | sub("\n+$"; "")) + (if .body == "" then "" else "\n\n" end)
               + ($sp.outside | map("Depends on (outside this board): " + .) | join("\n")) + "\n"
           else . end
       else . end)
    | .acceptance = (.acceptance // $sp.acceptance)
    | .blocked_by = (.blocked_by // $sp.blocked_by)
    | (if has("pr_url") then . elif $has_pr then .pr_url = ("https://github.com/" + $repo + "/pull/" + ($pr | tostring)) else .pr_url = null end)
    | (if has("pr_url_source") then . elif $has_pr then .pr_url_source = "note" else .pr_url_source = null end)' <<<"$card" > "$OUTF" \
    || fb_die 1 "cannot migrate card #$n"
  line="#$n: acceptance $(jq '.acceptance | length' "$OUTF"), blocked_by $(jq -c '.blocked_by' "$OUTF"), pr_url $(jq -r '.pr_url // "none"' "$OUTF")"
  if [ "$DRY" = 1 ]; then
    printf 'would change %s\n' "$line"
  else
    fl_write_card "$n" "$OUTF" || exit 1
    printf 'changed %s\n' "$line"
  fi
}

CARDS="$(fl_cards_dir)"
NUMBERS="$(for f in "$CARDS"/*.json; do [ -e "$f" ] || continue; b="${f##*/}"; echo "${b%.json}"; done | LC_ALL=C sort -n)"
for n in $NUMBERS; do
  case "$n" in ''|*[!0-9]*) continue ;; esac
  if [ "$DRY" = 1 ]; then
    migrate_one "$n"
  else
    fb_lock "$n"
    trap 'rm -f "$BODYF" "$OUTF"; fb_lock_release "$FB_LOCK"' EXIT
    migrate_one "$n"
    fb_lock_release "$FB_LOCK"
  fi
done
