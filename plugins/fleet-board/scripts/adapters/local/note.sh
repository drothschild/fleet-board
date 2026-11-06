#!/usr/bin/env bash
set -uo pipefail
. "$FLEET_SCRIPTS/board-lib.sh"
. "$FLEET_SCRIPTS/adapters/local/local-lib.sh"

N="$1"
ME="$(fb_login)" || exit 1
fl_require_store
fb_lock "$N"
CARD="$(fl_read_card "$N")" || exit $?
BODY="$(mktemp)" || fb_die 1 "cannot create a temporary file"
TMP="$(mktemp)" || { rm -f "$BODY"; fb_die 1 "cannot create a temporary file"; }
trap 'rm -f "$BODY" "$TMP"; rm -rf "$FB_LOCK"' EXIT
{
  printf '%s\n' "$FB_MARKER"
  cat "$2"
} > "$BODY"
# The note's "pr" drives pr_url: "has" says whether the key is there (an
# integer or null), "pr" its value. Unparsable bodies change nothing and warn.
PRINFO="$(jq -Rsc '
  split("\n") | reduce .[] as $l ({on: false, buf: [], done: false};
    if .done then .
    elif .on and ($l | test("^```")) then .done = true
    elif .on then .buf += [$l]
    elif ($l | test("^```json")) then .on = true
    else . end)
  | if .done | not then {ok: false}
    else (.buf | join("\n") | try fromjson catch null) as $j
      | if ($j | type) != "object" then {ok: false}
        elif ($j | has("pr") | not) then {ok: true, has: false}
        elif $j.pr == null then {ok: true, has: true, pr: null}
        elif ($j.pr | type) == "number" and $j.pr == ($j.pr | floor) and $j.pr > 0 then {ok: true, has: true, pr: $j.pr}
        else {ok: false} end
    end' < "$2")" || PRINFO='{"ok":false}'
if [ "$(jq -r '.ok' <<<"$PRINFO")" != true ]; then
  printf 'fleet-board: warning: manager note on #%s has no parsable json block with a valid "pr"; pr_url left as it is\n' "$N" >&2
fi
jq --arg m "$FB_MARKER" --arg me "$ME" --rawfile b "$BODY" --arg now "$(fl_now)" \
  --argjson pi "$PRINFO" --arg repo "$(fb_cfg board.repo)" '
  def apply_pr:
    if ($pi.ok | not) or ($pi.has | not) then .
    elif $pi.pr == null then
      (if .pr_url_source == "note" then .pr_url = null | .pr_url_source = null else . end)
    else
      ("https://github.com/" + $repo + "/pull/" + ($pi.pr | tostring)) as $u
      | if .pr_url_source == "person" and ((.pr_url // "") | test("/pull/" + ($pi.pr | tostring) + "$")) then .
        else .pr_url = $u | .pr_url_source = "note" end
    end;
  (.comments // []) as $cs
  | ([range(0; $cs | length) | select($cs[.].body | startswith($m)) | select($cs[.].author == $me)] | last) as $i
  | if $i != null then
      .comments[$i].body = $b | .comments[$i].updated_at = $now
    else
      (.next_comment_id // (($cs | map(.id) | max // 0) + 1)) as $id
      | .comments = $cs + [{id: $id, author: $me, body: $b, created_at: $now}]
      | .next_comment_id = $id + 1
    end
  | apply_pr
  | .updated_at = $now' <<<"$CARD" > "$TMP" \
  || fb_die 1 "cannot update card #$N"
fl_write_card "$N" "$TMP" || exit 1
