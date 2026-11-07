#!/usr/bin/env bash
#
# Test helper (not a suite): routes-store.sh <routes-file> <repo-root>
#
# Builds the local card store <repo-root>/.fleet-board (or board.dir) from a
# fake-gh routes file written for the removed GitHub labels board, so the
# suites' issue fixtures keep describing the cards:
#
#   api repos/<board.repo>/issues/<n>                  the card: title, body, labels;
#                                                      state from its fleet:<state> label,
#                                                      else from the listing that lists it
#   api --paginate repos/<board.repo>/issues/<n>/comments
#                                                      its comments (user.login = author)
#   issue list --repo <r> --label fleet:<state> *      a listed number with no issue
#                                                      route becomes a bare card in <state>
#   issue view <n> --repo <board.repo> --json state,stateReason
#                                                      a dependency: done (COMPLETED),
#                                                      wont_do (NOT_PLANNED) or backlog (open)
#   issue list --repo <r> --state open|closed --search *
#                                                      a title search: each row is a card
#                                                      too (open: ready; closed: done,
#                                                      updated at its closedAt)
#   api user                                           the login: printed on stdout, for
#                                                      FLEET_BOARD_USER
#
# As in the fake gh, the first route that matches wins: a later route for the
# same issue, comments or column is ignored. A comments route for
# issues/*/comments applies to every card without its own.
# A route with a non-zero exit for a card's issue or comments read leaves a
# card file that lists (number, title, the listed state) but that board-read.sh
# cannot read (its comments are not a list), as a failed read of a listed card.
# A listing or search route (issue list) with a non-zero exit leaves
# cards/0.json, not a JSON object, so every listing and search fails. Other routes are ignored. The cards are then given their fields by migrate-card-fields.sh
# (run in <repo-root>), so "## Acceptance" and "## Depends on" become
# acceptance and blocked_by as on a migrated board.
#
# With ROUTES_STORE_LISTED_ONLY=1, a card whose state has a listing route that
# does not list it is left out (the listing, not the issue, says which cards
# a column holds).
#
# The store is rebuilt from scratch on every call (the old fake gh answered
# every read from the fixtures too, whatever a script wrote before), so a
# suite calls it before each run. A routes file with no card route
# (api repos/<board.repo>/issues/<n>, issue list, issue view) leaves the
# store alone: the suite seeds it some other way.

