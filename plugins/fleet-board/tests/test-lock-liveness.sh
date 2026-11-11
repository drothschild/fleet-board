#!/usr/bin/env bash
# Card 253: fb_lock and fl_lock_next decide a lock is stale by owner liveness (pid), not by mtime.
set -u
unset CDPATH
HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/../scripts"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

for f in "$S/board-lib.sh" "$S/adapters/local/local-lib.sh"; do
  n=$(grep -c "mmin" "$f")
  if [ "$n" = 0 ]; then ok "$(basename "$f") has no mmin mtime check"; else bad "$(basename "$f") still has $n mmin check(s)"; fi
done

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export FLEET_ROOT="$T" FLEET_BOARD_LOCK_WAIT=2
# run <lockdir-setup> <snippet>: runs fb_lock / fl_lock_next in a fresh shell
run_fb() { ( . "$S/board-lib.sh"; fb_cfg() { case "$1" in worktrees.dir) echo wt ;; board.dir) echo bd ;; esac; }
  fb_lock 1 && echo acquired ) 2>&1; }
run_fl() { ( . "$S/board-lib.sh"; . "$S/adapters/local/local-lib.sh"; fb_cfg() { case "$1" in worktrees.dir) echo wt ;; board.dir) echo bd ;; esac; }
  fl_lock_next && echo acquired ) 2>&1; }

dead_pid() { ( exit 0 ) & local p=$!; wait "$p"; echo "$p"; }

mkdir -p "$T/wt/.locks" "$T/bd"
FB="$T/wt/.locks/card-1.lock"; FL="$T/bd/.next.lock"

# dead owner, fresh mtime: taken over
for kind in fb fl; do
  lock=$FB; [ $kind = fl ] && lock=$FL
  mkdir -p "$lock"; dead_pid > "$lock/pid"
  out=$(run_$kind)
  case "$out" in *acquired*) ok "$kind: lock of a dead owner is taken over even when fresh" ;; *) bad "$kind: dead owner's lock not taken over: $out" ;; esac
  rm -rf "$lock"
done

# live owner, old mtime: not taken over
for kind in fb fl; do
  lock=$FB; [ $kind = fl ] && lock=$FL
  mkdir -p "$lock"; sleep 30 & lp=$!; echo "$lp" > "$lock/pid"; touch -t 200001010000 "$lock"
  out=$(run_$kind)
  case "$out" in *acquired*) bad "$kind: live owner's old lock was taken over" ;; *) ok "$kind: lock of a live owner is kept despite old mtime" ;; esac
  kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null; rm -rf "$lock"
done

# fl_lock_next records the owner pid
( . "$S/board-lib.sh"; . "$S/adapters/local/local-lib.sh"; fb_cfg() { case "$1" in board.dir) echo bd ;; esac; }
  fl_lock_next; [ -s "$FL/pid" ] ) && ok "fl_lock_next writes an owner pid file" || bad "fl_lock_next writes no pid file"
rm -rf "$FL"
exit $fail
