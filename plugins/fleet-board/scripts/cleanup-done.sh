#!/usr/bin/env bash
# cleanup-done.sh - removes the worktrees of cards that reached done.
#
# Usage: cleanup-done.sh
#
# Lists the done column (board-list.sh --allow-truncated done: a listing at
# the list limit is used with a warning, not refused). It then lists the
# entries directly under the worktrees base once, locally, and keeps only the
# done cards <n> with an entry named <n>-* there (<n>-<slug>, <n>-review,
# <n>-review-copy; only <n>-* entries can belong to a card: other names in
# the base, such as verify-main.sh's main-check, never match one).
# The others have nothing to remove and are skipped silently, before any
# network call. The done column grows without bound, and reading a note costs
# GitHub round trips per card, so the cost must scale with the local dirs, not
# with the column. For each remaining card it reads the
# manager note (note.sh get) and, when the note names a worktree and that
# worktree or the card's <base>/<n>-review or <base>/<n>-review-copy still
# exists, runs
#   worktree.sh remove <n> "<note.worktree>"
# which refuses any path outside the normalized worktrees base and never
# deletes a branch. Prints one line per card cleaned:
#   cleaned #<n> <worktree>
#
# Paths are never guessed: a card whose note names no worktree is left alone,
# and a card whose note is invalid or unreadable is skipped with a warning on
# stderr. A note whose worktree lies outside the current base (note.sh treats
# it as null: the repo was re-cloned or moved, or worktrees.dir changed) has
# nothing here to remove; the card is skipped with a warning, which is not a
# failure. A failure on one card does not stop the others. Running it again is
# a no-op.
#
# Run it outside any Claude session (the headless wrapper runs it after each
# successful tick), or by hand; the manager never removes worktrees.
#
# Exit codes:
#   0 - every done card is clean (or was cleaned)
#   1 - the done column could not be listed (nothing removed), or some card
#       was skipped or could not be cleaned
#   2 - usage error

set -uo pipefail
unset CDPATH # a relative cd must not follow CDPATH (it would also echo the path)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

[ $# -eq 0 ] || fb_die 2 "usage: cleanup-done.sh"

fb_load_config

WT_DIR="$FLEET_ROOT/$(fb_cfg worktrees.dir)"
BASE="$(mkdir -p "$WT_DIR" && cd "$WT_DIR" && pwd -P)" || fb_die 1 "cannot resolve the worktrees directory $WT_DIR"
[ -n "$BASE" ] || fb_die 1 "cannot resolve the worktrees directory $WT_DIR"

# --allow-truncated: the done column only grows, and cleanup needs only the
# recent cards. A listing at the limit is used with a warning; a card it misses
# only leaves its worktree behind.
LIST="$(bash "$FLEET_SCRIPTS/board-list.sh" --allow-truncated done </dev/null)" || fb_die 1 "cannot list the done column; nothing removed"
NUMS="$(jq -r 'if type == "array" then .[].number else error("not a list") end' <<<"$LIST" 2>/dev/null)" \
  || fb_die 1 "cannot parse the done column; nothing removed"

warn() { printf 'fleet-board: warning: %s\n' "$1" >&2; }
exists() { [ -L "$1" ] || [ -e "$1" ]; }

ERR="$(mktemp)" || fb_die 1 "mktemp failed"
trap 'rm -f "$ERR"' EXIT

# The entries directly under the base, listed once and locally: one name per
# line, with a leading newline so every name is preceded by one. Only a done
# card with an entry named <n>-* can have anything here to remove.
NL='
'
LOCAL="$NL"
for e in "$BASE"/*; do
  exists "$e" || continue # the unmatched glob of an empty base
  LOCAL="$LOCAL${e##*/}$NL"
done
has_local() { case "$LOCAL" in *"$NL$1-"*) return 0 ;; esac; return 1; }

RC=0
for n in $NUMS; do
  if ! fb_valid_number "$n"; then
    warn "the done column lists a non-numeric card: $n"
    RC=1
    continue
  fi
  has_local "$n" || continue # nothing on disk: no note read, no network call
  if ! note="$(bash "$FLEET_SCRIPTS/note.sh" get "$n" </dev/null 2>"$ERR")"; then
    cat "$ERR" >&2
    warn "skipping #$n: its manager note cannot be read"
    RC=1
    continue
  fi
  if grep -q 'ignoring invalid manager note' "$ERR"; then
    cat "$ERR" >&2
    warn "skipping #$n: its manager note is invalid"
    RC=1
    continue
  fi
  if grep -q 'names a worktree outside' "$ERR"; then
    cat "$ERR" >&2
    warn "skipping #$n: its manager note names a worktree outside $BASE; nothing removed"
    continue
  fi
  wt="$(jq -r 'if type == "object" then .worktree // empty else empty end' <<<"$note" 2>/dev/null)"
  [ -n "$wt" ] || continue
  exists "$wt" || exists "$BASE/$n-review" || exists "$BASE/$n-review-copy" || continue
  if ! bash "$FLEET_SCRIPTS/worktree.sh" remove "$n" "$wt" </dev/null >/dev/null 2>"$ERR"; then
    cat "$ERR" >&2
    warn "could not clean #$n"
    RC=1
    continue
  fi
  printf 'cleaned #%s %s\n' "$n" "$wt"
done
exit "$RC"
