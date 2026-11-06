#!/usr/bin/env bash
# migrate-to-local.sh [--force] [--note-author <login>] <card.json>...
#
# Writes a local board store (<board.dir>/cards/<n>.json and <board.dir>/next)
# from cards saved with `board-read.sh <n>` on another backend. Run from the
# repo root; the config may still name the old backend.
#
# Each card keeps its number, title, body, state, labels, created_at and
# updated_at (when the saved JSON has them; else now) and every comment's
# author, body and created_at. Comments get local ids 1..k in their saved
# order. The comment that was the card's manager note (manager_note_id) is
# re-authored to the local login (--note-author, else FLEET_BOARD_USER, else
# $USER, else `id -un`), since the local read only trusts a note by that
# login. url, item_id and the comments' remote ids have no place in the local
# shape and are dropped. next becomes one more than the highest card number
# in the store.
#
# Refuses (exit 1) when the store already has a next file or a card, unless
# --force, which overwrites the named cards and leaves the others. Validates
# every input before writing anything. Prints one line per card written.
# Exit: 0 written; 1 bad input, existing store or write failure; 2 usage.
set -uo pipefail
unset CDPATH
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/board-lib.sh"

usage() { fb_die 2 "usage: migrate-to-local.sh [--force] [--note-author <login>] <card.json>..."; }

FORCE=0
NOTE_AUTHOR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --note-author) [ $# -ge 2 ] && [ -n "$2" ] || usage; NOTE_AUTHOR="$2"; shift 2 ;;
    --) shift; break ;;
    -*) usage ;;
    *) break ;;
  esac
done
[ $# -ge 1 ] || usage

if [ -z "$NOTE_AUTHOR" ]; then
  NOTE_AUTHOR="${FLEET_BOARD_USER:-${USER:-}}"
  [ -n "$NOTE_AUTHOR" ] || NOTE_AUTHOR="$(id -un 2>/dev/null)"
  [ -n "$NOTE_AUTHOR" ] || fb_die 1 "cannot determine the local user: pass --note-author or set FLEET_BOARD_USER"
fi

fb_load_config
. "$FLEET_SCRIPTS/adapters/local/local-lib.sh"
DIR="$(fl_dir)"
CARDS="$(fl_cards_dir)"

# Validate every input first, so a bad file writes nothing.
for f in "$@"; do
  [ -f "$f" ] || fb_die 1 "no such card file: $f"
  jq -e '
    type == "object"
    and (.number | type == "number" and . > 0 and . == floor)
    and (.title | type == "string")
    and ((.body // "") | type == "string")
    and ((.labels // []) | type == "array" and all(.[]; type == "string"))
    and ((.comments // []) | type == "array"
         and all(.[]; type == "object" and (.body | type == "string")))' "$f" >/dev/null 2>&1 \
    || fb_die 1 "not a saved card (need an integer number, a title, string labels and comment bodies): $f"
done

if [ "$FORCE" = 0 ]; then
  if [ -e "$DIR/next" ] || [ -n "$(find "$CARDS" -maxdepth 1 -name '*.json' 2>/dev/null | head -n 1)" ]; then
    fb_die 1 "a local board already exists at $DIR; pass --force to overwrite the named cards"
  fi
fi
mkdir -p "$CARDS" || fb_die 1 "cannot create $CARDS"

NOW="$(fl_now)"
TMP="$(mktemp)" || fb_die 1 "cannot create a temporary file"
trap 'rm -f "$TMP"' EXIT
for f in "$@"; do
  N="$(jq -r .number "$f")"
  jq --arg me "$NOTE_AUTHOR" --arg now "$NOW" '
    .manager_note_id as $nid
    | (.comments // []) as $cs
    | {
        number: .number,
        title: .title,
        body: (.body // ""),
        state: .state,
        labels: (.labels // []),
        created_at: (.created_at // $now),
        updated_at: (.updated_at // .created_at // $now),
        next_comment_id: (($cs | length) + 1),
        comments: [range(0; $cs | length) as $i | $cs[$i]
                   | {id: ($i + 1),
                      author: (if $nid != null and .id == $nid then $me else (.author // "unknown") end),
                      body: .body,
                      created_at: (.created_at // $now)}]
      }' "$f" > "$TMP" || fb_die 1 "cannot convert card #$N from $f"
  fl_write_card "$N" "$TMP" || exit 1
  jq -r '"migrated #\(.number) \(.state // "no-state") \(.comments | length) comments"
         + (if any(.comments[]; .body | startswith("<!-- fleet-board:manager-note -->")) then ", manager note" else "" end)
         + ": \(.title)"' "$(fl_card_file "$N")"
  [ "$(jq -r '.state // ""' "$f")" != "" ] \
    || printf 'fleet-board: warning: card #%s has no state; it will not show in any column\n' "$N" >&2
done

MAX="$(for c in "$CARDS"/*.json; do basename "$c" .json; done | grep -E '^[0-9]+$' | sort -n | tail -n 1)"
OLD=""
[ -f "$DIR/next" ] && OLD="$(tr -d '[:space:]' < "$DIR/next" 2>/dev/null)"
NEXT=$((MAX + 1))
case "$OLD" in ''|*[!0-9]*) ;; *) [ "$OLD" -gt "$NEXT" ] && NEXT="$OLD" ;; esac
printf '%s\n' "$NEXT" > "$DIR/next.tmp.$$" && mv -f "$DIR/next.tmp.$$" "$DIR/next" \
  || { rm -f "$DIR/next.tmp.$$"; fb_die 1 "cannot write $DIR/next"; }
