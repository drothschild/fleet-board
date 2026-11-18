#!/usr/bin/env bash
# Epic store helpers for the local card store. Source after local-lib.sh, once the
# config is loaded. An epic is <board.dir>/epics/<id>/epic.json, with design.md and
# log.jsonl beside it; <board.dir>/epics/next holds the next id. A store with no
# epics/ directory has no epics.

fl_epics_dir() { printf '%s/epics\n' "$(fl_dir)"; }
fl_epic_dir() { printf '%s/%s\n' "$(fl_epics_dir)" "$1"; }

# fl_epic_exists <id>: true only for a folder whose epic.json is an object with that id.
fl_epic_exists() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  jq -e --argjson n "$1" 'type == "object" and .id == $n' "$(fl_epic_dir "$1")/epic.json" >/dev/null 2>&1
}

# fl_next_epic_id: allocates and prints the next epic id under <epics dir>/.next.lock.
# The first call makes epics/ and epics/next.
fl_next_epic_id() {
  local d f lock n
  d="$(fl_epics_dir)"; f="$d/next"; lock="$d/.next.lock"
  mkdir -p "$d" || fb_die 1 "cannot create $d"
  fb_lock_acquire "$lock" "${FLEET_BOARD_LOCK_WAIT:-30}"
  if [ -f "$f" ]; then
    n="$(tr -d '[:space:]' < "$f" 2>/dev/null)"
    case "$n" in
      ''|*[!0-9]*|0|0[0-9]*) fb_lock_release "$lock"; fb_die 1 "$f is not a positive integer: '$n'" ;;
    esac
  else
    n=1
  fi
  # a stale counter skips past any folder that already exists
  while [ -e "$d/$n" ]; do n=$((n + 1)); done
  if ! mkdir "$d/$n" 2>/dev/null \
     || ! printf '%s\n' $((n + 1)) > "$f.tmp.$$" || ! mv -f "$f.tmp.$$" "$f"; then
    rm -f "$f.tmp.$$"; fb_lock_release "$lock"; fb_die 1 "cannot allocate an epic id in $d"
  fi
  fb_lock_release "$lock"
  printf '%s\n' "$n"
}

# fl_epic_lock <id>: takes <epics dir>/.<id>.lock and sets FB_EPIC_LOCK. The caller
# releases it in its EXIT trap: fb_lock_release "$FB_EPIC_LOCK".
fl_epic_lock() {
  local d; d="$(fl_epics_dir)"
  mkdir -p "$d" || fb_die 1 "cannot create $d"
  FB_EPIC_LOCK="$d/.$1.lock"
  fb_lock_acquire "$FB_EPIC_LOCK" "${FLEET_BOARD_LOCK_WAIT:-30}"
}

# fl_write_epic <id> <json-file>: atomic replace of the epic's epic.json.
fl_write_epic() {
  local dir tmp
  jq -e --argjson n "$1" 'type == "object" and .id == $n' "$2" >/dev/null 2>&1 \
    || fb_die 1 "refusing to write epic E$1: the new content is not a JSON object with id $1; the stored epic is unchanged"
  dir="$(fl_epic_dir "$1")"; mkdir -p "$dir" || fb_die 1 "cannot create $dir"
  tmp="$(mktemp "$dir/.tmp.XXXXXX")" || fb_die 1 "cannot write a temporary file in $dir"
  if ! cat "$2" > "$tmp"; then rm -f "$tmp"; fb_die 1 "cannot write epic E$1"; fi
  mv -f "$tmp" "$dir/epic.json" || { rm -f "$tmp"; fb_die 1 "cannot write epic E$1"; }
}
