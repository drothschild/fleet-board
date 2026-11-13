#!/usr/bin/env bash
# board-lib.sh - Shared board adapter library
#
# Sourced by contract scripts; provides common functions and variables.
# Exports: FLEET_CFG, FLEET_ROOT, FLEET_REPO, FLEET_SCRIPTS (set by fb_load_config)
# FB_LOCK is set by fb_lock and used with trap EXIT to clean up

FB_STATES_FIXED="backlog ready in_progress in_review merging human_qa blocked done wont_do"
FB_STATES="$FB_STATES_FIXED"
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
  fb_set_states
}

# fb_set_states: sets FB_STATES to the fixed states with review_<name> for each
# review stage of $FLEET_CFG inserted after in_review, in config order.
fb_set_states() {
  local extra; extra="$(fb_stage_states | tr '\n' ' ')"
  extra="${extra% }"
  if [ -z "$extra" ]; then FB_STATES="$FB_STATES_FIXED"; return 0; fi
  FB_STATES="${FB_STATES_FIXED/in_review/in_review $extra}"
}

# fb_mark_active <n>: touches <board.dir>/active/<n>
# (the web board lights the card while a role works on it) and sets
# FB_ACTIVE_FILE to it. An existing marker is never truncated: the
# supervisor writes the session's process group into it. A failure is a
# warning, never an error. Needs the config loaded.
fb_mark_active() {
  . "$FB_SCRIPTS/adapters/local/local-lib.sh"
  local d; d="$(fl_active_dir)"
  # the group's own stderr is silenced: a redirection error is printed by the
  # shell before a trailing 2>/dev/null on the command takes effect
  if { mkdir -p "$d" && : >> "$d/$1"; } 2>/dev/null; then
    FB_ACTIVE_FILE="$d/$1"
  else
    printf 'fleet-board: warning: cannot write the active marker for #%s\n' "$1" >&2
  fi
  return 0
}

# fb_stage_states: the stage states of $FLEET_CFG, one per line, in config order.
fb_stage_states() {
  [ -n "${FLEET_CFG:-}" ] || return 0
  jq -r '(.review.stages // [])[] | "review_" + .name' <<<"$FLEET_CFG"
}

# fb_stage_of_state <review_x>: prints that stage's JSON object, or nothing.
fb_stage_of_state() {
  [ -n "${FLEET_CFG:-}" ] || return 0
  jq -c --arg s "$1" '(.review.stages // [])[] | select("review_" + .name == $s)' <<<"$FLEET_CFG"
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

# fb_login: the login whose manager note counts on this board: FLEET_BOARD_USER,
# else $USER, else `id -un` (no gh call); exits 1 if it cannot be determined
fb_login() {
  local u="${FLEET_BOARD_USER:-${USER:-}}"
  [ -n "$u" ] || u="$(id -un 2>/dev/null)"
  [ -n "$u" ] || fb_die 1 "cannot determine the local user: set FLEET_BOARD_USER (USER is unset and id -un failed)"
  printf '%s\n' "$u"
}

# fb_token_scopes <gh auth status output>: prints the "Token scopes:" line of
# github.com's ACTIVE account, or nothing when gh shows none for it (a
# GH_TOKEN token, a failed login, or no github.com login). init.sh talks
# to github.com only, so another host's accounts never count.
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
  # The default board (column) name of a canonical state
  case "$1" in
    review_*) echo "Review: ${1#review_}" ;;
    backlog) echo "Backlog" ;;
    ready) echo "Ready" ;;
    in_progress) echo "In Progress" ;;
    in_review) echo "In Review" ;;
    merging) echo "Merging" ;;
    human_qa) echo "Human QA" ;;
    blocked) echo "Blocked" ;;
    done) echo "Done" ;;
    wont_do) echo "Won't Do" ;;
  esac
}

fb_state_name() { local o; o="$(fb_cfg "board.states.$1")"; [ -n "$o" ] && echo "$o" || fb_default_name "$1"; }

# Board name -> canonical, or empty
fb_canonical_of() {
  local s; for s in $FB_STATES; do [ "$(fb_state_name "$s")" = "$1" ] && { echo "$s"; return; }; done
}

# (a here-string, not a pipe: grep -q quits at its first match, and under pipefail a
# body bigger than the pipe buffer would kill the writer and read as "no Acceptance")
fb_has_acceptance() { grep -Eq '^##[[:space:]]+Acceptance([[:space:]].*)?$' <<<"$1"; }

