#!/usr/bin/env bash
# note.sh - the manager note codec: reads, writes and merges a card's note.
#
# Usage:
#   note.sh get <n>                    print the note JSON ({} when there is none)
#   note.sh parse <n> < <board-read-json>
#                                      the same as get, from a board-read.sh
#                                      output on stdin (no board call)
#   note.sh put <n> <json-file>        write the note (missing keys get defaults)
#   note.sh merge <n> <json-patch>     get, merge the patch in, put
#   note.sh reset-failures <n>         merge {"action_failures": 0,
#                                      "last_action_error": null} (no file)
#   note.sh fail <n> <error>           merge {"action_failures": <stored> + 1,
#                                      "last_action_error": <error>} (no file)
#
# The note is a comment on the card: the marker line (added by board-note.sh),
# a heading, a one-line summary, and one fenced ```json block holding the note.
#
# get validates the note before trusting it (fields that could steer shell
# commands). An invalid note prints {} and a warning on stderr:
#   fleet-board: warning: ignoring invalid manager note on #<n>: <field>
# A worktree that is a well-formed absolute path (no control character, no
# ".." segment) but lies outside the current normalized worktrees base (the
# repo was re-cloned or moved, or worktrees.dir changed) does not reject the
# note: get prints it with worktree null and warns
#   fleet-board: warning: manager note on #<n> names a worktree outside <base>; treating it as null: <path>
# put refuses to write a note that get would reject, and a worktree outside
# the base.
#
# action_failures (a non-negative integer, default 0) and last_action_error
# (a string or null) count the manager's actions on the card that failed to
# make progress, in a row (the manager resets them after one that did);
# tick-plan.sh blocks the card at review.max_rounds, and skips it for a
# person at 2 * review.max_rounds (review.max_rounds when it is blocked and
# its unblock is due). A hand move does not reset them; reset-failures does.
# get rejects a last_action_error holding a control character; put and
# merge replace each control character in it with a space first, since it
# is written from an error line and a refused write would lose the count.
# The summary line shows the count and the error when action_failures > 0.
# A note written before the rename holds setup_failures and last_setup_error:
# get, parse, merge and put read them as action_failures and
# last_action_error (the new key wins when both are present) and drop them.
#
# reset-failures is what a person runs after moving a card that tick-plan.sh
# skips on its count (its warnings end with this command): a hand move does not
# reset the count, so without it the card would be skipped, or blocked again.
# It behaves exactly like merge with that patch, including the refusal below.
#
# fail counts one action failure from its arguments alone. The manager uses it
# when a step fails before a patch file exists, or because one cannot be
# written (a refused Write): counting through merge would need that file, the
# count would never rise, and tick-plan.sh would never block the card. The
# error must be non-empty; like merge, it refuses an invalid stored note.
#
# merge: out_of_scope_created and bugs_filed append (deduplicated by title,
# compared case-insensitively), report_errors appends, pending_followups is
# replaced whole, and every other key is merged with jq's * operator. merge
# refuses (exit 1, nothing written) when the stored note is invalid, so that
# it never overwrites it with a note built from {}; replace it with put.
#
# Exit codes:
#   0 - success (get: note or {} printed)
#   1 - the card could not be read or written (parse: stdin is not a card),
#       the note's JSON block does not parse, put/merge was given an invalid
#       note or a file that is not a JSON object, or merge (or reset-failures)
#       found the stored note invalid (also fail)
#   2 - usage error (fail: a missing or empty error)

set -uo pipefail
unset CDPATH # a relative cd must not follow CDPATH (it would also echo the path)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

usage() { fb_die 2 "usage: note.sh get <n> | parse <n> < <board-read-json> | put <n> <json-file> | merge <n> <json-patch-file> | reset-failures <n> | fail <n> <error>"; }

[ $# -ge 2 ] || usage
CMD="$1"
N="$2"
fb_valid_number "$N" || fb_die 2 "card number must be numeric, got: $N"
case "$CMD" in
  get|parse|reset-failures) [ $# -eq 2 ] || usage ;;
  put|merge)
    [ $# -eq 3 ] || usage
    [ -f "$3" ] || fb_die 2 "file not found: $3"
    ;;
  fail)
    [ $# -eq 3 ] || usage
    [ -n "$3" ] || fb_die 2 "note.sh fail needs a non-empty error"
    ;;
  *) usage ;;
esac

fb_load_config

# The normalized worktrees base: worktree paths must be this or under it
WT_DIR="$FLEET_ROOT/$(fb_cfg worktrees.dir)"
BASE="$(mkdir -p "$WT_DIR" && cd "$WT_DIR" && pwd -P)" || fb_die 1 "cannot resolve the worktrees directory $WT_DIR"
[ -n "$BASE" ] || fb_die 1 "cannot resolve the worktrees directory $WT_DIR"

TMP=""
trap '[ -n "$TMP" ] && rm -f "$TMP"' EXIT

