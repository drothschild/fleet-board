#!/usr/bin/env bash
# create.sh <title> <body-file> [--label L]... [--state S] [--acceptance-file F] [--blocked-by N]...
# A body that carries "## Acceptance" / "## Depends on" sections is split into
# the card fields; --acceptance-file and --blocked-by, when given, win over it.
set -uo pipefail
. "$FLEET_SCRIPTS/board-lib.sh"
. "$FLEET_SCRIPTS/adapters/local/local-lib.sh"

TITLE="$1"
BODY_FILE="$2"
shift 2
labels=()
blocked=()
STATE="${FB_CREATE_STATE:-backlog}"
ACC_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --label) labels+=("$2"); shift 2 ;;
    --state) STATE="$2"; shift 2 ;;
    --acceptance-file) ACC_FILE="$2"; shift 2 ;;
    --blocked-by) blocked+=("$2"); shift 2 ;;
    *) fb_die 2 "create.sh: unknown argument: $1" ;;
  esac
done
[ -z "$ACC_FILE" ] || [ -f "$ACC_FILE" ] || fb_die 2 "file not found: $ACC_FILE"

fl_require_store
SPLIT="$(fl_split_body "$BODY_FILE")" || exit 1
fl_check_bad_deps "$SPLIT"
if [ -n "$ACC_FILE" ]; then ACC="$(fl_acceptance_json "$ACC_FILE")" || exit 1; else ACC="$(jq -c .acceptance <<<"$SPLIT")"; fi
if [ ${#blocked[@]} -gt 0 ]; then
  BLOCKED="$(jq -nc '$ARGS.positional | map(tonumber? // .)' --args "${blocked[@]}" | fl_uniq_json)"
else
  BLOCKED="$(jq -c .blocked_by <<<"$SPLIT")"
fi
# Refuse before a number is spent: the number about to be allocated is the card itself.
NEXT="$(tr -d '[:space:]' < "$(fl_dir)/next" 2>/dev/null)"
fl_check_blocked_by "$NEXT" "$BLOCKED"

N="$(fl_next_number)" || exit 1
fb_lock "$N"
TMP="$(mktemp)" || fb_die 1 "cannot create a temporary file"
BODYTMP="$(mktemp)" || fb_die 1 "cannot create a temporary file"
trap 'rm -f "$TMP" "$BODYTMP"; fb_lock_release "$FB_LOCK"' EXIT
fl_check_blocked_by "$N" "$BLOCKED"
fl_fold_outside "$SPLIT" "#$N" > "$BODYTMP" || exit 1
for l in ${labels[@]+"${labels[@]}"}; do
  if [ "$l" = needs-human-qa ]; then
    QB="$(cat "$BODYTMP"; printf x)"; QB="${QB%x}"
    fl_add_qa_section "$QB" > "$BODYTMP" || exit 1
    break
  fi
done
LABELS_JSON="$(printf '%s\n' ${labels[@]+"${labels[@]}"} | jq -R . | jq -sc 'map(select(. != ""))')"
jq -n --argjson n "$N" --arg t "$TITLE" --rawfile b "$BODYTMP" \
  --arg s "$STATE" --argjson l "$LABELS_JSON" --arg now "$(fl_now)" \
  --argjson acc "$ACC" --argjson blk "$BLOCKED" \
  '{number: $n, title: $t, body: $b, acceptance: $acc, blocked_by: $blk, pr_url: null, pr_url_source: null,
    state: $s, labels: $l, next_comment_id: 1, comments: [], created_at: $now}' > "$TMP" \
  || fb_die 1 "cannot build card #$N"
fl_write_card "$N" "$TMP" || exit 1
jq -nc --argjson n "$N" --arg u "$(fl_url "$N")" '{number: $n, url: $u}'
