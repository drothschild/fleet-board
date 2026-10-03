#!/usr/bin/env bash
# board-lib.sh - Shared board adapter library
#
# Sourced by contract scripts; provides common functions and variables.
# Exports: FLEET_CFG, FLEET_ROOT, FLEET_REPO, FLEET_SCRIPTS (set by fb_load_config)
# FB_LOCK is set by fb_lock and used with trap EXIT to clean up

FB_STATES="backlog ready in_progress in_review human_qa blocked done wont_do"
FB_MARKER='<!-- fleet-board:manager-note -->'
# With CDPATH exported, a relative cd can land in a CDPATH directory and echo
# its path, which $(cd ... && pwd) would capture as a second line. Each entry
# script unsets it too, before its own cd; this covers anything that sources
# the library by a relative path.
unset CDPATH
FB_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fb_die() { printf 'fleet-board: %s\n' "$2" >&2; exit "$1"; }

fb_load_config() {
  # Sets and exports FLEET_CFG FLEET_ROOT FLEET_REPO FLEET_SCRIPTS
  FLEET_CFG="$(bash "$FB_SCRIPTS/config.sh")"; local rc=$?
  [ $rc -eq 0 ] || exit $rc
  local common; common="$(fb_git_common_dir .)"
  if [ -n "$common" ]; then FLEET_ROOT="$(dirname "$common")"; else FLEET_ROOT="$(pwd)"; fi
  FLEET_REPO="$(jq -r .board.repo <<<"$FLEET_CFG")"
  FLEET_SCRIPTS="$FB_SCRIPTS"
  export FLEET_CFG FLEET_ROOT FLEET_REPO FLEET_SCRIPTS
}

