#!/usr/bin/env bash
#
# Test helper (not a suite), sourced: store_snap / store_calls [repo-root]
#
# For the suites written against the removed GitHub board, whose assertions
# read the fake gh's record of issue writes (argv/<seq>, calls.log, bodies/).
# store_snap copies the local card files before a run; store_calls, after the
# run, records each change the run made to the store as the gh call the
# GitHub board made for it, in the same files the fake gh writes:
#
#   a new card     issue create --repo <board.repo> --title <title>
#                  --body-file <file> --label fleet:<state> [--label <label>]...
#                  (bodies/ gets the body board-read.sh returns for the card,
#                  with its acceptance and blocked_by rendered as sections)
#   a label        issue edit <n> --repo <board.repo> --add-label <label>
#                  (or --remove-label), one call per label added or removed
#                  on an existing card
#   a move         issue edit <n> --repo <board.repo> --add-label fleet:<new>, then
#                  issue edit <n> --repo <board.repo> --remove-label fleet:<old>
#   a new comment  issue comment <n> --repo <board.repo> --body <text>
#                  (bodies/ gets the text of a comment on an existing card,
#                  as the board adapter's --body-file was saved; a comment on
#                  a card the run created is recorded without it)
#                  on a card, after its create when the card is new (a manager
#                  note is not a comment here)
#   any other edit issue edit <n> --repo <board.repo> --body-file -, when an
#                  existing card's file changed and none of the records above
#                  covers it (title, body, acceptance, blocked_by, pr_url, ...),
#                  so a "no write" check still sees the write
#   a note write   api -X PATCH repos/<board.repo>/issues/comments/<id> --input -,
#                  and inputs/ gets {"body": <the note comment>}, as the fake
#                  gh saved the --input - of the note's POST or PATCH
#
# The records come after the run's real gh calls (PR comments), in card
# number order. Nothing is recorded for a run that changed no card, or for a
# store the suite seeded itself (not built by store_sync).

store_snap() {
  local root="${1:-${REPO:-}}"
  rm -rf "$FAKE_GH_DIR/store-snap"; mkdir -p "$FAKE_GH_DIR/store-snap"
  [ -d "$root/.fleet-board/cards" ] && cp "$root/.fleet-board/cards/"*.json "$FAKE_GH_DIR/store-snap/" 2>/dev/null
  return 0
}

# store_record <arg>...: one fake gh call, recorded as fake-gh.sh records one
store_record() {
  local seq=0 f
  [ -f "$FAKE_GH_DIR/count" ] && seq="$(cat "$FAKE_GH_DIR/count")"
  seq=$((seq + 1)); printf '%d\n' "$seq" > "$FAKE_GH_DIR/count"
  mkdir -p "$FAKE_GH_DIR/argv"
  f="$FAKE_GH_DIR/argv/$(printf '%010d' "$seq")"
  for a in "$@"; do printf '%s\n' "$a" >> "$f"; done
  printf '%s\t%s\n' "store" "$*" >> "$FAKE_GH_DIR/calls.log"
}

store_calls() {
  local root="${1:-${REPO:-}}" f n old repo marker='<!-- fleet-board:manager-note -->' b args os ns new before
  [ -d "$root/.fleet-board/cards" ] || return 0
  [ -e "$root/.fleet-board/.from-routes" ] || return 0 # a store the suite seeded itself
  repo="$(sed -n 's/^  repo: *//p' "$root/.fleet-board.yml" | head -n 1 | tr -d '"')"
  for f in $(ls "$root/.fleet-board/cards/"*.json 2>/dev/null | sed 's|.*/||; s|\.json$||' | sort -n); do
    n="$f"; f="$root/.fleet-board/cards/$n.json"; old="$FAKE_GH_DIR/store-snap/$n.json"; new=0
    jq -e 'type == "object"' "$f" >/dev/null 2>&1 || continue
    if [ ! -e "$old" ]; then
      mkdir -p "$FAKE_GH_DIR/bodies"
      b="$FAKE_GH_DIR/bodies/store-$n"
      (cd "$root" && bash "$STORE_SYNC_HERE/../scripts/board-read.sh" "$n" 2>/dev/null) | jq -j '.body // ""' > "$b"
      args=(issue create --repo "$repo" --title "$(jq -r .title "$f")" --body-file "$b" --label "fleet:$(jq -r .state "$f")")
      while IFS= read -r l; do [ -n "$l" ] && args+=(--label "$l"); done < <(jq -r '(.labels // [])[]' "$f")
      store_record "${args[@]}"
      new=1
      printf '{"comments":[]}\n' > "$FAKE_GH_DIR/store-snap/$n.json" # its comments follow, as on an existing card
      old="$FAKE_GH_DIR/store-snap/$n.json"
    fi
    cmp -s "$f" "$old" && continue # (a new card's snapshot never matches)
    before="$(cat "$FAKE_GH_DIR/count" 2>/dev/null || echo 0)"
    os="$(jq -r '.state // ""' "$old")"; ns="$(jq -r '.state // ""' "$f")"
    if [ -n "$os" ] && [ "$os" != "$ns" ]; then
      store_record issue edit "$n" --repo "$repo" --add-label "fleet:$ns"
      store_record issue edit "$n" --repo "$repo" --remove-label "fleet:$os"
    fi
    if jq -e '.labels' "$old" >/dev/null 2>&1; then
      while IFS=$'\t' read -r op l; do
        [ -n "$l" ] && store_record issue edit "$n" --repo "$repo" "$op" "$l"
      done < <(jq -r --slurpfile o "$old" '
        (.labels // []) as $now | ($o[0].labels // []) as $was
        | ([$now[] | select(. as $x | $was | index($x) | not) | "--add-label\t" + .]
           + [$was[] | select(. as $x | $now | index($x) | not) | "--remove-label\t" + .])[]' "$f")
    fi
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      if [ "$new" = 0 ]; then
        mkdir -p "$FAKE_GH_DIR/bodies"
        jq -j .body <<<"$c" > "$FAKE_GH_DIR/bodies/store-$n-$(jq -r .id <<<"$c")"
      fi
      store_record issue comment "$n" --repo "$repo" --body "$(jq -r .body <<<"$c")"
    done < <(jq -c --slurpfile o "$old" --arg m "$marker" '
      ($o[0].comments // [] | map(.id)) as $had
      | (.comments // [])[] | select((.id as $i | $had | index($i)) | not) | select(.body | startswith($m) | not)' "$f")
    # the manager note, when the run wrote it (by the trusted login)
    b="$(jq -c --slurpfile o "$old" --arg m "$marker" --arg me "${FLEET_BOARD_USER:-}" '
      def note: [(.comments // [])[] | select(.body | startswith($m)) | select(.author == $me)] | last;
      (note) as $now | ($o[0] | note) as $was
      | if $now != null and ($now.body != ($was.body // null)) then {id: $now.id, body: $now.body} else empty end' "$f")"
    if [ -n "$b" ]; then
      store_record api -X PATCH "repos/$repo/issues/comments/$(jq -r .id <<<"$b")" --input -
      b="$(jq -c '{body}' <<<"$b")"
      mkdir -p "$FAKE_GH_DIR/inputs"
      printf '%s\n' "$b" > "$FAKE_GH_DIR/inputs/store-$n-$(date +%s)-$RANDOM"
    fi
    if [ "$new" = 0 ] && [ "$(cat "$FAKE_GH_DIR/count" 2>/dev/null || echo 0)" = "$before" ]; then
      store_record issue edit "$n" --repo "$repo" --body-file -
    fi
  done
}
