#!/usr/bin/env bash
# shim.sh <guard-dir> <name> [args...] - one command of a provider session.
#
# 1. Builds the PreToolUse(Bash) payload for `<name> <args>` and runs hooks/gate.sh on it: a block
#    prints the gate's line on stderr and exits 2, exactly as it does for a Claude role.
# 2. Applies the implementor's own rules (this file): no card move, no premise decision, no
#    gh pr merge or ready, no git push except to the card's branch (never forced), no git command
#    against a path outside the card's worktree, no git write to .fleet-board.yml or .fleet-board/,
#    no write request to the board server.
# 3. Runs the real command, found without the guard directory on PATH.
#
# Residual: a script called by absolute path (bash /x/scripts/board-move.sh) does not pass a shim;
# the provider's filesystem sandbox and the post-run check are the backstop for that.
set -uo pipefail
unset CDPATH
GUARD_DIR="$1"; NAME="$2"; shift 2
# shellcheck disable=SC1090
. "$GUARD_DIR/guard.env" || { echo "fleet-board guard: cannot read the guard settings; blocking" >&2; exit 2; }

# note_block TEXT: records a blocked call in <guard-dir>/blocked.log, which a runner reads afterwards
note_block() { printf '%s: %s\n' "$NAME" "$1" | tr '\r' ' ' >> "$GUARD_DIR/blocked.log" 2>/dev/null || true; }
# refuse: block without recording (a git command outside the worktree, as a test suite may run)
refuse() { printf 'fleet-board guard: %s\n' "$1" >&2; exit 2; }
block() { note_block "$1"; refuse "$1"; }

# word_text ARG: ARG as a shell word for the gate. A word with a $ or a backtick stays bare, so the
# gate sees the substitution and blocks it; a plain word stays bare; anything else is single-quoted.
word_text() {
  case "$1" in
    *'$'*|*'`'*) printf '%s' "$1" ;;
    ''|*[!A-Za-z0-9_./:=@%+,-]*)
      case "$1" in *"'"*) printf '%s' "$1" ;; *) printf "'%s'" "$1" ;; esac ;;
    *) printf '%s' "$1" ;;
  esac
}

CMD="$NAME"
for a in "$@"; do CMD="$CMD $(word_text "$a")"; done

PAYLOAD="$(jq -nc --arg c "$CMD" --arg d "$PWD" \
  '{session_id: "provider-guard", hook_event_name: "PreToolUse", cwd: $d, tool_name: "Bash", tool_input: {command: $c}}')" \
  || block "cannot build the gate payload; blocking"
GATE_ERR="$(PATH="$GUARD_REAL_PATH" bash "$GUARD_GATE" <<<"$PAYLOAD" 2>&1 >/dev/null)"
GATE_RC=$?
if [ "$GATE_RC" -ne 0 ]; then
  note_block "$(printf '%s' "$GATE_ERR" | head -n 1) ($CMD)"
  printf '%s\n' "$GATE_ERR" >&2
  exit 2
fi

has_subst() { case "$1" in *'$'*|*'`'*) return 0 ;; esac; return 1; }

under_worktree() { # under_worktree DIR: DIR (physical) is the worktree or below it
  local p
  p="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  case "$p/" in "$GUARD_WORKTREE/"*) return 0 ;; esac
  return 1
}

