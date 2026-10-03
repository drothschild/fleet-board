#!/usr/bin/env bash
# worktree.sh - creates, refreshes and removes a card's git worktrees.
#
# Usage:
#   worktree.sh create <n> <branch> <path>
#       Fetches origin. When <path> is already a worktree of this repo on
#       <branch>, prints the path and stops (resumption). Otherwise adds a
#       worktree at <path>: on the local branch when it exists, else tracking
#       origin/<branch> when that exists, else a new branch from origin/HEAD
#       (falling back to origin/main). Runs worktrees.setup in a worktree it
#       just created, then prints the path. When setup fails, the worktree is
#       removed; when this call made the branch from origin/HEAD or
#       origin/main it is also deleted, so the retry starts from the current
#       origin base. A pre-existing local branch, or one just created tracking
#       origin/<branch>, is kept. When the branch is already checked
#       out in another worktree (for example under an old worktrees.dir, or in
#       a repo that moved), it adds nothing and fails with
#         fleet-board: branch <branch> is checked out at <other path>; remove that worktree (git worktree remove, or git worktree prune when its directory is gone) or restore worktrees.dir
#       or, when the other checkout is the repository's main checkout,
#         fleet-board: branch <branch> is checked out at <path>, the repository's main checkout; switch that checkout to another branch
#   worktree.sh review <n> <pr>
#       Fetches the PR head (into refs/fleet-board/pull/<pr>) and puts a
#       detached worktree <base>/<n>-review on it, creating it (and running
#       worktrees.setup once) or checking the new head out in it. With
#       worktrees.mutate_on_copy, also refreshes <base>/<n>-review-copy, a
#       cp -R of the checkout without .git. Prints
#       {"path":..,"copy":..|null,"sha":<head>,"base":<merge-base origin/main head>}.
#   worktree.sh remove <n> [<worktree-path>]
#       Removes <worktree-path>, which must be the card's own directory: a
#       direct child of <base> named <n>-* (as given and after symlinks are
#       resolved), never main-check (an empty string or "null" counts as omitted;
#       omitted means every <base>/<n>-* except <n>-review and
#       <n>-review-copy), then <n>-review, then <n>-review-copy, then runs
#       git worktree prune. Missing paths are fine. Never deletes a branch.
#
# <base> is the normalized worktrees directory:
#   cd "$FLEET_ROOT/<worktrees.dir>" && pwd -P
# Every path this script touches must resolve (symlinks followed) to a path
# strictly under <base>; create also requires <path> to be a direct child.
# A path outside it, or holding a "." or ".." segment, is refused before
# anything is changed.
#
# Exit codes:
#   0 - done (create: path printed; review: JSON printed; remove: all removed)
#   1 - refused path, git failure, setup failure, or an existing path that is
#       not the expected worktree
#   2 - usage error

set -uo pipefail
unset CDPATH # a relative cd must not follow CDPATH (it would also echo the path)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

usage() { fb_die 2 "usage: worktree.sh create <n> <branch> <path> | review <n> <pr> | remove <n> [<worktree-path>]"; }

[ $# -ge 2 ] || usage
CMD="$1"
N="$2"
fb_valid_number "$N" || fb_die 2 "card number must be numeric, got: $N"
case "$CMD" in
  create) [ $# -eq 4 ] || usage ;;
  review) [ $# -eq 3 ] || usage; fb_valid_number "$3" || fb_die 2 "PR number must be numeric, got: $3" ;;
  remove) [ $# -eq 2 ] || [ $# -eq 3 ] || usage ;;
  *) usage ;;
esac

fb_load_config

WT_DIR="$FLEET_ROOT/$(fb_cfg worktrees.dir)"
BASE="$(mkdir -p "$WT_DIR" && cd "$WT_DIR" && pwd -P)" || fb_die 1 "cannot resolve the worktrees directory $WT_DIR"
[ -n "$BASE" ] || fb_die 1 "cannot resolve the worktrees directory $WT_DIR"
SETUP="$(fb_cfg worktrees.setup)"
COMMON="$(fb_git_common_dir "$FLEET_ROOT")" \
  || fb_die 1 "$FLEET_ROOT is not a git repository"

g() { git -C "$FLEET_ROOT" "$@"; }

