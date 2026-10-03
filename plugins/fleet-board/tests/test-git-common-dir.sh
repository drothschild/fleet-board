#!/usr/bin/env bash
#
# Plain-bash tests for fb_git_common_dir (board-lib.sh) and the scripts that
# use it, under a git that lacks `rev-parse --path-format` (git before 2.31).
# A git shim on PATH plays the old git:
#   GIT_SHIM_MODE=reject  --path-format=... is an error (exit 129)
#   GIT_SHIM_MODE=echo    --path-format=... is printed back and ignored, as
#                         old rev-parse does with an unknown flag, so the
#                         common dir comes out relative
# No framework, no dependencies beyond POSIX tools, jq and git.
#
# Usage: bash plugins/fleet-board/tests/test-git-common-dir.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LIB="${SCRIPT_DIR}/../scripts/board-lib.sh"
WORKTREE_SH="${SCRIPT_DIR}/../scripts/worktree.sh"
CONFIG_SH="${SCRIPT_DIR}/../scripts/config.sh"

unset FLEET_BOARD_CONFIG FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT || true

PASS=0
FAIL=0
LAST_OUT=""
LAST_ERR=""
LAST_EXIT=0
CLEANUP_DIRS=()
ORIG_PATH="$PATH"
REAL_GIT="$(command -v git)"

if [ -x /bin/bash ]; then BASH_EXE="/bin/bash"; else BASH_EXE="bash"; fi

cleanup() {
  for dir in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do
    rm -rf "$dir" 2>/dev/null || true
  done
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}

assert_exit() {
  if [ "$LAST_EXIT" = "$2" ]; then pass "$1"; else fail "$1" "expected exit $2, got $LAST_EXIT (stderr: $LAST_ERR)"; fi
}

run_check() {
  local tmpout tmperr
  tmpout="$(mktemp)"
  tmperr="$(mktemp)"
  "$BASH_EXE" "$@" > "$tmpout" 2> "$tmperr"
  LAST_EXIT=$?
  LAST_OUT="$(cat "$tmpout")"
  LAST_ERR="$(cat "$tmperr")"
  rm -f "$tmpout" "$tmperr"
}

# setup: an origin, a clone with a config, a linked worktree, and the shim
setup() {
  local tmp; tmp="$(mktemp -d)"
  CLEANUP_DIRS+=("$tmp")
  TMPROOT="$(cd "$tmp" && pwd -P)"
  git init -q --bare "$TMPROOT/origin.git"
  git -C "$TMPROOT/origin.git" symbolic-ref HEAD refs/heads/main
  REPO="$TMPROOT/repo"
  git init -q "$REPO"
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test User"
  git -C "$REPO" checkout -q -b main
  printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\n' > "$REPO/.fleet-board.yml"
  printf '.fw/\n' > "$REPO/.gitignore"
  git -C "$REPO" add .fleet-board.yml .gitignore
  git -C "$REPO" commit -q -m "initial"
  git -C "$REPO" remote add origin "$TMPROOT/origin.git"
  git -C "$REPO" push -q origin main 2>/dev/null
  git -C "$REPO" fetch -q origin
  git -C "$REPO" remote set-head origin main
  mkdir -p "$REPO/sub"
  LINKED="$TMPROOT/linked"
  git -C "$REPO" worktree add -q --detach "$LINKED" 2>/dev/null
  # a linked worktree on a commit without .fleet-board.yml: config.sh must
  # fall back to the main worktree's copy
  NOCFG="$TMPROOT/nocfg"
  git -C "$REPO" worktree add -q -b nocfg "$NOCFG" 2>/dev/null
  git -C "$NOCFG" rm -q .fleet-board.yml
  git -C "$NOCFG" commit -q -m "no config"
  BASE="$(mkdir -p "$REPO/.fw" && cd "$REPO/.fw" && pwd -P)"

  SHIM="$TMPROOT/shim"
  mkdir -p "$SHIM"
  cat > "$SHIM/git" << SHIMEOF
#!/usr/bin/env bash
# git before 2.31: no rev-parse --path-format
args=()
seen=0
for a in "\$@"; do
  case "\$a" in
    --path-format=*) seen=1 ;;
    *) args+=("\$a") ;;
  esac