# fb_card_has_acceptance <card-json>: a card (a read, or a stored card file)
# has acceptance when its "acceptance" array is non-empty, whatever its body
# says. A card without the field (a store that predates migrate-card-fields.sh)
# has none: migrate first.
fb_card_has_acceptance() {
  jq -e '(.acceptance | type) == "array" and (.acceptance | length) > 0' <<<"$1" >/dev/null 2>&1
}

# fb_card_text <board-read-json>: the card as text for a reader that scans
# prose (the reviewers, lint's missing-file scan): the body with its trailing
# newlines trimmed, then "## Acceptance" and one "- " line per acceptance item
# when there are any. Prints nothing extra for a card without acceptance.
fb_card_text() {
  jq -r '((.body // "") | sub("\n+$"; "")) as $b | ((.acceptance // []) | map(select(type == "string"))) as $a
    | if ($a | length) == 0 then (.body // "")
      else (if $b == "" then "" else $b + "\n\n" end) + "## Acceptance\n" + ($a | map("- " + .) | join("\n")) + "\n" end' <<<"$1"
}

# fb_list_limit DEFAULT: the --limit import-github.sh passes to its gh list
# calls, FLEET_BOARD_LIST_LIMIT when set. Dies (1) on a value that is not a
# positive integer. Callers run it in $(...), so they must add `|| exit 1`.
fb_list_limit() {
  local v="${FLEET_BOARD_LIST_LIMIT:-$1}"
  case "$v" in
    ''|*[!0-9]*|0*) fb_die 1 "FLEET_BOARD_LIST_LIMIT must be a positive integer, got: $v" ;;
  esac
  printf '%s\n' "$v"
}

# fb_glob_match <path> <pattern>: exit 0 when the path matches. Matched with
# bash `case` after turning ** into *; a pattern that starts with **/ also
# matches with that prefix removed (src/components/** matches
# src/components/a/b.tsx, **/*.test.* matches a.test.js).
fb_glob_match() {
  local path="$1" pat="${2//\*\*/*}"
  # shellcheck disable=SC2254 # the pattern is a glob on purpose
  case "$path" in $pat) return 0 ;; esac
  case "$2" in
    '**/'*)
      pat="${2#\*\*/}"
      pat="${pat//\*\*/*}"
      case "$path" in $pat) return 0 ;; esac
      ;;
  esac
  return 1
}

fb_valid_number() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# fb_pid_alive <pid>: false only when <pid> is known not to run. Unknown counts as
# alive, since calling a live owner dead lets its lock be stolen. It uses the kill
# builtin (no ps, which can be missing, BusyBox or sandboxed): kill -0 succeeding
# is alive, and of its failures only "No such process" (ESRCH, read under LC_ALL=C)
# is dead; EPERM (another user's process) and anything else are alive. A
# non-numeric pid is dead.
fb_pid_alive() {
  local err
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  err="$(export LC_ALL=C; kill -0 "$1" 2>&1)" && return 0
  case "$err" in *"No such process"*) return 1 ;; esac
  return 0
}

# _fb_lock_remove <lockdir>: renames the lock to the private <lockdir>.rel.$$ and
# deletes that copy (the rm is retried once). A late `ln` of a taker's claim goes
# through the lock path, so it can never land in the copy being deleted, and the
# rm cannot fail half done and leave a pid-less dir at the path.
_fb_lock_remove() {
  local rel="$1.rel.$$"
  rm -rf "$rel" 2>/dev/null
  mv "$1" "$rel" 2>/dev/null || return 0
  rm -rf "$rel" 2>/dev/null || rm -rf "$rel"
}

# fb_lock_release <lockdir>: releases a lock this process holds (its pid file
# names $$) through _fb_lock_remove. A lock that is gone or not ours is left alone,
# so a second release (an explicit one, then the EXIT trap) never removes the lock
# a later holder has taken. An empty argument is a no-op. Every release site uses it.
fb_lock_release() {
  [ -n "${1:-}" ] || return 0
  [ "$(cat "$1/pid" 2>/dev/null)" = "$$" ] || return 0
  _fb_lock_remove "$1"
}

# FB_LOCK_PIDLESS_GRACE: seconds a lock may stay without a pid before a waiter takes
# it over (its creator crashed between mkdir and recording its pid). The same value is
# stuck.py's LOCK_GRACE, and FLEET_BOARD_LOCK_PIDLESS_GRACE overrides both. It is far
# above the real gap between mkdir and the pid write (a printf and an ln), and below
# the default 30 s lock wait, so a lone waiter finishes the takeover inside its own
# wait. Safety does not rest on it: an owner that stalls longer only loses the lock.
FB_LOCK_PIDLESS_GRACE=20
_fb_lock_grace() {
  case "${FLEET_BOARD_LOCK_PIDLESS_GRACE:-}" in
    ''|*[!0-9]*) echo "$FB_LOCK_PIDLESS_GRACE" ;;
    *) echo "$FLEET_BOARD_LOCK_PIDLESS_GRACE" ;;
  esac
}