DEFAULTS='{"state":null,"branch":null,"worktree":null,"pr":null,"round":null,"models":null,
  "escalated":null,"escalated_at_round":null,"last_verified":null,"last_review":null,
  "blocked_findings":[],"blocking_pr":null,"merged_pr":null,"main_check":null,
  "out_of_scope_created":[],"bugs_filed":[],"pending_followups":null,"report_errors":[],
  "implementor_attempts":0,"action_failures":0,"last_action_error":null,"updated_at":null}'

# legacy: maps the pre-rename keys setup_failures and last_setup_error to
# action_failures and last_action_error (unless those are present) and drops them
LEGACY='def legacy: if type != "object" then . else
    (if has("setup_failures") and (has("action_failures") | not) then .action_failures = .setup_failures else . end)
    | (if has("last_setup_error") and (has("last_action_error") | not) then .last_action_error = .last_setup_error else . end)
    | del(.setup_failures, .last_setup_error) end;'

# invalid_field <json>: prints the first field that fails validation, or
# nothing. A worktree that is well-formed but outside $BASE is checked last and
# reported as "worktree-outside-base", so any other invalid field wins.
invalid_field() {
  jq -r --arg base "$BASE" '
    def int: type == "number" and . == floor;
    def nint: . == null or int;
    def clean: test("[[:cntrl:]]") | not;
    if type != "object" then "note"
    elif (.pr | nint | not) then "pr"
    elif (.blocking_pr | nint | not) then "blocking_pr"
    elif (.merged_pr | nint | not) then "merged_pr"
    elif (.branch | . == null or (type == "string" and test("\\Afleet/[0-9]+-[a-z0-9-]{1,40}\\z")) | not) then "branch"
    elif (.worktree | . == null or (type == "string" and clean and startswith("/")
            and ((split("/") | any(.[]; . == "..")) | not)) | not) then "worktree"
    elif (.round | nint | not) then "round"
    elif (.implementor_attempts | nint | not) then "implementor_attempts"
    elif (.action_failures | . == null or (int and . >= 0) | not) then "action_failures"
    elif (.last_action_error | . == null or (type == "string" and clean) | not) then "last_action_error"
    elif (.pending_followups | . == null or type == "object" | not) then "pending_followups"
    elif (.pending_followups | . == null or (.pr | nint) | not) then "pending_followups.pr"
    elif (.worktree | . == null or . == $base or startswith($base + "/") | not) then "worktree-outside-base"
    else empty end' <<<"$1"
}

# one_object <file>: prints the file's single JSON object, compact; fails otherwise
one_object() {
  jq -s -c 'if length == 1 and (.[0] | type) == "object" then .[0] else error("not one JSON object") end' "$1" 2>/dev/null
}

# note_from_card <board-read-json>: prints the validated note JSON, or {}
# (with a warning) when invalid. Returns 1 when the card does not parse or the
# note's JSON block does not parse, and 3 when the note was rejected as invalid
# ({} printed).
note_from_card() {
  local card="$1" body block note rc field wt
  body="$(jq -r 'if type == "object" then .manager_note // empty else error("not a card") end' <<<"$card" 2>/dev/null)" \
    || { printf 'fleet-board: cannot parse card #%s\n' "$N" >&2; return 1; }
  if [ -z "$body" ]; then echo '{}'; return 0; fi
  block="$(printf '%s\n' "$body" | awk '
    $0 == "```json" && !found { found = 1; on = 1; next }
    on && $0 == "```" { closed = 1; exit }
    on { print }
    END { if (!found) exit 3; if (!closed) exit 4 }')"
  rc=$?
  if [ $rc -eq 3 ]; then echo '{}'; return 0; fi
  if [ $rc -ne 0 ]; then printf 'fleet-board: manager note on #%s has an unterminated json block\n' "$N" >&2; return 1; fi
  note="$(printf '%s\n' "$block" | jq -s -c "$LEGACY"' if length == 1 then .[0] | legacy else error("not one JSON value") end' 2>/dev/null)" \
    || { printf 'fleet-board: manager note on #%s has a json block that does not parse\n' "$N" >&2; return 1; }
  field="$(invalid_field "$note")" || { printf 'fleet-board: cannot validate the manager note on #%s\n' "$N" >&2; return 1; }
  if [ "$field" = worktree-outside-base ]; then
    wt="$(jq -r '.worktree' <<<"$note")"
    printf 'fleet-board: warning: manager note on #%s names a worktree outside %s; treating it as null: %s\n' "$N" "$BASE" "$wt" >&2
    note="$(jq -c '.worktree = null' <<<"$note")" || { printf 'fleet-board: cannot validate the manager note on #%s\n' "$N" >&2; return 1; }
    field="$(invalid_field "$note")" || { printf 'fleet-board: cannot validate the manager note on #%s\n' "$N" >&2; return 1; }
  fi
  if [ -n "$field" ]; then
    printf 'fleet-board: warning: ignoring invalid manager note on #%s: %s\n' "$N" "$field" >&2
    echo '{}'
    return 3
  fi
  printf '%s\n' "$note"
}