set -uo pipefail
unset CDPATH

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROUTES="$1"
ROOT="$2"
RDIR="$(cd "$(dirname "$ROUTES")" && pwd)"
CFG="$(cd "$ROOT" && bash "$HERE/../scripts/config.sh")" || { echo "routes-store: bad config in $ROOT" >&2; exit 1; }
SLUG="$(jq -r .board.repo <<<"$CFG")"
STORE="$ROOT/$(jq -r .board.dir <<<"$CFG")"
if ! grep -Eq '^(api repos/[^ ]+/issues/[0-9]+|issue list |issue view )' "$ROUTES"; then
  login="$(awk -F'\t' '$1 == "api user" && $2 == 0 { print $3; exit }' "$ROUTES")"
  if [ -n "$login" ]; then
    case "$login" in /*) ;; *) login="$RDIR/$login" ;; esac
    jq -r '.login // "fleet-bot"' "$login" 2>/dev/null || echo fleet-bot
  else
    echo fleet-bot
  fi
  exit 0
fi
rm -rf "$STORE/cards"
mkdir -p "$STORE/cards"
# the store is kept out of git, as init.sh's .gitignore line keeps it
if ex="$(git -C "$ROOT" rev-parse --git-path info/exclude 2>/dev/null)"; then
  case "$ex" in /*) ;; *) ex="$ROOT/$ex" ;; esac
  d="$(jq -r .board.dir <<<"$CFG")/"
  grep -qxF -- "$d" "$ex" 2>/dev/null || { mkdir -p "$(dirname "$ex")" && printf '%s\n' "$d" >> "$ex"; }
fi

fx() { case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s/%s\n' "$RDIR" "$1" ;; esac; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
LOGIN=""
while IFS=$'\t' read -r glob code fixture; do
  [ -n "$glob" ] || continue
  case "$glob" in \#*) continue ;; esac
  case "$glob" in
    "issue list "*) if [ "$code" != 0 ] || [ "$fixture" = - ]; then : > "$WORK/list-broken"; continue; fi ;;
  esac
  if [ "$glob" = "api user" ] && [ "$code" = 0 ]; then
    LOGIN="$(jq -r '.login // empty' "$(fx "$fixture")")"
  elif [[ "$glob" =~ ^api\ repos/([^/]+/[^/]+)/issues/([0-9]+)$ ]]; then
    [ "${BASH_REMATCH[1]}" = "$SLUG" ] || continue
    n="${BASH_REMATCH[2]}"
    [ -e "$WORK/seen-issue-$n" ] && continue; : > "$WORK/seen-issue-$n"
    if [ "$code" = 0 ] && [ "$fixture" != - ]; then cp "$(fx "$fixture")" "$WORK/issue-$n"; else : > "$WORK/broken-$n"; fi
  elif [[ "$glob" =~ ^api\ --paginate\ repos/([^/]+/[^/]+)/issues/\*/comments$ ]]; then
    [ "${BASH_REMATCH[1]}" = "$SLUG" ] || continue
    [ "$code" = 0 ] && [ "$fixture" != - ] && [ ! -e "$WORK/comments-all" ] && cp "$(fx "$fixture")" "$WORK/comments-all"
  elif [[ "$glob" =~ ^api\ --paginate\ repos/([^/]+/[^/]+)/issues/([0-9]+)/comments$ ]]; then
    [ "${BASH_REMATCH[1]}" = "$SLUG" ] || continue
    n="${BASH_REMATCH[2]}"
    [ -e "$WORK/seen-comments-$n" ] && continue; : > "$WORK/seen-comments-$n"
    if [ "$code" = 0 ] && [ "$fixture" != - ]; then cp "$(fx "$fixture")" "$WORK/comments-$n"; else : > "$WORK/broken-$n"; fi
  elif [[ "$glob" =~ ^issue\ list\ --repo\ [^\ ]+\ --label\ fleet:([a-z_]+)\  ]]; then
    s="${BASH_REMATCH[1]}"
    [ -e "$WORK/seen-list-$s" ] && continue; : > "$WORK/seen-list-$s"
    if [ "$code" != 0 ] || [ "$fixture" = - ]; then : > "$WORK/list-broken"; continue; fi
    jq -r --arg s "$s" '.[] | "\(.number)\t\($s)\t\(.title)"' "$(fx "$fixture")" >> "$WORK/listed"
  elif [[ "$glob" =~ ^issue\ list\ --repo\ [^\ ]+\ --state\ (open|closed)\ --search ]]; then
    w="${BASH_REMATCH[1]}"
    if [ "$code" != 0 ] || [ "$fixture" = - ]; then : > "$WORK/list-broken"; continue; fi
    jq -r --arg w "$w" '.[] | "\(.number)\t\(if $w == "open" then "ready" else "done" end)\t\(.title)\t\(.closedAt // "")"' "$(fx "$fixture")" >> "$WORK/searched"
  elif [[ "$glob" =~ ^issue\ view\ ([0-9]+)\ --repo\ ([^\ ]+)\ --json\ state,stateReason ]]; then
    [ "${BASH_REMATCH[2]}" = "$SLUG" ] || continue
    [ "$code" = 0 ] && [ "$fixture" != - ] || continue
    printf '%s\t%s\n' "${BASH_REMATCH[1]}" \
      "$(jq -r 'if .state == "CLOSED" then (if .stateReason == "NOT_PLANNED" then "wont_do" else "done" end) else "backlog" end' "$(fx "$fixture")")" >> "$WORK/deps"
  fi
done < "$ROUTES"

write_card() { # <n> <json>
  printf '%s\n' "$2" > "$STORE/cards/$1.json"
}

