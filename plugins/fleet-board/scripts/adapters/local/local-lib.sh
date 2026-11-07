#!/usr/bin/env bash
# Store helpers for the local board backend. Source after board-lib.sh, once the
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
  cards="$(fl_cards_dir)"; mkdir -p "$cards" || fb_die 1 "cannot create $cards"
  tmp="$(mktemp "$cards/.tmp.XXXXXX")" || fb_die 1 "cannot write a temporary file in $cards"
  if ! cat "$2" > "$tmp"; then rm -f "$tmp"; fb_die 1 "cannot write card #$1"; fi
  mv -f "$tmp" "$(fl_card_file "$1")" || { rm -f "$tmp"; fb_die 1 "cannot write card #$1"; }
}

# fl_next_number: allocates and prints the next card number, under <dir>/.next.lock.
fl_next_number() {
  local d lock wait stale_min=5 waited=0 f n
  d="$(fl_dir)"; f="$d/next"; lock="$d/.next.lock"
  wait="${FLEET_BOARD_LOCK_WAIT:-30}"
  [ -f "$f" ] || fb_die 1 "no local board at $d; run /fleet-board:init"
  while ! mkdir "$lock" 2>/dev/null; do
    if [ -n "$(find "$lock" -maxdepth 0 -mmin +$stale_min 2>/dev/null)" ]; then
      rm -rf "$lock"; continue
    fi
    [ "$waited" -ge $((wait * 10)) ] && fb_die 1 "could not take lock $lock after ${wait}s"
    sleep 0.1; waited=$((waited + 1))
  done
  n="$(tr -d '[:space:]' < "$f" 2>/dev/null)"
  case "$n" in
    ''|*[!0-9]*|0|0[0-9]*) rm -rf "$lock"; fb_die 1 "$f is not a positive integer: '$n'" ;;
  esac
  if ! printf '%s\n' $((n + 1)) > "$f.tmp.$$" || ! mv -f "$f.tmp.$$" "$f"; then
    rm -f "$f.tmp.$$"; rm -rf "$lock"; fb_die 1 "cannot update $f"
  fi
  rm -rf "$lock"
  printf '%s\n' "$n"
}
