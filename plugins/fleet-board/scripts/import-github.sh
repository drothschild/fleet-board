#!/usr/bin/env bash
# import-github.sh --repo OWNER/NAME [--project N [--owner LOGIN]] [--dry-run] [--force]
#
# Reads an existing GitHub board (read only) and writes it into this repo's
# local card store. Run from the target repo root; its .fleet-board.yml is the
# local board's config.
#
# Every gh call is a read: gh api user (the login whose manager notes count),
# gh issue list --state all (every issue, open and closed, with body and
# labels), gh api --paginate .../issues/<n>/comments (GET), and with --project
# gh project item-list. Nothing is written to GitHub.
#
# State: on a labels board, the issue's fleet:<state> label (or the name this
# config gives the state in board.states); with --project, the item's Status
# column, by the default column names (fb_default_name: Backlog, Ready,
# In Progress, In Review, Review: <stage>, Human QA, Blocked, Done, Won't Do,
# the names the removed Projects adapter used too) or the board.states name.
# An issue with no state label, or not on the project, is not a card and is
# skipped with a warning. An item whose column maps to no state stops the run.
#
# Each card keeps its issue number, title, created_at and updated_at, and its
# labels without the fleet:<state> labels. acceptance and blocked_by are split
# from the body (fl_split_body); a dependency on an issue that is not imported,
# or in another repo, stays in the body as prose with a warning. The manager
# note (the last marker comment by the gh login) is re-authored to the local
# login (FLEET_BOARD_USER, else $USER, else id -un), its accepted.login (if any)
# is rewritten to the local login too, and its "pr" sets pr_url (source "note").
# Trust: no other imported comment can carry the local login or the marker. Every
# other comment's author becomes "github:<login>" (so a GitHub user whose login
# equals the local login is not trusted), and a marker comment other than the
# chosen note gets "[imported] " put before its body so note.sh cannot match it.
# Comments get local ids 1..k in their GitHub order. next
# becomes one more than the highest card number (or stays, if higher).
# --repo must equal board.repo (case-insensitive): pr_url and "#n" refs are built
# against it. A mismatch exits 2.
#
# Refuses (exit 1) when the store already has a card, unless --force, which
# overwrites the imported numbers and leaves other cards, except a card that is
# in human_qa in the store: it is kept as it is, with a warning (nothing moves a
# card out of human_qa but a person). Reads and checks
# everything before writing anything. Prints one line per card; --dry-run
# prints the same lines and writes nothing.
# Exit: 0 imported; 1 a failed read, bad data, an existing store or a failed
# write; 2 usage.
set -uo pipefail
unset CDPATH
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/board-lib.sh"

USAGE="usage: import-github.sh --repo OWNER/NAME [--project N [--owner LOGIN]] [--dry-run] [--force]"
SRC="" PROJECT="" OWNER="" DRY=0 FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || fb_die 2 "$USAGE"; SRC="$2"; shift 2 ;;
    --project) [ $# -ge 2 ] || fb_die 2 "$USAGE"; PROJECT="$2"; shift 2 ;;
    --owner) [ $# -ge 2 ] || fb_die 2 "$USAGE"; OWNER="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --force) FORCE=1; shift ;;
    *) fb_die 2 "$USAGE" ;;
  esac