done
if [ "\$seen" = 1 ]; then
  if [ "\${GIT_SHIM_MODE:-reject}" = reject ]; then
    printf 'error: unknown option %s\n' "--path-format" >&2
    exit 129
  fi
  printf '%s\n' "--path-format=absolute"
fi
exec "$REAL_GIT" \${args[@]+"\${args[@]}"}
SHIMEOF
  chmod +x "$SHIM/git"
  cd "$REPO"
}

# common_dir <dir>: fb_git_common_dir <dir> in a fresh bash with the given PATH
common_dir() {
  PATH="$1" "$BASH_EXE" -c '. "$1" && fb_git_common_dir "$2"' _ "$LIB" "$2" 2>/dev/null
}

# fleet_root <dir>: FLEET_ROOT as fb_load_config sets it, run from <dir>
fleet_root() {
  (cd "$2" && PATH="$1" "$BASH_EXE" -c '. "$1" && fb_load_config && printf "%s\n" "$FLEET_ROOT"' _ "$LIB" 2>/dev/null)
}

echo "Test: fb_git_common_dir (git without --path-format)"
echo ""

setup
WANT="$(cd "$REPO/.git" && pwd -P)"
for mode in none reject echo; do
  if [ "$mode" = none ]; then P="$ORIG_PATH"; else P="$SHIM:$ORIG_PATH"; fi
  export GIT_SHIM_MODE="$mode"
  assert_eq "$mode: common dir from the repo root" "$(common_dir "$P" "$REPO")" "$WANT"
  assert_eq "$mode: common dir from a subdirectory" "$(common_dir "$P" "$REPO/sub")" "$WANT"
  assert_eq "$mode: common dir from a linked worktree" "$(common_dir "$P" "$LINKED")" "$WANT"
  assert_eq "$mode: FLEET_ROOT from a subdirectory is the repo root" "$(fleet_root "$P" "$REPO/sub")" "$REPO"
  assert_eq "$mode: FLEET_ROOT from a linked worktree is the main repo" "$(fleet_root "$P" "$LINKED")" "$REPO"
  assert_eq "$mode: config.sh in a worktree without the file reads the main worktree's" \
    "$(cd "$NOCFG" && PATH="$P" "$BASH_EXE" "$CONFIG_SH" board.repo 2>&1)" "acme/toy"
  OUTSIDE="$TMPROOT/not-a-repo"; mkdir -p "$OUTSIDE"
  if common_dir "$P" "$OUTSIDE" >/dev/null; then
    fail "$mode: outside a repository fails" "succeeded: $(common_dir "$P" "$OUTSIDE")"
  else
    pass "$mode: outside a repository fails"
  fi
done

# worktree.sh end to end under each old-git mode: create, create again
# (resumption needs the common-dir comparison), remove
for mode in reject echo; do
  setup
  export GIT_SHIM_MODE="$mode"
  export PATH="$SHIM:$ORIG_PATH"
  WT="$BASE/12-add-subtract"
  run_check "$WORKTREE_SH" create 12 fleet/12-add-subtract "$WT"
  assert_exit "$mode: worktree.sh create exit" 0
  assert_eq "$mode: worktree.sh create prints the path" "$LAST_OUT" "$WT"
  run_check "$WORKTREE_SH" create 12 fleet/12-add-subtract "$WT"
  assert_exit "$mode: worktree.sh create again (resumption) exit" 0
  assert_eq "$mode: worktree.sh create again prints the path" "$LAST_OUT" "$WT"
  run_check "$WORKTREE_SH" remove 12 "$WT"
  assert_exit "$mode: worktree.sh remove exit" 0
  if [ -e "$WT" ]; then fail "$mode: worktree removed" "$WT still exists"; else pass "$mode: worktree removed"; fi
  export PATH="$ORIG_PATH"
done
unset GIT_SHIM_MODE

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