# note_get: note_from_card on the card as board-read.sh reads it now
note_get() {
  local card
  card="$(bash "$FLEET_SCRIPTS/board-read.sh" "$N")" || { printf 'fleet-board: cannot read card #%s\n' "$N" >&2; return 1; }
  note_from_card "$card"
}

# note_put <json>: fills defaults, stamps updated_at, renders, writes via board-note.sh
note_put() {
  local full field now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  full="$(jq -c --argjson d "$DEFAULTS" --arg now "$now" "$LEGACY"' $d + legacy + {updated_at: $now}
    | if (.last_action_error | type) == "string" then .last_action_error |= gsub("[[:cntrl:]]"; " ") else . end' <<<"$1")" \
    || fb_die 1 "cannot build the manager note for #$N"
  field="$(invalid_field "$full")" || fb_die 1 "cannot validate the manager note for #$N"
  [ -z "$field" ] || fb_die 1 "refusing to write invalid manager note on #$N: $field"
  TMP="$(mktemp)" || fb_die 1 "cannot create a temp file"
  {
    printf '### fleet-board manager note\n'
    jq -r '
      def v: if . == null then "—" else tostring | gsub("[[:cntrl:]]"; " ") end;
      "State: \(.state | v) · Round: \(.round | v) · PR: \(if .pr == null then "—" else "#\(.pr)" end) · Branch: \(if .branch == null then "—" else "`\(.branch)`" end)"
      + (if (.action_failures // 0) > 0 then " · Action failures: \(.action_failures) (last: \(.last_action_error | v))" else "" end)' <<<"$full"
    printf '\n```json\n'
    jq . <<<"$full"
    printf '```\n'
  } > "$TMP" || fb_die 1 "cannot render the manager note for #$N"
  bash "$FLEET_SCRIPTS/board-note.sh" "$N" "$TMP" || fb_die 1 "cannot write the manager note on #$N"
}

# note_merge <json-patch> <what>: get, merge the patch in, put. <what> names
# the operation in the refusal when the stored note is invalid.
note_merge() {
  local patch="$1" what="$2" old rc merged
  old="$(note_get)"
  rc=$?
  [ $rc -ne 3 ] || fb_die 1 "refusing to $what the invalid manager note on #$N; nothing written (replace it with note.sh put)"
  [ $rc -eq 0 ] || exit 1
  merged="$(jq -c -n --argjson o "$old" --argjson p "$patch" '
      def dedup: reduce .[] as $e ([];
        if ($e | type) == "object" and ($e.title | type) == "string"
           and any(.[]; type == "object" and (.title | type) == "string" and (.title | ascii_downcase) == ($e.title | ascii_downcase))
        then . else . + [$e] end);
      def arr($k): ($o[$k] // []) + ($p[$k] // []);
      ($o * ($p | del(.out_of_scope_created, .bugs_filed, .report_errors, .pending_followups)))
      | if $p | has("pending_followups") then .pending_followups = $p.pending_followups else . end
      | if $p | has("out_of_scope_created") then .out_of_scope_created = (arr("out_of_scope_created") | dedup) else . end
      | if $p | has("bugs_filed") then .bugs_filed = (arr("bugs_filed") | dedup) else . end
      | if $p | has("report_errors") then .report_errors = arr("report_errors") else . end' 2>/dev/null)" \
    || fb_die 1 "cannot merge the patch into the manager note on #$N"
  note_put "$merged"
}

case "$CMD" in
  get)
    note_get
    rc=$?
    [ $rc -eq 0 ] || [ $rc -eq 3 ] || exit 1
    ;;
  parse)
    CARD="$(cat)" || fb_die 1 "cannot read the card from stdin"
    note_from_card "$CARD"
    rc=$?
    [ $rc -eq 0 ] || [ $rc -eq 3 ] || exit 1
    ;;
  put)
    IN="$(one_object "$3")" || fb_die 1 "$3 does not hold one JSON object"
    note_put "$IN"
    ;;
  merge)
    PATCH="$(one_object "$3")" || fb_die 1 "$3 does not hold one JSON object"
    note_merge "$PATCH" "merge into"
    ;;
  reset-failures)
    note_merge '{"action_failures":0,"last_action_error":null}' "reset the action failures on"
    ;;
  fail)
    OLD="$(note_get)"
    rc=$?
    [ $rc -ne 3 ] || fb_die 1 "refusing to count a failure on the invalid manager note on #$N; nothing written (replace it with note.sh put)"
    [ $rc -eq 0 ] || exit 1
    PATCH="$(jq -c -n --argjson o "$OLD" --arg e "$3" \
      '{action_failures: (($o.action_failures // 0) + 1), last_action_error: $e}' 2>/dev/null)" \
      || fb_die 1 "cannot build the failure count for #$N"
    note_merge "$PATCH" "count a failure on"
    ;;
esac
