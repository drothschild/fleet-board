#!/usr/bin/env bash
# verify-main.sh - checks main after a card's PR merged (typecheck plus the
# touched tests), and files a P0 card when main is red.
#
# Usage: verify-main.sh <card-n> <pr>
#
# Steps:
#   1. git fetch origin.
#   2. Put the detached worktree <base>/main-check on origin/main, creating it
#      or checking the new commit out in it. The user's own checkout is never
#      touched. worktrees.setup runs when main-check is first created, and
#      again when package-lock.json, yarn.lock or pnpm-lock.yaml changed
#      between its previous and new HEAD.
#   3. Runs commands.typecheck in main-check, when set.
#   4. For each file of `gh pr view <pr> --json files` that matches test_paths
#      and exists on main, runs commands.test_one with {file} replaced by the
#      path. A path outside [A-Za-z0-9._/@+-] is not substituted into a shell
#      command; it is recorded as a failed result instead.
#   5. Prints {"commit": <sha>, "ok": bool, "results": [{"cmd", "exit"}]}.
#   6. When ok is false, files the Backlog card "[P0] main is red after #<pr>"
#      and adds "p0_card": <n>. It first searches the open issues
#        gh issue list --state open --search "<terms> in:title"
#      (<terms> is the title with each character outside [A-Za-z0-9 _-]
#      turned into a space); a row whose title equals the P0 title,
#      case-insensitively, is reused (a retry never files a second card).
#      Otherwise it creates the card through board-create.sh (its body names
#      the commit, the failing commands, "Merged PR: #<pr>" and the card).
#      A failed or unexpected search exits 1: it never files blind.
#      Limits of the reuse:
#      - GitHub search is eventually consistent. A new issue can take a while
#        to appear in search results, so a retry within seconds of a run that
#        filed the card can still file a duplicate.
#      - On the github-projects backend, filing is two steps (create the
#        issue, then add it to the project), so a run can leave the issue off
#        the board. A reused issue is read with board-read.sh; when it is not
#        an item of the project (item_id null) it is moved to backlog with
#        board-move.sh, which adds it to the project. An issue already on the
#        project is left in whatever column it is in. A failed read or move
#        exits 1.
#        On github-labels, one gh issue create files and labels the card, so
#        no board check is made.
# Command output goes to stderr; stdout holds only the JSON.
#
# <base> is the normalized worktrees directory (cd <worktrees.dir> && pwd -P).
#
# Exit codes:
#   0 - verified; JSON printed (ok may be false, with the P0 card filed)
#   1 - main could not be verified (fetch, worktree, setup, or PR files lookup
#       failed), or main is red and the P0 card could not be searched for or
#       filed; nothing is printed on stdout
#   2 - usage error

set -uo pipefail
unset CDPATH # a relative cd must not follow CDPATH (it would also echo the path)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