# resolve_under_base <path>: prints the path with symlinks resolved when it is
# absolute, has no "." or ".." segment, and resolves strictly under $BASE.
resolve_under_base() {
  local p="$1" r
  case "$p" in /*) ;; *) return 1 ;; esac
  case "$p/" in */../*|*/./*) return 1 ;; esac
  if [ -L "$p" ] || [ -e "$p" ]; then
    [ -d "$p" ] || return 1
    r="$(cd "$p" && pwd -P)" || return 1
  else
    r="${p%/}"
  fi
  case "$r" in "$BASE"/?*) printf '%s\n' "$r" ;; *) return 1 ;; esac
}

# is_our_worktree <path>: the path is the top of a worktree of this repository
is_our_worktree() {
  local top common
  top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || return 1
  common="$(fb_git_common_dir "$1")" || return 1
  [ "$(cd "$top" && pwd -P)" = "$(cd "$1" && pwd -P)" ] && [ "$common" = "$COMMON" ]
}

# run_setup <worktree> [<new-branch>]: runs worktrees.setup inside it; on
# failure removes the worktree (so the next attempt starts fresh and runs setup
# again), deletes <new-branch> when given (a branch this call just made, so the
# retry starts from the current origin base), and fails
run_setup() {
  [ -n "$SETUP" ] || return 0
  if ! (cd "$1" && bash -c "$SETUP") >&2; then
    g worktree remove --force "$1" >&2 2>/dev/null
    if [ -n "${2:-}" ]; then
      if g branch -D -q "$2" >&2; then
        fb_die 1 "worktrees.setup failed in $1; the worktree was removed; the new branch was deleted"
      fi
      fb_die 1 "worktrees.setup failed in $1; the worktree was removed; the new branch $2 could not be deleted"
    fi
    fb_die 1 "worktrees.setup failed in $1; the worktree was removed"
  fi
}

case "$CMD" in
  create)
    B="$3"
    re='^fleet/[0-9]+-[a-z0-9-]{1,40}$'
    [[ "$B" =~ $re ]] || fb_die 2 "branch must match fleet/<n>-<slug>, got: $B"
    P="$(resolve_under_base "$4")" || fb_die 1 "refusing a path outside $BASE: $4"
    [ "$(dirname "$P")" = "$BASE" ] || fb_die 1 "refusing a path that is not directly under $BASE: $4"
    g fetch -q origin >&2 || fb_die 1 "git fetch origin failed"
    if [ -e "$P" ]; then
      if is_our_worktree "$P" && [ "$(git -C "$P" symbolic-ref -q --short HEAD 2>/dev/null)" = "$B" ]; then
        printf '%s\n' "$P"
        exit 0
      fi
      fb_die 1 "$P exists and is not a worktree on $B"
    fi
    # A branch can be checked out in one worktree only; name the other one
    # rather than passing on git's error
    OTHER="$(g worktree list --porcelain 2>/dev/null | awk -v ref="refs/heads/$B" '
      /^worktree / { p = substr($0, 10) }
      $0 == "branch " ref { print p; exit }')"
    if [ -n "$OTHER" ]; then
      # The main checkout cannot be removed; it has to switch branches
      if [ -d "$OTHER" ] && [ "$(cd "$OTHER" && pwd -P)" = "$(cd "$FLEET_ROOT" && pwd -P)" ]; then
        fb_die 1 "branch $B is checked out at $OTHER, the repository's main checkout; switch that checkout to another branch"
      fi
      fb_die 1 "branch $B is checked out at $OTHER; remove that worktree (git worktree remove, or git worktree prune when its directory is gone) or restore worktrees.dir"
    fi
    NEW_BRANCH=""
    if g show-ref --verify --quiet "refs/heads/$B"; then
      g worktree add -q "$P" "$B" >&2 || fb_die 1 "cannot add a worktree for $B at $P"
    elif g show-ref --verify --quiet "refs/remotes/origin/$B"; then
      g worktree add -q --track -b "$B" "$P" "origin/$B" >&2 || fb_die 1 "cannot add a worktree tracking origin/$B at $P"
    else
      if g rev-parse --verify --quiet "refs/remotes/origin/HEAD^{commit}" >/dev/null; then START=origin/HEAD
      elif g rev-parse --verify --quiet "refs/remotes/origin/main^{commit}" >/dev/null; then START=origin/main
      else fb_die 1 "neither origin/HEAD nor origin/main exists"
      fi
      g worktree add -q --no-track -b "$B" "$P" "$START" >&2 || fb_die 1 "cannot add a worktree for $B from $START at $P"
      NEW_BRANCH="$B"
    fi
    run_setup "$P" "$NEW_BRANCH"
    printf '%s\n' "$P"
    ;;

  review)
    PR="$3"
    RV="$BASE/$N-review"
    RC="$BASE/$N-review-copy"
    REF="refs/fleet-board/pull/$PR"
    g fetch -q origin >&2 || fb_die 1 "git fetch origin failed"
    g fetch -q origin "+refs/pull/$PR/head:$REF" >&2 || fb_die 1 "cannot fetch the head of PR #$PR"
    SHA="$(g rev-parse --verify --quiet "$REF^{commit}")" || fb_die 1 "cannot resolve the head of PR #$PR"
    if [ -L "$RV" ] || [ -e "$RV" ]; then
      is_our_worktree "$RV" || fb_die 1 "$RV exists and is not a worktree of this repository"
      git -C "$RV" checkout -q --force --detach "$SHA" >&2 || fb_die 1 "cannot check out $SHA in $RV"
    else
      g worktree add -q --detach "$RV" "$SHA" >&2 || fb_die 1 "cannot add the review worktree $RV"
      run_setup "$RV"
    fi
    COPY=null
    rm -rf "$RC" || fb_die 1 "cannot remove the old copy $RC"
    if [ "$(fb_cfg worktrees.mutate_on_copy)" = true ]; then
      mkdir "$RC" || fb_die 1 "cannot create $RC"
      (cd "$RV" && find . -mindepth 1 -maxdepth 1 ! -name .git -exec cp -R {} "$RC/" \;) \
        || fb_die 1 "cannot copy $RV to $RC"
      COPY="$RC"
    fi
    MB="$(g merge-base origin/main "$SHA")" || fb_die 1 "cannot compute merge-base origin/main $SHA"
    jq -nc --arg p "$RV" --arg c "$COPY" --arg s "$SHA" --arg b "$MB" \
      '{path: $p, copy: (if $c == "null" then null else $c end), sha: $s, base: $b}'
    ;;

  remove)
    GIVEN="${3:-}"
    [ "$GIVEN" = null ] && GIVEN=""
    TARGETS=()
    if [ -n "$GIVEN" ]; then
      T="$(resolve_under_base "$GIVEN")" || fb_die 1 "refusing a path outside $BASE: $GIVEN"
      # Only the card's own directory: <base>/<n>-*, never main-check, never
      # another card's (checked on the path as given and as resolved)
      GP="$(cd "$(dirname "$GIVEN")" 2>/dev/null && pwd -P)"
      { [ "$(dirname "$T")" = "$BASE" ] && [ "$GP" = "$BASE" ]; } \
        || fb_die 1 "refusing a path that is not directly under $BASE: $GIVEN"
      for b in "$(basename "$GIVEN")" "$(basename "$T")"; do
        case "$b" in
          main-check) fb_die 1 "refusing to remove main-check: $GIVEN" ;;
          "$N"-?*) ;;
          *) fb_die 1 "refusing a path that is not card #$N's directory ($N-*): $GIVEN" ;;
        esac
      done
      TARGETS+=("$T")
    else
      for d in "$BASE/$N"-*; do
        [ -L "$d" ] || [ -e "$d" ] || continue
        case "$(basename "$d")" in "$N-review"|"$N-review-copy") continue ;; esac
        T="$(resolve_under_base "$d")" || fb_die 1 "refusing a path outside $BASE: $d"
        TARGETS+=("$T")
      done
    fi
    if [ -L "$BASE/$N-review" ] || [ -e "$BASE/$N-review" ]; then
      T="$(resolve_under_base "$BASE/$N-review")" || fb_die 1 "refusing a path outside $BASE: $BASE/$N-review"
      TARGETS+=("$T")
    fi
    RC=0
    for t in ${TARGETS[@]+"${TARGETS[@]}"}; do
      [ -L "$t" ] || [ -e "$t" ] || continue
      if ! g worktree remove --force "$t" >&2; then
        printf 'fleet-board: cannot remove the worktree %s\n' "$t" >&2
        RC=1
      fi
    done
    if [ -L "$BASE/$N-review-copy" ] || [ -e "$BASE/$N-review-copy" ]; then
      rm -rf "$BASE/$N-review-copy" || { printf 'fleet-board: cannot remove %s\n' "$BASE/$N-review-copy" >&2; RC=1; }
    fi
    g worktree prune >&2 || { printf 'fleet-board: git worktree prune failed\n' >&2; RC=1; }
    exit "$RC"
    ;;
esac