done
[ -n "$SRC" ] || fb_die 2 "$USAGE"
[[ "$SRC" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || fb_die 2 "--repo must be OWNER/NAME, got: $SRC"
[ -z "$OWNER" ] || [ -n "$PROJECT" ] || fb_die 2 "--owner needs --project"
[ -z "$PROJECT" ] || fb_valid_number "$PROJECT" || fb_die 2 "--project must be a number, got: $PROJECT"
[ -n "$OWNER" ] || OWNER="${SRC%%/*}"
[[ "$OWNER" =~ ^[A-Za-z0-9._-]+$ ]] || fb_die 2 "--owner must be a login, got: $OWNER"

fb_load_config
ME="$(fb_login)" || exit 1
BOARD_REPO="$(fb_cfg board.repo)"
if [ -n "$BOARD_REPO" ] && [ "$(printf '%s' "$SRC" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$BOARD_REPO" | tr '[:upper:]' '[:lower:]')" ]; then
  fb_die 2 "--repo $SRC is not this board's repo (board.repo is $BOARD_REPO); pr_url and issue refs are built against board.repo"
fi
. "$FLEET_SCRIPTS/adapters/local/local-lib.sh"
DIR="$(fl_dir)"
CARDS="$(fl_cards_dir)"

if [ "$FORCE" = 0 ] && [ -n "$(find "$CARDS" -maxdepth 1 -name '*.json' 2>/dev/null | head -n 1)" ]; then
  fb_die 1 "the local board at $DIR already has cards; pass --force to overwrite the imported numbers"
fi

WORK="$(mktemp -d)" || fb_die 1 "cannot create a temporary directory"
trap 'rm -rf "$WORK"' EXIT

# --- reads (all of them, before any write) ---------------------------------
GHLOGIN="$(gh api user </dev/null 2>/dev/null | jq -r '.login // empty' 2>/dev/null)"
[ -n "$GHLOGIN" ] || fb_die 1 "cannot determine the gh login (gh api user failed)"

LIMIT="$(fb_list_limit 1000)" || exit 1
gh issue list --repo "$SRC" --state all --limit "$LIMIT" \
  --json number,title,body,labels,state,createdAt,updatedAt </dev/null > "$WORK/issues.json" \
  || fb_die 1 "cannot list the issues of $SRC (gh issue list failed)"
COUNT="$(jq 'if type == "array" then length else error("not a list") end' "$WORK/issues.json" 2>/dev/null)" \
  || fb_die 1 "cannot parse the issue list of $SRC"
[ "$COUNT" -lt "$LIMIT" ] || fb_die 1 "gh issue list returned $COUNT issues, the list limit ($LIMIT); the list may be truncated. Set FLEET_BOARD_LIST_LIMIT above $LIMIT and retry"

# name -> state map: {"<board name>": "<canonical state>"}
NAMES="$(for s in $FB_STATES; do
  if [ -n "$PROJECT" ]; then printf '%s\t%s\n' "$(fb_default_name "$s")" "$s"; else printf 'fleet:%s\t%s\n' "$s" "$s"; fi
  o="$(fb_cfg "board.states.$s")"; [ -z "$o" ] || printf '%s\t%s\n' "$o" "$s"
done | jq -Rsc 'split("\n") | map(select(. != "") | split("\t") | {(.[0]): .[1]}) | add // {}')"

if [ -n "$PROJECT" ]; then
  gh project item-list "$PROJECT" --owner "$OWNER" --format json --limit "$LIMIT" </dev/null > "$WORK/items.json" \
    || fb_die 1 "cannot list the items of project $PROJECT (owner $OWNER)"
  N="$(jq '.items | length' "$WORK/items.json" 2>/dev/null)" || fb_die 1 "cannot parse the items of project $PROJECT"
  fb_valid_number "$N" || fb_die 1 "cannot parse the items of project $PROJECT"
  [ "$N" -lt "$LIMIT" ] || fb_die 1 "gh project item-list returned $N items, the list limit ($LIMIT); the list may be truncated. Set FLEET_BOARD_LIST_LIMIT above $LIMIT and retry"
  # {"<n>": "<Status>"} for this repo's issues on the project
  STATUS="$(jq -c --arg r "$SRC" '[.items[] | select(.content.type == "Issue" and ((.content.repository // "") | ascii_downcase) == ($r | ascii_downcase))
            | {key: (.content.number | tostring), value: (.status // "" | if . == "" then null else . end)}] | from_entries' "$WORK/items.json")" \
    || fb_die 1 "cannot parse the items of project $PROJECT"
  # every issue gets a state (or null: not on the project, or an item with no
  # Status, which the Projects board never listed); an unmapped column stops the run
  jq -c --argjson st "$STATUS" --argjson names "$NAMES" '
    map(. + {fb_status: ($st[.number | tostring])})
    | map(. + {fb_state: (if .fb_status == null then null else ($names[.fb_status] // ("?" + .fb_status)) end)})' \
    "$WORK/issues.json" > "$WORK/states.json" || fb_die 1 "cannot map the project columns"
else
  # first state in board order whose label the issue carries; several is a warning
  jq -c --argjson names "$NAMES" --arg order "$FB_STATES" '
    ($order | split(" ")) as $o
    | map(. as $i | [($i.labels // [])[] | .name | $names[.] // empty] as $hit
          | . + {fb_state: ([$o[] | select(. as $s | $hit | index($s))] | .[0]),
                 fb_several: ($hit | unique | length > 1)})' \
    "$WORK/issues.json" > "$WORK/states.json" || fb_die 1 "cannot read the labels of $SRC's issues"
fi

BAD="$(jq -r '.[] | select((.fb_state // "") | startswith("?")) | "#\(.number) (\(.fb_status))"' "$WORK/states.json")"
[ -z "$BAD" ] || fb_die 1 "project columns that name no state in this config: $(printf '%s' "$BAD" | tr '\n' ' ')- add them to board.states or review.stages"
jq -r '.[] | select(.fb_state == null) | .number' "$WORK/states.json" | while IFS= read -r n; do
  printf 'fleet-board: warning: #%s is not on the board; not imported\n' "$n" >&2
done
jq -r '.[] | select(.fb_several == true) | .number' "$WORK/states.json" | while IFS= read -r n; do
  printf 'fleet-board: warning: #%s carries several state labels; the first in board order wins\n' "$n" >&2
done

jq -c '[.[] | select(.fb_state != null)] | sort_by(.number)' "$WORK/states.json" > "$WORK/board.json"
IMPORTED="$(jq -c '[.[].number]' "$WORK/board.json")"

# comments, one read per imported issue
for n in $(jq -r '.[].number' "$WORK/board.json"); do
  gh api --paginate "repos/$SRC/issues/$n/comments" </dev/null > "$WORK/c-$n.raw" \
    || fb_die 1 "cannot read the comments of #$n (gh api failed)"
  jq -sc 'add // [] | if type == "array" then . else error("not a list") end' "$WORK/c-$n.raw" > "$WORK/c-$n.json" 2>/dev/null \
    || fb_die 1 "cannot parse the comments of #$n"
done

# --- build every card in WORK, then write ----------------------------------
NOW="$(fl_now)"
for n in $(jq -r '.[].number' "$WORK/board.json"); do
  ISSUE="$(jq -c --argjson n "$n" '.[] | select(.number == $n)' "$WORK/board.json")"
  jq -j '.body // ""' <<<"$ISSUE" > "$WORK/body-$n"
  SPLIT="$(fl_split_body "$WORK/body-$n" "$SRC")" || fb_die 1 "cannot split the body of #$n"
  # a blocker must be a card this import writes (or one already in the store), never the card itself
  SPLIT="$(jq -c --argjson self "$n" --argjson imp "$IMPORTED" --arg dir "$CARDS" '
    .blocked_by as $b
    | .outside += [$b[] | . as $x | select($x == $self or ($imp | index($x) | not)) | "#" + tostring]
    | .blocked_by = [$b[] | . as $x | select($x != $self and ($imp | index($x)))]' <<<"$SPLIT")"
  # keep a blocker that already exists in the store (a --force import onto an existing board)
  for o in $(jq -r '.outside[] | select(test("^#[0-9]+$")) | .[1:]' <<<"$SPLIT"); do
    if [ "$o" != "$n" ] && [ -f "$(fl_card_file "$o")" ]; then
      SPLIT="$(jq -c --argjson o "$o" '.outside -= ["#" + ($o | tostring)] | .blocked_by += [$o]' <<<"$SPLIT")"
    fi
  done
  fl_fold_outside "$SPLIT" "#$n" > "$WORK/fold-$n" || exit 1
  # the trusted note: the last marker comment by the gh login
  NOTEIDX="$(jq --arg m "$FB_MARKER" --arg me "$GHLOGIN" \
    '[to_entries[] | select((.value.body // "") | startswith($m)) | select(.value.user.login == $me) | .key] | last // -1' "$WORK/c-$n.json")"
  PRINFO='{"ok":false}'
  if [ "$NOTEIDX" != -1 ]; then
    jq -j --argjson i "$NOTEIDX" '.[$i].body' "$WORK/c-$n.json" > "$WORK/note-$n"
    PRINFO="$(fl_note_pr_info "$WORK/note-$n")" || PRINFO='{"ok":false}'
  fi
  jq -n --argjson i "$ISSUE" --slurpfile cs "$WORK/c-$n.json" --rawfile b "$WORK/fold-$n" \
    --argjson sp "$SPLIT" --argjson ni "$NOTEIDX" --argjson pi "$PRINFO" \
    --arg me "$ME" --arg now "$NOW" --arg src "$SRC" --argjson names "$NAMES" --arg proj "$PROJECT" --arg m "$FB_MARKER" '
    # the note body with accepted.login rewritten from the gh login to the local login
    def fixnote:
      split("\n") as $l
      | ([$l | to_entries[] | select(.value | test("^```json")) | .key] | first) as $s
      | if $s == null then .
        else ([$l | to_entries[] | select(.key > $s and (.value | test("^```"))) | .key] | first) as $e
          | if $e == null then .
            else (($l[$s + 1:$e] | join("\n") | try fromjson catch null) as $j
              | if ($j | type) == "object" and (($j.accepted | type) == "object")
                then ($l[0:$s + 1] + [($j | .accepted.login = $me | tojson)] + $l[$e:]) | join("\n")
                else . end)
            end
        end;
    $cs[0] as $c
    | (if $pi.ok and $pi.has and $pi.pr != null then "https://github.com/" + $src + "/pull/" + ($pi.pr | tostring) else null end) as $pr
    | {
        number: $i.number,
        title: ($i.title // ""),
        body: $b,
        acceptance: $sp.acceptance,
        blocked_by: $sp.blocked_by,
        pr_url: $pr,
        pr_url_source: (if $pr == null then null else "note" end),
        state: $i.fb_state,
        labels: [($i.labels // [])[] | .name | select(if $proj == "" then ($names[.] == null) else true end)],
        next_comment_id: (($c | length) + 1),
        comments: [range(0; $c | length) as $k | $c[$k]
                   | {id: ($k + 1),
                      author: (if $k == $ni then $me else "github:" + (.user.login // "unknown") end),
                      body: ((.body // "") | if $k == $ni then fixnote
                                             elif startswith($m) then "[imported] " + . else . end),
                      created_at: (.created_at // $now)}],
        created_at: ($i.createdAt // $now),
        updated_at: ($i.updatedAt // $i.createdAt // $now)
      }' > "$WORK/card-$n.json" || fb_die 1 "cannot build card #$n"
done

for n in $(jq -r '.[].number' "$WORK/board.json"); do
  if [ "$FORCE" = 1 ] && [ -f "$(fl_card_file "$n")" ] && [ "$(jq -r '.state // ""' "$(fl_card_file "$n")" 2>/dev/null)" = human_qa ]; then
    printf 'fleet-board: warning: #%s is in human_qa in the store; --force keeps it as it is\n' "$n" >&2
    printf 'kept #%s human_qa (not overwritten)\n' "$n"
    continue
  fi
  if [ "$DRY" = 0 ]; then
    mkdir -p "$CARDS" || fb_die 1 "cannot create $CARDS"
    fb_lock "$n"
    trap 'rm -rf "$WORK" "$FB_LOCK"' EXIT
    fl_write_card "$n" "$WORK/card-$n.json" || exit 1
    rm -rf "$FB_LOCK"
  fi
  jq -r --arg m "$FB_MARKER" --arg me "$ME" '"imported #\(.number) \(.state) \(.comments | length) comments"
         + (if any(.comments[]; .author == $me and (.body | startswith($m))) then ", manager note" else "" end)
         + ": \(.title)"' "$WORK/card-$n.json"
done
trap 'rm -rf "$WORK"' EXIT
FB_LOCK=""

[ "$DRY" = 0 ] || exit 0
MAX="$(for c in "$CARDS"/*.json; do [ -e "$c" ] && basename "$c" .json; done | grep -E '^[0-9]+$' | sort -n | tail -n 1)"
[ -n "$MAX" ] || MAX=0
# under the lock fl_next_number takes, re-reading next inside it
fl_lock_next || exit 1
OLD=""
[ -f "$DIR/next" ] && OLD="$(tr -d '[:space:]' < "$DIR/next" 2>/dev/null)"
NEXT=$((MAX + 1))
case "$OLD" in ''|*[!0-9]*) ;; *) [ "$OLD" -gt "$NEXT" ] && NEXT="$OLD" ;; esac
if ! printf '%s\n' "$NEXT" > "$DIR/next.tmp.$$" || ! mv -f "$DIR/next.tmp.$$" "$DIR/next"; then
  rm -f "$DIR/next.tmp.$$"; fl_unlock_next; fb_die 1 "cannot write $DIR/next"
fi
fl_unlock_next
