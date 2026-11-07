#!/usr/bin/env bash
# edit.sh <n> [--title-file F] [--body-file F] [--labels-json J] [--acceptance-file F]
#             [--blocked-by-json J] [--pr-url U]
# Local-only, called by the web server. Every flag is optional; an omitted flag
# (or an empty file argument, or --labels-json null) leaves that field unchanged.
# A body with "## Acceptance" / "## Depends on" sections is split into the card
# fields unless --acceptance-file / --blocked-by-json is given; a body without
# a section clears that field (the body is the whole truth about its sections). --pr-url sets
# pr_url with source "person"; an empty U clears both.
set -uo pipefail
unset CDPATH
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/board-lib.sh"
. "$FB_SCRIPTS/adapters/local/local-lib.sh"

USAGE="usage: edit.sh <number> [--title-file F] [--body-file F] [--labels-json J] [--acceptance-file F] [--blocked-by-json J] [--pr-url U]"
[ $# -ge 1 ] || fb_die 2 "$USAGE"
N="$1"; shift
fb_valid_number "$N" || fb_die 2 "card number must be numeric, got: $N"
TITLE_FILE=""; BODY_FILE=""; LABELS=null; ACC_FILE=""; BLOCKED=null; PR_SET=0; PR_URL=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || fb_die 2 "$USAGE"
  case "$1" in
    --title-file) TITLE_FILE="$2" ;;
    --body-file) BODY_FILE="$2" ;;
    --labels-json) LABELS="$2" ;;
    --acceptance-file) ACC_FILE="$2" ;;
    --blocked-by-json) BLOCKED="$2" ;;
    --pr-url) PR_SET=1; PR_URL="$2" ;;
    *) fb_die 2 "$USAGE" ;;
  esac
  shift 2
done
for f in "$TITLE_FILE" "$BODY_FILE" "$ACC_FILE"; do
  [ -z "$f" ] || [ -f "$f" ] || fb_die 2 "file not found: $f"
done
jq -e '. == null or (type == "array" and all(.[]; type == "string"))' >/dev/null 2>&1 <<<"$LABELS" \
  || fb_die 2 "labels must be null or a JSON array of strings"
jq -e '. == null or type == "array"' >/dev/null 2>&1 <<<"$BLOCKED" \
  || fb_die 2 "blocked_by must be null or a JSON array of positive integers"
fb_load_config
fl_require_store
fb_lock "$N"
CARD="$(fl_read_card "$N")" || exit $?
TMP="$(mktemp)" || fb_die 1 "cannot create a temporary file"
BODYTMP="$(mktemp)" || fb_die 1 "cannot create a temporary file"
trap 'rm -f "$TMP" "$BODYTMP"; rm -rf "$FB_LOCK"' EXIT

ACC=null
if [ -n "$ACC_FILE" ]; then ACC="$(fl_acceptance_json "$ACC_FILE")" || exit 1; fi
if [ -n "$BODY_FILE" ]; then
  SPLIT="$(fl_split_body "$BODY_FILE")" || exit 1
  fl_fold_outside "$SPLIT" "#$N" > "$BODYTMP" || exit 1
  [ "$ACC" != null ] || ACC="$(jq -c .acceptance <<<"$SPLIT")"
  [ "$BLOCKED" != null ] || BLOCKED="$(jq -c .blocked_by <<<"$SPLIT")"
fi
if [ "$BLOCKED" != null ]; then
  BLOCKED="$(fl_uniq_json <<<"$BLOCKED")"
  # only refs this edit adds are checked: one already stored stays even when
  # its card is gone (a hand edit or an import), so a prose save still works
  NEWREFS="$(jq -c --argjson s "$(jq -c '[.blocked_by[]?]' <<<"$CARD")" \
    'if type == "array" then map(. as $x | select($s | index([$x]) | not)) else . end' <<<"$BLOCKED")"
  fl_check_blocked_by "$N" "$NEWREFS"
fi
jq --rawfile t "${TITLE_FILE:-/dev/null}" --rawfile b "$BODYTMP" \
  --arg title_file "$TITLE_FILE" --arg body_file "$BODY_FILE" \
  --argjson l "$LABELS" --argjson acc "$ACC" --argjson blk "$BLOCKED" \
  --argjson pr_set "$PR_SET" --arg pr "$PR_URL" --arg now "$(fl_now)" '
  (if $title_file != "" then .title = ($t | sub("\n+$"; "")) else . end)
  | (if $body_file != "" then .body = $b else . end)
  | (if $l != null then .labels = $l else . end)
  | (if $acc != null then .acceptance = $acc else . end)
  | (if $blk != null then .blocked_by = $blk else . end)
  | (if $pr_set == 1 then (if $pr == "" then .pr_url = null | .pr_url_source = null else .pr_url = $pr | .pr_url_source = "person" end) else . end)
  | .updated_at = $now' <<<"$CARD" > "$TMP" \
  || fb_die 1 "cannot update card #$N"
fl_write_card "$N" "$TMP" || exit 1
