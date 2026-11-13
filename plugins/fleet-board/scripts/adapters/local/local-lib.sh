#!/usr/bin/env bash
# Store helpers for the local card store. Source after board-lib.sh, once the
# config is loaded (FLEET_ROOT and FLEET_CFG set).

fl_dir() { printf '%s/%s\n' "$FLEET_ROOT" "$(fb_cfg board.dir)"; }
fl_cards_dir() { printf '%s/cards\n' "$(fl_dir)"; }
fl_active_dir() { printf '%s/active\n' "$(fl_dir)"; }
fl_card_file() { printf '%s/%s.json\n' "$(fl_cards_dir)" "$1"; }
fl_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
fl_url() { printf 'http://127.0.0.1:%s/cards/%s\n' "${FLEET_BOARD_PORT:-$(fb_cfg board.port)}" "$1"; }

fl_require_store() {
  local d; d="$(fl_dir)"
  [ -f "$d/next" ] || fb_die 1 "no local board at $d; run /fleet-board:init"
}

# fl_read_card <n>: prints the card JSON.
fl_read_card() {
  local f; f="$(fl_card_file "$1")"
  [ -f "$f" ] || fb_die 1 "card #$1 not found in $(fl_cards_dir)"
  jq -e 'type == "object"' "$f" >/dev/null 2>&1 || fb_die 1 "card #$1 is not valid JSON: $f"
  cat "$f"
}

# fl_next_comment_id <card-json>: prints the id the card's next comment gets:
# its next_comment_id, else one more than the highest numeric comment id.
fl_next_comment_id() {
  jq -r '.next_comment_id // (([(.comments // [])[] | .id | numbers] | max // 0) + 1)' <<<"$1"
}