protected_path() { # protected_path ARG: names .fleet-board.yml or something under .fleet-board/
  case "$1" in
    .fleet-board.yml|./.fleet-board.yml|*/.fleet-board.yml|.fleet-board|./.fleet-board|*/.fleet-board|\
    .fleet-board/*|./.fleet-board/*|*/.fleet-board/*) return 0 ;;
  esac
  return 1
}

real_cmd() {
  case "$NAME" in
    board-move|board-move.sh) printf '%s\n' "$GUARD_SCRIPTS/board-move.sh" ;;
    premise-settle.sh) printf '%s\n' "$GUARD_SCRIPTS/premise-settle.sh" ;;
    *) PATH="$GUARD_REAL_PATH" command -v "$NAME" ;;
  esac
}

case "$NAME" in
  board-move|board-move.sh)
    block "a provider session moves no card" ;;
  premise-settle.sh)
    block "a provider session runs no premise decision" ;;
  gh)
    prev=""
    for a in "$@"; do
      if [ "$prev" = pr ]; then
        case "$a" in merge|ready) block "a provider session never runs gh pr $a" ;; esac
      fi
      case "$a" in -*) ;; *) prev="$a" ;; esac
    done ;;
  curl)
    loop=0; write=0
    prev=""
    for a in "$@"; do
      case "$a" in
        *://127.0.0.1*|*://localhost*|*://\[::1\]*|*://0.0.0.0*|127.0.0.1*|localhost*) loop=1 ;;
      esac
      case "$a" in
        -d|--data|--data-*|-F|--form|--form-string|-T|--upload-file|--json|-d*) write=1 ;;
        -X|--request) ;;
        -X*) [ "${a#-X}" = GET ] || write=1 ;;
      esac
      if [ "$prev" = -X ] || [ "$prev" = --request ]; then
        case "$a" in GET|get|HEAD|head) ;; *) write=1 ;; esac
      fi
      prev="$a"
    done
    [ "$loop$write" = 11 ] && block "a provider session sends no write request to the board server" ;;
  git)
    # global options, then the subcommand
    dirs=("$PWD")
    sub=""; rest=()
    i=1; args=("$@")
    n=${#args[@]}
    while [ $i -le $n ]; do
      a="${args[$((i - 1))]}"
      if [ -n "$sub" ]; then rest+=("$a"); i=$((i + 1)); continue; fi
      case "$a" in
        -C)
          i=$((i + 1)); d="${args[$((i - 1))]:-}"
          [ -n "$d" ] || block "git -C needs a path"
          has_subst "$d" && block "git -C path '$d' holds a substitution; blocking"
          case "$d" in /*) dirs+=("$d") ;; *) dirs+=("${dirs[$((${#dirs[@]} - 1))]}/$d") ;; esac ;;
        --git-dir|--git-dir=*|--work-tree|--work-tree=*|--super-prefix|--super-prefix=*)
          refuse "git $a would point git outside the card's worktree" ;;
        -c|--namespace|--exec-path) i=$((i + 1)) ;;
        -*) ;;
        *) sub="$a" ;;
      esac
      i=$((i + 1))
    done
    for d in "${dirs[@]}"; do
      under_worktree "$d" || refuse "git against $d, outside the card's worktree $GUARD_WORKTREE"
    done
    case "$sub" in
      add|rm|mv|checkout|restore|apply|stash|reset|clean|commit|switch|update-index)
        for a in ${rest[@]+"${rest[@]}"}; do
          protected_path "$a" && block "git $sub of $a: .fleet-board.yml and .fleet-board/ are not the provider's to change"
        done ;;
    esac
    if [ "$sub" = push ]; then
      cur="$(PATH="$GUARD_REAL_PATH" git -C "${dirs[$((${#dirs[@]} - 1))]}" branch --show-current 2>/dev/null)"
      pos=()
      for a in ${rest[@]+"${rest[@]}"}; do
        has_subst "$a" && block "git push argument '$a' holds a substitution; blocking"
        case "$a" in
          -u|--set-upstream|-q|--quiet|-v|--verbose|-n|--dry-run|--no-verify|--porcelain|--progress|--no-progress|--atomic) ;;
          -*) block "git push $a is not allowed for a provider session" ;;
          *) pos+=("$a") ;;
        esac
      done
      ok_branch() { [ "$1" = "$GUARD_BRANCH" ] || [ "$1" = "refs/heads/$GUARD_BRANCH" ]; }
      if [ ${#pos[@]} -le 1 ]; then
        [ "$cur" = "$GUARD_BRANCH" ] || block "git push from '$cur' is not a push of the card's branch $GUARD_BRANCH"
      else
        for spec in "${pos[@]:1}"; do
          case "$spec" in
            \+*|'*'|*'*'*|*'?'*|*'['*|'') block "git push refspec '$spec' is not allowed" ;;
          esac
          src="${spec%%:*}"; dst="$src"
          case "$spec" in *:*) dst="${spec#*:}" ;; esac
          if [ "$dst" = HEAD ]; then dst="$cur"; fi
          ok_branch "$dst" || block "git push to '$dst': a provider session pushes only the card's branch $GUARD_BRANCH"
          if [ "$src" = HEAD ]; then
            [ "$cur" = "$GUARD_BRANCH" ] || block "git push HEAD from '$cur', not the card's branch $GUARD_BRANCH"
          fi
        done
      fi
    fi ;;
esac

REAL="$(real_cmd)" || block "cannot find the real $NAME"
[ -n "$REAL" ] || block "cannot find the real $NAME"
case "$NAME" in
  board-move|board-move.sh|premise-settle.sh) exec bash "$REAL" "$@" ;;
  *) exec "$REAL" "$@" ;;
esac