# _fb_lock_older <path> <seconds>: true when <path> itself (a symlink is not followed)
# was last modified more than <seconds> ago. GNU and BusyBox stat take -c %Y, BSD stat
# takes -f %m; neither follows a symlink by default. An unreadable time is not old.
_fb_lock_older() {
  local m
  m="$(stat -c %Y "$1" 2>/dev/null)" || m="$(stat -f %m "$1" 2>/dev/null)" || return 1
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  [ $(( $(date +%s) - m )) -gt "$2" ]
}

# _fb_lock_own <lockdir>: records $$ as the owner of the lock instance now at
# <lockdir>. The pid is written to <lockdir>/.pid.$$ and hard-linked to <lockdir>/pid.
# The link is the ownership step: it fails when pid exists, so each lock instance gets
# exactly one owner, and a reader sees no pid or a whole one. Returns 0 when we are
# the owner, 1 when another process filled the pid first or the instance went away
# (the caller waits again). A failed write dies; before dying it rmdirs the path,
# which can only remove an empty dir, and an empty dir has no owner and no claim.
_fb_lock_own() {
  local tmp="$1/.pid.$$"
  if ! printf '%s\n' "$$" > "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    [ -d "$1" ] || return 1
    rmdir "$1" 2>/dev/null; fb_die 1 "cannot record the owner of lock $1"
  fi
  if ln "$tmp" "$1/pid" 2>/dev/null; then rm -f "$tmp"; return 0; fi
  [ -e "$tmp" ] || return 1                        # the instance changed under us
  rm -f "$tmp"
  [ -e "$1/pid" ] && return 1                      # another process owns it
  rmdir "$1" 2>/dev/null; fb_die 1 "cannot record the owner of lock $1"
}

# _fb_lock_claim <lockdir>: step 1 of a takeover (below). Sets _fb_k and succeeds
# when claim.<_fb_k> in the lock now at <lockdir> is ours.
_fb_lock_claim() {
  local c
  _fb_k=1
  while [ "$_fb_k" -le 32 ]; do
    c="$(readlink "$1/claim.$_fb_k" 2>/dev/null)"
    if [ -z "$c" ]; then
      ln -s "$$" "$1/claim.$_fb_k" 2>/dev/null || return 1   # lost the race, or lock gone
      break
    fi
    [ "$c" = "$$" ] && break
    fb_pid_alive "$c" && return 1                  # a live taker owns this lock
    _fb_k=$((_fb_k + 1))
  done
  [ "$_fb_k" -le 32 ] && _fb_lock_mine "$1"
}
_fb_lock_mine() { [ "$(readlink "$1/claim.$_fb_k" 2>/dev/null)" = "$$" ]; }

# _fb_lock_take <lockdir> <owner>: step 3 of a takeover. Renames the lock aside,
# checks the moved copy still has <owner> as its pid (and, for a dead owner, our
# claim), then deletes it. Fails without touching anything when the rename fails.
_fb_lock_take() {
  local moved="$1.dead.$$"
  rm -rf "$moved"
  mv "$1" "$moved" 2>/dev/null || return 1
  if [ "$(cat "$moved/pid" 2>/dev/null)" = "$2" ] \
     && { [ "$2" = "$$" ] || [ "$(readlink "$moved/claim.$_fb_k" 2>/dev/null)" = "$$" ]; }; then
    rm -rf "$moved"; return 0
  fi
  fb_die 1 "lock takeover of $1 moved a lock it had not claimed; left it at $moved"
}

