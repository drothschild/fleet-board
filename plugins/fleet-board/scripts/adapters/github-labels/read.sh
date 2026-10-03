#!/usr/bin/env bash
set -uo pipefail
. "$FLEET_SCRIPTS/board-lib.sh"

ME="$(fb_login)" || exit 1

# Fetch issue and comments; fail closed if either fails
ISSUE="$(gh api "repos/$FLEET_REPO/issues/$1")" || fb_die 1 "cannot read card #$1"
RAW="$(gh api --paginate "repos/$FLEET_REPO/issues/$1/comments")" || fb_die 1 "cannot read comments for #$1"
COMMENTS="$(printf '%s' "$RAW" | jq -s 'add // []')"

# Compute canonical state: walk FB_STATES in order, take first match
STATE=null
MULTIPLE=0
for s in $FB_STATES; do
  name="$(fb_state_name "$s")"
  if echo "$ISSUE" | jq -e --arg n "$name" ".labels[] | select(.name == \$n)" >/dev/null 2>&1; then
    if [ "$STATE" = "null" ]; then
      STATE="$s"
    else
      MULTIPLE=1
    fi
  fi
done

if [ "$MULTIPLE" = 1 ]; then
  printf 'fleet-board: warning: card #%d carries several state labels\n' "$1" >&2
fi

# Build output with jq
jq -n \
  --argjson i "$ISSUE" \
  --argjson c "$COMMENTS" \
  --arg m "$FB_MARKER" \
  --arg s "$STATE" \
  --arg me "$ME" \
  '
  # Find the manager note: last comment whose body starts with marker AND author is me
  def find_note:
    [$c | .[] | select(.body | startswith($m)) | select(.user.login == $me)] | last;

  def note_data:
    if . then
      {id: .id, body: (.body | sub("^[^\n]*\n"; ""))}
    else
      {id: null, body: null}
    end;

  (find_note | note_data) as $note |
  {
    number: $i.number,
    title: $i.title,
    url: $i.html_url,
    state: ($s | if . == "null" then null else . end),
    body: $i.body,
    labels: [$i.labels[].name],
    manager_note: $note.body,
    manager_note_id: $note.id,
    comments: [$c[] | {id, author: .user.login, body, created_at}]
  }
  '