# fl_find_title <title> open|closed [days]: the local stand-in for a GitHub
# title search. Prints the lowest-numbered card whose title equals <title>
# case-insensitively, or "none". "open" is any state but done and wont_do;
# "closed" is done or wont_do with updated_at (else created_at) within <days>
# (default 30).
# Fails closed (exit 1, printing nothing) when the store is missing or any card
# file is not a JSON object.
fl_find_title() {
  local cards
  fl_require_store
  cards="$(fl_cards_dir)"
  set -- "$1" "$2" "${3:-30}" "$cards"/*.json
  if [ ! -e "$4" ]; then echo none; return 0; fi
  local t="$1" which="$2" days="$3"
  shift 3
  jq -rs --arg t "$t" --arg w "$which" --argjson d "$days" '
    if all(.[]; type == "object") then . else error("not a card") end
    | [.[] | select((.title | type) == "string" and (.title | ascii_downcase) == ($t | ascii_downcase))
           | (.state == "done" or .state == "wont_do") as $closed
           | select(if $w == "open" then ($closed | not)
                    else (.updated_at // .created_at) as $u
                         | $closed and ($u | type) == "string"
                           and (($u | fromdateiso8601) >= (now - $d * 86400)) end)]
    | sort_by(.number) | .[0].number // "none"' "$@" 2>/dev/null \
    || fb_die 1 "cannot search the cards in $cards: a card file is not valid JSON"
}

# fl_write_card <n> <json-file>: atomic replace of the card file.
fl_write_card() {
  local cards tmp
  jq -e --argjson n "$1" 'type == "object" and .number == $n' "$2" >/dev/null 2>&1 \
    || fb_die 1 "refusing to write card #$1: the new content is not a JSON object with number $1; the stored card is unchanged"
  cards="$(fl_cards_dir)"; mkdir -p "$cards" || fb_die 1 "cannot create $cards"
  tmp="$(mktemp "$cards/.tmp.XXXXXX")" || fb_die 1 "cannot write a temporary file in $cards"
  if ! cat "$2" > "$tmp"; then rm -f "$tmp"; fb_die 1 "cannot write card #$1"; fi
  mv -f "$tmp" "$(fl_card_file "$1")" || { rm -f "$tmp"; fb_die 1 "cannot write card #$1"; }
}

# fl_lock_next / fl_unlock_next: <dir>/.next.lock, the lock every writer of
# <dir>/next takes (a lock whose owner process is gone, or that has had no owner
# pid for longer than the pid-less grace, is stale and removed).
fl_lock_next() {
  local d
  d="$(fl_dir)"
  mkdir -p "$d" || fb_die 1 "cannot create $d"
  fb_lock_acquire "$d/.next.lock" "${FLEET_BOARD_LOCK_WAIT:-30}"
}
fl_unlock_next() { fb_lock_release "$(fl_dir)/.next.lock"; }

# fl_next_number: allocates and prints the next card number, under <dir>/.next.lock.
fl_next_number() {
  local d lock f n
  d="$(fl_dir)"; f="$d/next"; lock="$d/.next.lock"
  [ -f "$f" ] || fb_die 1 "no local board at $d; run /fleet-board:init"
  fl_lock_next
  n="$(tr -d '[:space:]' < "$f" 2>/dev/null)"
  case "$n" in
    ''|*[!0-9]*|0|0[0-9]*) fb_lock_release "$lock"; fb_die 1 "$f is not a positive integer: '$n'" ;;
  esac
  # Belt and braces: the lock alone is not trusted (a stale-lock takeover can let
  # two holders in). A number is only issued once mkdir of its claim succeeds, and
  # never when its card file already exists, so a stale counter skips ahead.
  mkdir -p "$d/.claims" || { rm -rf "$lock"; fb_die 1 "cannot create $d/.claims"; }
  while [ -e "$(fl_card_file "$n")" ] || ! mkdir "$d/.claims/$n" 2>/dev/null; do n=$((n + 1)); done
  if ! printf '%s\n' $((n + 1)) > "$f.tmp.$$" || ! mv -f "$f.tmp.$$" "$f"; then
    rm -f "$f.tmp.$$"; fb_lock_release "$lock"; fb_die 1 "cannot update $f"
  fi
  fb_lock_release "$lock"
  printf '%s\n' "$n"
}

# fl_split_body <body-file> [repo]: prints {"body","acceptance","blocked_by","outside"}.
# Removes the FIRST "## Acceptance" and the FIRST "## Depends on" section that
# sit outside code fences (a section runs to the next heading); a repeat of
# either heading, or one inside a fence, stays in the body as prose. Bullets
# lose their "- " and are trimmed; "#n" and "<repo>#n" (repo defaults to board.repo) become numbers in
# blocked_by, any other dependency entry goes to outside, except an entry that
# starts with "#n" or "<repo>#n" and has more text after it: that goes to bad. A body with neither
# section comes back byte for byte.
fl_split_body() {
  jq -n --rawfile b "$1" --arg repo "${2:-$(fb_cfg board.repo)}" '
    def trim: sub("^[ \t]+"; "") | sub("[ \t\r]+$"; "");
    def isbullet: test("^[ \t]*[-*][ \t]+");
    def clean: sub("^[ \t]*[-*][ \t]+"; "") | trim;
    def cont($l): if (.acc | length) == 0 then .body += [$l] else .acc[-1] += "\n" + ($l | trim) end;
    def inside($l):
      if .sec == "acc" then cont($l)
      elif .sec == "dep" then .dep += [$l | trim]
      else .body += [$l] end;
    def ref:
      if test("^#[0-9]+$") then {n: (.[1:] | tonumber)}
      elif test("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+#[0-9]+$")
           and ((split("#")[0] | ascii_downcase) == ($repo | ascii_downcase))
        then {n: (split("#")[1] | tonumber)}
      else {o: .} end;
    def badref:
      (test("^#[0-9]+[^0-9]") and (test("^#[0-9]+$") | not))
      or (test("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+#[0-9]+[^0-9]")
          and ((split("#")[0] | ascii_downcase) == ($repo | ascii_downcase)));
    ($b | split("\n")) as $lines
    | reduce $lines[] as $l ({fence: false, sec: null, sa: false, sd: false, hit: false, body: [], acc: [], dep: []};
        if ($l | test("^[ ]{0,3}(```|~~~)")) then
          .fence = (.fence | not) | inside($l)
        elif .fence then inside($l)
        elif ($l | test("^#{1,6}([ \t]|$)")) then
          if ($l | test("^##[ \t]+Acceptance([ \t].*)?$")) and (.sa | not) then .sec = "acc" | .sa = true | .hit = true
          elif ($l | test("^##[ \t]+depends[ \t]+on[ \t]*$"; "i")) and (.sd | not) then .sec = "dep" | .sd = true | .hit = true
          else .sec = null | .body += [$l] end
        elif .sec == null then .body += [$l]
        elif ($l | test("^[ \t\r]*$")) then .
        elif .sec == "acc" then (if ($l | isbullet) then .acc += [$l | clean] else cont($l) end)
        else .dep += [$l | clean] end)
    | . as $s
    | ($s.dep | map(select(. != "") | ref)) as $refs
    | {body: (if $s.hit then ($s.body | join("\n") | sub("\n+$"; "") | if . == "" then "" else . + "\n" end) else $b end),
       acceptance: ($s.acc | map(select(. != ""))),
       blocked_by: ([$refs[] | select(.n != null) | .n] | reduce .[] as $x ([]; if index($x) then . else . + [$x] end)),
       outside: [$refs[] | select(.o != null) | .o],
       bad: [$s.dep[] | select(. != "" and badref)]}'
}

# fl_check_bad_deps <split-json>: exits 2 naming every dependency entry that
# starts with a reference of this board but carries more text after it.
fl_check_bad_deps() {
  local bad
  bad="$(jq -r '.bad[]' <<<"$1")"
  [ -z "$bad" ] && return 0
  while IFS= read -r l; do printf 'bad dependency line: %s\n' "$l" >&2; done <<<"$bad"
  exit 2
}

# fl_acceptance_json <file>: the bullets (a leading "- " or "* " is optional)
# of an acceptance file as a JSON array of trimmed, non-empty strings.
fl_acceptance_json() {
  jq -Rs 'split("\n") | map(sub("^[ \t]*[-*][ \t]+"; "") | sub("^[ \t]+"; "") | sub("[ \t\r]+$"; "")) | map(select(. != ""))' < "$1"
}

# fl_uniq_json: stdin JSON array -> the array without repeats, order kept.
fl_uniq_json() { jq -c 'reduce .[] as $x ([]; if index($x) then . else . + [$x] end)'; }

# fl_fold_outside <split-json> <card-n-for-message>: prints the split body with
# each outside dependency kept as a prose line (so nothing is lost), and warns.
fl_fold_outside() {
  jq -r '.outside[]' <<<"$1" | while IFS= read -r r; do
    printf 'fleet-board: warning: card %s: dependency %s is outside this board; kept in the body as prose\n' "$2" "$r" >&2
  done
  jq -j '.body as $b | if (.outside | length) == 0 then $b
    else ($b | sub("\n+$"; "")) + (if $b == "" then "" else "\n\n" end) + (.outside | map("Depends on (outside this board): " + .) | join("\n")) + "\n" end' <<<"$1"
}

# fl_note_pr_info <note-body-file>: reads the note's fenced json block and
# prints {"ok": false} when it has none or its "pr" is not a positive integer
# or null, else {"ok": true, "has": <key present>, "pr": <value>}.
fl_note_pr_info() {
  jq -Rsc '
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
    end' < "$1"
}

# fl_check_blocked_by <self-number|""> <json>: exit 2 unless <json> is an array
# of positive integers naming cards that exist in the store, none of them the
# card itself.
fl_check_blocked_by() {
  local self="$1" b
  jq -e 'type == "array" and all(.[]; type == "number" and . == floor and . > 0)' <<<"$2" >/dev/null 2>&1 \
    || fb_die 2 "blocked_by must be a JSON array of positive integers, got: $2"
  for b in $(jq -r '.[]' <<<"$2"); do
    [ "$b" != "$self" ] || fb_die 2 "blocked_by names #$b, the card itself"
    [ -f "$(fl_card_file "$b")" ] || fb_die 2 "blocked_by names #$b, which does not exist in $(fl_cards_dir)"
  done
}

# fl_add_qa_section <body-string>:
# prints the body with an empty "## Human QA" section appended when it has no
# such heading outside a code fence; an existing section leaves it byte for byte.
fl_add_qa_section() {
  jq -nj --arg b "$1" '
    def badref:
      (test("^#[0-9]+[^0-9]") and (test("^#[0-9]+$") | not))
      or (test("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+#[0-9]+[^0-9]")
          and ((split("#")[0] | ascii_downcase) == ($repo | ascii_downcase)));
    ($b | split("\n")) as $lines
    | (reduce $lines[] as $l ({fence: false, has: false};
        if ($l | test("^[ ]{0,3}(```|~~~)")) then .fence = (.fence | not)
        elif .fence then .
        elif ($l | test("^##[ \t]+Human[ \t]+QA[ \t]*$"; "i")) then .has = true
        else . end)).has as $has
    | if $has then $b
      else ($b | sub("\n+$"; "")) as $t
        | (if $t == "" then "" else $t + "\n\n" end) + "## Human QA\n" end'
}