# fb_lock_acquire <lockdir> <wait-seconds>: takes the mkdir lock <lockdir> and
# records its owner ($$) in <lockdir>/pid. At most one process holds the lock at
# any interleaving, including while a stale lock is taken over.
#
# Owner. mkdir only makes a lock instance; owning it is the next step, the no-clobber
# hard link of our pid onto <lockdir>/pid (_fb_lock_own). That link is path-based, so
# an owner that stalls after its mkdir may find its instance taken over: its link
# then fails on the pid already there, or lands in a newer instance that nobody owns
# yet (whose maker's own link then fails). Either way each instance has one owner,
# and an owner's instance stays at the path until it releases: nothing moves a lock
# with a live pid. A process holds the lock exactly when its link succeeded. A lock
# is stale when its pid is not running (liveness, not age), or when it has had no
# pid for longer than the grace. The owner is the process: subshells share $$.
#
# Takeover. Nothing ever renames or removes a lock path on the strength of an
# earlier read alone: the lock at that path may have been replaced since. A waiter
# first claims the lock instance from inside it:
#   1. Claim. `ln -s $$ <lock>/claim.<k>` creates a symlink whose target is our pid,
#      in one step that fails when the name exists (BSD and GNU ln). It walks k from
#      1: a link naming us is our own claim (reused), a link naming a live process
#      belongs to a taker still at work (back off), a link naming a dead process is
#      passed over to k+1. So each instance has at most one live claimant.
#   2. Verify, between two reads of claim.<k> (ours). Our link can only be in an
#      instance we linked into, and an instance never returns to the path, so both
#      reads, and every read between them, saw that one instance.
#      Dead owner: the pid is still P and P is still dead. P will never release it
#      and no other taker acts on an instance whose live claimant is us.
#      No pid: there is still no pid, and claim.1 is older than the grace. claim.1
#      is the instance's first claim, so the instance has been pid-less at least
#      that long (a pid, once linked, never leaves an instance). The dir's own mtime
#      cannot serve: every claim, ours included, updates it. Then fence: take the
#      pid slot ourselves with _fb_lock_own. If the slow owner's link got there
#      first, ours fails and we back off: it holds the lock. If ours wins, its link
#      fails from now on, and the instance is ours: no one else moves it.
#   3. Remove. Rename the instance to the private <lock>.dead.$$, re-verify its pid
#      (P, or us after the fence) on the moved copy, then delete it and retry mkdir.
#      The rename takes the instance out of the path at once, so a late claim or a
#      late pid lands in no dir or in a newer instance, never in the one deleted.
# Any failed step backs off (sleep, retry) and touches nothing: a lost claim, or a
# claim made in a live lock that was put there after our read, is left in place,
# where it is harmless (the owner's release removes it with the lock, and if that
# owner dies we find our own claim and reuse it). A moved copy that fails the
# re-check cannot happen under the argument above; if it does, the lock is left at
# the moved name and the call fails rather than retry and become a second holder.
#
# Release. A holder releases with fb_lock_release, which renames the lock out of
# the path before deleting it. A plain rm -rf on the path could lose to a late
# claim landing between its unlinks and its rmdir, leaving a pid-less dir behind.
fb_lock_acquire() {
  local lock="$1" wait="$2" waited=0 pid grace
  grace="$(_fb_lock_grace)"
  while :; do
    if mkdir "$lock" 2>/dev/null; then
      _fb_lock_own "$lock" && return 0
    else
      pid="$(cat "$lock/pid" 2>/dev/null)"
      if [ -n "$pid" ] || [ -e "$lock/pid" ]; then   # an owner: stale only when dead
        if ! fb_pid_alive "$pid" && _fb_lock_claim "$lock" \
           && [ "$(cat "$lock/pid" 2>/dev/null)" = "$pid" ] && ! fb_pid_alive "$pid" \
           && _fb_lock_mine "$lock"; then
          _fb_lock_take "$lock" "$pid" && continue
        fi
      elif _fb_lock_claim "$lock" && [ ! -e "$lock/pid" ] \
           && _fb_lock_older "$lock/claim.1" "$grace" && _fb_lock_mine "$lock"; then
        if _fb_lock_own "$lock"; then                # fence the pid slot
          _fb_lock_take "$lock" "$$" && continue
        fi
      fi
    fi
    [ "$waited" -ge $((wait * 10)) ] && fb_die 1 "could not take lock $lock after ${wait}s"
    sleep 0.1; waited=$((waited + 1))
  done
}

# fb_lock <card-number>; releases on EXIT
fb_lock() {
  local dir
  dir="$FLEET_ROOT/$(fb_cfg worktrees.dir)/.locks"; mkdir -p "$dir"
  FB_LOCK="$dir/card-$1.lock"
  fb_lock_acquire "$FB_LOCK" "${FLEET_BOARD_LOCK_WAIT:-30}"
  trap 'fb_lock_release "$FB_LOCK"' EXIT
}

# Adapter scripts are exec'd with FLEET_CFG exported and never call fb_load_config;
# derive the stage states for them at load.
[ -z "${FLEET_CFG:-}" ] || fb_set_states