[ $# -eq 2 ] || fb_die 2 "usage: verify-main.sh <card-n> <pr>"
fb_valid_number "$1" || fb_die 2 "card number must be numeric, got: $1"
fb_valid_number "$2" || fb_die 2 "PR number must be numeric, got: $2"
CARD="$1"
PR="$2"

fb_load_config

WT_DIR="$FLEET_ROOT/$(fb_cfg worktrees.dir)"
BASE="$(mkdir -p "$WT_DIR" && cd "$WT_DIR" && pwd -P)" || fb_die 1 "cannot resolve the worktrees directory $WT_DIR"
[ -n "$BASE" ] || fb_die 1 "cannot resolve the worktrees directory $WT_DIR"
MC="$BASE/main-check"
SETUP="$(fb_cfg worktrees.setup)"
COMMON="$(fb_git_common_dir "$FLEET_ROOT")" \
  || fb_die 1 "$FLEET_ROOT is not a git repository"

g() { git -C "$FLEET_ROOT" "$@"; }

RES="" BODY=""
trap 'rm -f ${RES:+"$RES"} ${BODY:+"$BODY"}' EXIT
RES="$(mktemp)" || fb_die 1 "cannot create a temp file"

# is_our_worktree <path>: the path is the top of a worktree of this repository
is_our_worktree() {
  local top common
  top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || return 1
  common="$(fb_git_common_dir "$1")" || return 1
  [ "$(cd "$top" && pwd -P)" = "$(cd "$1" && pwd -P)" ] && [ "$common" = "$COMMON" ]
}

# matches <path> <glob>: the test_paths rule (** is *, and a leading **/ is optional)
matches() {
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

# run_cmd <command>: runs it in main-check and records {cmd, exit}
run_cmd() {
  local ec
  (cd "$MC" && bash -c "$1") </dev/null >&2
  ec=$?
  jq -nc --arg c "$1" --argjson e "$ec" '{cmd: $c, exit: $e}' >> "$RES" || fb_die 1 "cannot record a result"
}

# 1-2. main-check at origin/main
g fetch -q origin >&2 || fb_die 1 "git fetch origin failed"
NEW="$(g rev-parse --verify --quiet "refs/remotes/origin/main^{commit}")" || fb_die 1 "origin/main does not exist"
RUN_SETUP=0
if [ -L "$MC" ] || [ -e "$MC" ]; then
  is_our_worktree "$MC" || fb_die 1 "$MC exists and is not a worktree of this repository"
  PREV="$(git -C "$MC" rev-parse --verify --quiet HEAD)" || fb_die 1 "cannot read the HEAD of $MC"
  git -C "$MC" checkout -q --force --detach "$NEW" >&2 || fb_die 1 "cannot check out origin/main in $MC"
  git -C "$MC" diff --quiet "$PREV" "$NEW" -- package-lock.json yarn.lock pnpm-lock.yaml || RUN_SETUP=1
else
  g worktree add -q --detach "$MC" "$NEW" >&2 || fb_die 1 "cannot add the worktree $MC"
  RUN_SETUP=1
fi
if [ "$RUN_SETUP" = 1 ] && [ -n "$SETUP" ]; then
  if ! (cd "$MC" && bash -c "$SETUP") </dev/null >&2; then
    # Removed so that the next run creates it again and re-runs setup
    g worktree remove --force "$MC" >&2
    fb_die 1 "worktrees.setup failed in $MC; the worktree was removed"
  fi
fi
COMMIT="$(git -C "$MC" rev-parse --verify --quiet HEAD)" || fb_die 1 "cannot read the HEAD of $MC"
[ "$COMMIT" = "$NEW" ] || fb_die 1 "$MC is at $COMMIT, expected origin/main $NEW"

# The PR's files, before anything runs
FILES_JSON="$(gh pr view "$PR" --repo "$FLEET_REPO" --json files)" || fb_die 1 "cannot list the files of PR #$PR"
PATHS="$(jq -r 'if (.files | type) == "array" then .files[].path else error("no files") end' <<<"$FILES_JSON" 2>/dev/null)" \
  || fb_die 1 "cannot parse the files of PR #$PR"
PATTERNS="$(jq -r '.test_paths[]' <<<"$FLEET_CFG")" || fb_die 1 "cannot read test_paths"

# 3. typecheck
TYPECHECK="$(fb_cfg commands.typecheck)"
[ -z "$TYPECHECK" ] || run_cmd "$TYPECHECK"

# 4. touched tests that exist on main
TEST_ONE="$(fb_cfg commands.test_one)"
safe_re='^[A-Za-z0-9._/@+][A-Za-z0-9._/@+-]*$'
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "/$f/" in */../*) continue ;; esac
  case "$f" in /*) continue ;; esac
  hit=0
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    if matches "$f" "$pat"; then hit=1; break; fi
  done <<<"$PATTERNS"
  [ "$hit" = 1 ] || continue
  [ -f "$MC/$f" ] || continue
  if [ -z "$TEST_ONE" ]; then
    printf 'fleet-board: warning: commands.test_one is not set; not running %s\n' "$f" >&2
    continue
  fi
  if ! [[ "$f" =~ $safe_re ]]; then
    printf 'fleet-board: warning: refusing to run a test with an unsafe path: %s\n' "$f" >&2
    jq -nc --arg c "refused unsafe test path: $f" '{cmd: $c, exit: 1}' >> "$RES" || fb_die 1 "cannot record a result"
    continue
  fi
  run_cmd "${TEST_ONE//\{file\}/$f}"
done <<<"$PATHS"

# 5. the result
OUT="$(jq -s -c --arg c "$COMMIT" '{commit: $c, ok: all(.[]; .exit == 0), results: .}' "$RES")" \
  || fb_die 1 "cannot build the result"

# 6. a red main files a P0 card, or reuses the open one a previous run filed
if [ "$(jq -r .ok <<<"$OUT")" != true ]; then
  TITLE="[P0] main is red after #$PR"
  CREATED="" # set only when this run files the card; never inherited
  TERMS="$(jq -rn --arg t "$TITLE" '$t | gsub("[^A-Za-z0-9 _-]"; " ")')" || fb_die 1 "cannot build the P0 search terms"
  ROWS="$(gh issue list --repo "$FLEET_REPO" --state open --search "$TERMS in:title" --json number,title --limit 50 </dev/null)" \
    || fb_die 1 "main is red at $COMMIT, and the search for an open P0 card failed; nothing filed"
  P0="$(jq -r --arg t "$TITLE" '
    if type != "array" then error("not a list") else . end
    | [.[] | select((.title | type) == "string" and (.title | ascii_downcase) == ($t | ascii_downcase))]
    | .[0].number // "none"' <<<"$ROWS" 2>/dev/null)" \
    || fb_die 1 "main is red at $COMMIT, and the P0 search returned an unexpected answer; nothing filed"
  if [ "$P0" = none ]; then
    BODY="$(mktemp)" || fb_die 1 "cannot create a temp file"
    {
      printf '`main` is red at commit %s after PR #%s merged.\n\n' "$COMMIT" "$PR"
      printf 'Failing commands:\n'
      jq -r '.results[] | select(.exit != 0) | "- `\(.cmd)` exited \(.exit)"' <<<"$OUT"
      printf '\nMerged PR: #%s\n' "$PR"
      printf 'Card: #%s\n' "$CARD"
    } > "$BODY" || fb_die 1 "cannot write the P0 card body"
    CREATED="$(bash "$FLEET_SCRIPTS/board-create.sh" "$TITLE" "$BODY")" \
      || fb_die 1 "main is red at $COMMIT, and the P0 card could not be created"
    P0="$(jq -r '.number' <<<"$CREATED" 2>/dev/null)"
    fb_valid_number "$P0" || fb_die 1 "main is red at $COMMIT, and board-create.sh returned no card number"
  fi
  fb_valid_number "$P0" || fb_die 1 "main is red at $COMMIT, and the P0 search returned an unexpected answer; nothing filed"
  # A reused card on the projects backend may never have reached the board
  if [ -z "${CREATED:-}" ] && [ "$(fb_cfg board.backend)" = github-projects ]; then
    P0READ="$(bash "$FLEET_SCRIPTS/board-read.sh" "$P0" </dev/null)" \
      || fb_die 1 "main is red at $COMMIT, and the open P0 card #$P0 could not be read to check it is on the board"
    P0ITEM="$(jq -r 'if type == "object" and has("item_id") then (.item_id // "") else error("not a card") end' <<<"$P0READ" 2>/dev/null)" \
      || fb_die 1 "main is red at $COMMIT, and the open P0 card #$P0 could not be read to check it is on the board"
    if [ -z "$P0ITEM" ]; then
      bash "$FLEET_SCRIPTS/board-move.sh" "$P0" backlog </dev/null >&2 \
        || fb_die 1 "main is red at $COMMIT, and the open P0 card #$P0 is not on the board and could not be added"
    fi
  fi
  OUT="$(jq -c --argjson n "$P0" '. + {p0_card: $n}' <<<"$OUT")" || fb_die 1 "cannot build the result"
fi

printf '%s\n' "$OUT"