for f in "$WORK"/issue-*; do
  [ -e "$f" ] || continue
  n="${f##*/issue-}"
  [ -e "$WORK/broken-$n" ] && continue
  if [ "${ROUTES_STORE_LISTED_ONLY:-}" = 1 ]; then
    s="$(jq -r '[.labels[]?.name | select(startswith("fleet:")) | ltrimstr("fleet:")] | .[0] // ""' "$f")"
    if [ -e "$WORK/seen-list-$s" ] \
       && ! awk -F'\t' -v s="$s" -v n="$n" '$2 == s && $1 == n { f = 1 } END { exit f ? 0 : 1 }' "$WORK/listed" 2>/dev/null; then
      continue
    fi
  fi
  c="$WORK/comments-$n"
  [ -e "$c" ] || { if [ -e "$WORK/comments-all" ]; then cp "$WORK/comments-all" "$c"; else printf '[]\n' > "$c"; fi; }
  ls_state="$( [ -f "$WORK/listed" ] && awk -F'\t' -v n="$n" '$1 == n { print $2; exit }' "$WORK/listed")"
  write_card "$n" "$(jq -c --slurpfile cs "$c" --arg ls "$ls_state" '
    ([.labels[]?.name | select(startswith("fleet:")) | ltrimstr("fleet:")] | .[0] // (if $ls == "" then null else $ls end)) as $s
    | ($cs[0] | if type == "array" then . else [] end) as $c
    | {number, title, body: (.body // ""), state: $s,
       labels: [.labels[]?.name | select(startswith("fleet:") | not)],
       next_comment_id: (($c | map(.id) | max // 0) + 1),
       comments: [$c[] | {id, author: .user.login, body, created_at: (.created_at // "2026-01-01T00:00:00Z")}],
       created_at: "2026-01-01T00:00:00Z"}' "$f")"
done
for f in "$WORK"/broken-*; do
  [ -e "$f" ] || continue
  n="${f##*/broken-}"
  s="$( [ -f "$WORK/listed" ] && awk -F'\t' -v n="$n" '$1 == n { print $2; exit }' "$WORK/listed")"
  jq -nc --argjson n "$n" --arg s "$s" \
    '{number: $n, title: "unreadable (a failed read in the routes fixture)", state: (if $s == "" then null else $s end),
      acceptance: [], blocked_by: [], pr_url: null, pr_url_source: null, comments: "unreadable"}' > "$STORE/cards/$n.json"
done
[ ! -e "$WORK/list-broken" ] || printf 'not a card (a failed listing in the routes fixture)\n' > "$STORE/cards/0.json"
if [ -f "$WORK/listed" ]; then
  while IFS=$'\t' read -r n s t; do
    [ -e "$STORE/cards/$n.json" ] && continue
    write_card "$n" "$(jq -nc --argjson n "$n" --arg s "$s" --arg t "$t" '{number: $n, title: $t, body: "", state: $s, labels: [], next_comment_id: 1, comments: [], created_at: "2026-01-01T00:00:00Z"}')"
  done < "$WORK/listed"
fi
if [ -f "$WORK/searched" ]; then
  while IFS=$'\t' read -r n s t u; do
    [ -e "$STORE/cards/$n.json" ] && continue
    write_card "$n" "$(jq -nc --argjson n "$n" --arg s "$s" --arg t "$t" --arg u "$u" '{number: $n, title: $t, body: "", state: $s, labels: [], next_comment_id: 1, comments: [], created_at: "2026-01-01T00:00:00Z"} + (if $u == "" then {} else {updated_at: $u} end)')"
  done < "$WORK/searched"
fi
if [ -f "$WORK/deps" ]; then
  while IFS=$'\t' read -r n s; do
    [ -e "$STORE/cards/$n.json" ] && continue
    write_card "$n" "$(jq -nc --argjson n "$n" --arg s "$s" '{number: $n, title: ("Dependency " + ($n | tostring)), body: "", state: $s, labels: [], next_comment_id: 1, comments: [], created_at: "2026-01-01T00:00:00Z"}')"
  done < "$WORK/deps"
fi
MAX="$(ls "$STORE/cards" | sed -n 's/^\([0-9][0-9]*\)\.json$/\1/p' | sort -n | tail -n 1)"
printf '%s\n' "$(( ${MAX:-0} + 1 ))" > "$STORE/next"
: > "$STORE/.from-routes" # built from the routes (store-sync.sh, store-calls.sh)
# Give the readable cards their fields; an unreadable one is set aside meanwhile.
mkdir -p "$WORK/aside"
for f in "$STORE"/cards/*.json; do
  [ -e "$f" ] || continue
  jq -e 'type == "object" and ((.comments // []) | type) == "array"' "$f" >/dev/null 2>&1 || mv "$f" "$WORK/aside/"
done
# the migration takes card locks under worktrees.dir; leave that as it was
WTD="$ROOT/$(jq -r '.worktrees.dir' <<<"$CFG")"
WTD_HAD=0; [ -e "$WTD" ] && WTD_HAD=1
LOCKS_HAD=0; [ -e "$WTD/.locks" ] && LOCKS_HAD=1
( cd "$ROOT" && FLEET_BOARD_USER="${LOGIN:-fleet-bot}" bash "$HERE/../scripts/migrate-card-fields.sh" >/dev/null 2>&1 ) \
  || { echo "routes-store: migrate-card-fields.sh failed in $ROOT" >&2; exit 1; }
[ "$LOCKS_HAD" = 1 ] || rmdir "$WTD/.locks" 2>/dev/null
[ "$WTD_HAD" = 1 ] || rmdir "$WTD" 2>/dev/null
for f in "$WORK"/aside/*.json; do [ -e "$f" ] && mv "$f" "$STORE/cards/"; done
printf '%s\n' "${LOGIN:-fleet-bot}"
