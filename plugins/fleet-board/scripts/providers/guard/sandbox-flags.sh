#!/usr/bin/env bash
# sandbox-flags.sh <worktree> <tmpdir> - print the provider CLI flags that limit its filesystem to the
# card's worktree and its temp directory (the codex form: --sandbox workspace-write, -C, --add-dir).
#
# Fails closed: exit 2 with a line on stderr and nothing on stdout when the flags cannot be built (a
# missing or unwritable directory, a path the flags cannot carry, or FLEET_GUARD_SANDBOX=unavailable).
set -uo pipefail
unset CDPATH
[ $# -eq 2 ] || { echo "usage: sandbox-flags.sh <worktree> <tmpdir>" >&2; exit 2; }
refuse() { printf 'fleet-board guard: no sandbox flags: %s\n' "$1" >&2; exit 2; }
[ "${FLEET_GUARD_SANDBOX:-}" != unavailable ] || refuse "the sandbox is marked unavailable"
[ -d "$1" ] || refuse "worktree $1 is not a directory"
[ -d "$2" ] || refuse "temp directory $2 is not a directory"
[ -w "$2" ] || refuse "temp directory $2 is not writable"
WT="$(cd "$1" && pwd -P)" || refuse "cannot enter $1"
TMPD="$(cd "$2" && pwd -P)" || refuse "cannot enter $2"
[ -e "$WT/.git" ] || refuse "$WT is not a git worktree"
case "$WT$TMPD" in *[[:space:]]*|*[[:cntrl:]]*) refuse "a path holds a space or control character" ;; esac
printf -- '--sandbox workspace-write -C %s --add-dir %s\n' "$WT" "$TMPD"