# fb_git_common_dir <dir>: prints the absolute path of the git common dir of
# the repository <dir> is in; fails (printing nothing) outside a repository.
# git 2.31 and later print it with rev-parse --path-format=absolute. Older git
# rejects that flag or echoes it back and prints the dir relative to <dir>, so
# anything but one absolute line falls back to resolving the relative answer.
fb_git_common_dir() {
  local d="$1" out rel
  out="$(git -C "$d" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  case "$out" in
    *$'\n'*) ;;
    /*) printf '%s\n' "$out"; return 0 ;;
  esac
  rel="$(git -C "$d" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$rel" in ''|*$'\n'*) return 1 ;; esac
  (cd "$d" && cd "$rel" && pwd -P)
}

# Prints scalars raw (booleans print as true/false), objects/arrays as JSON, and nothing for null.
fb_cfg() { jq -r --arg p "$1" 'getpath($p | split(".")) | if . == null then empty elif type == "object" or type == "array" then tojson else . end' <<<"$FLEET_CFG"; }

# Prints the authenticated gh login; exits 1 if it cannot be determined
fb_login() {
  local l; l="$(gh api user 2>/dev/null | jq -r '.login // empty' 2>/dev/null)"
  [ -n "$l" ] && [ "$l" != "null" ] || fb_die 1 "cannot determine the authenticated gh login (gh api user failed)"
  printf '%s\n' "$l"
}

# fb_token_scopes <gh auth status output>: prints the "Token scopes:" line of
# github.com's ACTIVE account, or nothing when gh shows none for it (a
# GH_TOKEN token, a failed login, or no github.com login). The adapters and
# init talk to github.com only, so another host's accounts never count.
# gh groups accounts under a host header line (the host name, unindented), and
# prints one block per account, starting at a "Logged in to <host>" /
# "Failed to log in to <host>" line, with an "Active account:" line inside it.
# The github.com block with "Active account: true" is picked wherever it sits
# in the listing (gh lists the active account first, but this does not rely on
# it). Output without any "Active account:" line (gh before multi-account
# support) has one account per host, so github.com's first scopes line is used.
# That older output lists the scopes unquoted; test them with fb_has_scope,
# which accepts either form.
fb_token_scopes() {
  printf '%s\n' "$1" | awk -v want=github.com '
    function flush() {
      if (scopes != "" && host == want) {
        if (active == "true" && pick == "") pick = scopes
        if (first == "") first = scopes
      }
      scopes = ""; active = ""
    }
    /^[^[:space:]]/ { flush(); host = $1; next }
    /Logged in to|[Ll]og in to/ {
      flush()
      for (i = 1; i < NF - 1; i++) if ($i == "in" && $(i + 1) == "to") { host = $(i + 2); break }
    }
    /Active account: true/ { active = "true"; marked = 1 }
    /Active account: false/ { active = "false"; marked = 1 }
    /Token scopes:/ { scopes = $0 }
    END {
      flush()
      if (pick != "") print pick
      else if (!marked && first != "") print first
    }'
}

# fb_has_scope <scopes line> <name>: succeeds when <name> is one of the
# comma-separated scopes on a "Token scopes:" line. Current gh quotes each
# scope ('repo', 'project'); older gh prints them bare (repo, project). Each
# item is compared whole, so read:project is not project.
fb_has_scope() {
  printf '%s\n' "$1" | awk -v want="$2" -v q="'" '
    {
      sub(/.*Token scopes:/, "")
      n = split($0, item, ",")
      for (i = 1; i <= n; i++) {
        s = item[i]
        gsub(/[[:space:]"]/, "", s)
        gsub(q, "", s)
        if (s == want) found = 1
      }
    }
    END { exit found ? 0 : 1 }'
}

fb_valid_state() { case " $FB_STATES " in *" $1 "*) return 0 ;; esac; return 1; }

fb_default_name() {
  # Backend-specific default board name for a canonical state
  case "$(fb_cfg board.backend)" in
    github-projects)
      case "$1" in
        backlog) echo "Backlog" ;;
        ready) echo "Ready" ;;
        in_progress) echo "In Progress" ;;
        in_review) echo "In Review" ;;
        human_qa) echo "Human QA" ;;
        blocked) echo "Blocked" ;;
        done) echo "Done" ;;
        wont_do) echo "Won't Do" ;;
      esac
      ;;
    *) echo "fleet:$1" ;;
  esac
}

fb_state_name() { local o; o="$(fb_cfg "board.states.$1")"; [ -n "$o" ] && echo "$o" || fb_default_name "$1"; }

# Board name -> canonical, or empty
fb_canonical_of() {
  local s; for s in $FB_STATES; do [ "$(fb_state_name "$s")" = "$1" ] && { echo "$s"; return; }; done
}

fb_has_acceptance() { printf '%s\n' "$1" | grep -Eq '^##[[:space:]]+Acceptance([[:space:]].*)?$'; }

# fb_list_limit DEFAULT: the --limit a backend passes to its gh list call,
# FLEET_BOARD_LIST_LIMIT when set. Dies (1) on a value that is not a positive
# integer. Callers run it in $(...), so they must add `|| exit 1`.
fb_list_limit() {
  local v="${FLEET_BOARD_LIST_LIMIT:-$1}"
  case "$v" in
    ''|*[!0-9]*|0*) fb_die 1 "FLEET_BOARD_LIST_LIMIT must be a positive integer, got: $v" ;;
  esac
  printf '%s\n' "$v"
}

# fb_list_truncated COUNT LIMIT WHAT REMEDY: a gh list reply of LIMIT items may
# be cut short, and a short column silently drops cards, so fail closed (exit 1)
# naming both remedies: a higher FLEET_BOARD_LIST_LIMIT, or REMEDY (the
# backend's way to shrink what it lists). FB_LIST_ALLOW_TRUNCATED=1, set only by
# `board-list.sh --allow-truncated`, downgrades the failure to a warning.
fb_list_truncated() {
  [ "$1" -lt "$2" ] && return 0
  if [ "${FB_LIST_ALLOW_TRUNCATED:-}" = 1 ]; then
    printf 'fleet-board: warning: %s returned %s items, the list limit (%s); the list may be truncated, continuing\n' "$3" "$1" "$2" >&2
    return 0
  fi
  fb_die 1 "$3 returned $1 items, the list limit ($2); the list may be truncated. Set FLEET_BOARD_LIST_LIMIT above $2, or $4, and retry"
}

fb_valid_number() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# fb_lock <card-number>; releases on EXIT
fb_lock() {
  local dir wait stale_min=5 waited=0
  dir="$FLEET_ROOT/$(fb_cfg worktrees.dir)/.locks"; mkdir -p "$dir"
  FB_LOCK="$dir/card-$1.lock"; wait="${FLEET_BOARD_LOCK_WAIT:-30}"
  while ! mkdir "$FB_LOCK" 2>/dev/null; do
    if [ -n "$(find "$FB_LOCK" -maxdepth 0 -mmin +$stale_min 2>/dev/null)" ]; then
      # Known race: waiters A and B both see the lock as stale. B removes it and
      # takes a fresh lock; A's rm -rf then deletes B's live lock and A takes it
      # too, so two holders run at once. Accepted for now (see rehearsal notes).
      rm -rf "$FB_LOCK"; continue
    fi
    [ "$waited" -ge $((wait * 10)) ] && fb_die 1 "could not take lock $FB_LOCK after ${wait}s"
    sleep 0.1; waited=$((waited + 1))
  done
  echo $$ > "$FB_LOCK/pid"
  trap 'rm -rf "$FB_LOCK"' EXIT
}
