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

# --- Concurrent takeover (C/D interleaving) ---------------------------------------
# Waiter B finds a dead owner's lock. Right after B's liveness check says "dead",
# process C takes the lock over and holds it (injected through a ps override in B).
# If B then moves the lock dir, process D is started at that point (an mv override in
# B), so it can mkdir the lock while it is moved away. At most one process may hold
# the lock at any time: the lock's pid names the one live holder and no lock dir
# is nested inside it. Every contender is its own bash process (the owner id is $$).
# The overrides exist only in B's process; the library carries no test hook.
W="$T/w"; mkdir -p "$W"
cat > "$W/common.sh" <<'SH'
. "$S/board-lib.sh"; . "$S/adapters/local/local-lib.sh"
fb_cfg() { case "$1" in worktrees.dir) echo wt ;; board.dir) echo bd ;; esac; }
take() { if [ "$KIND" = fb ]; then fb_lock 1; else fl_lock_next; fi; }
hold() {  # records this process as a holder, then holds until the test releases
  : > "$HELD/$$"; i=0
  while [ ! -e "$HELD/../release" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ "$KIND" = fl ] && fl_unlock_next; exit 0
}
start_holder() {  # start_holder <name>: a plain contender in its own process
  bash "$W/holder.sh" >"$HELD/../$1.log" 2>&1 & echo $! > "$HELD/../$1.pid"
}
wait_for_holders() {  # wait_for_holders <n> <tenths>
  i=0; while [ "$(ls "$HELD" | wc -l | tr -d ' ')" -lt "$1" ] && [ $i -lt "$2" ]; do sleep 0.1; i=$((i + 1)); done
}
SH
cat > "$W/holder.sh" <<'SH'
. "$W/common.sh"; take && hold
SH
cat > "$W/taker.sh" <<'SH'
. "$W/common.sh"
# C is injected right after B's first liveness check of the dead pid, whether the
# library asks ps or kill.
inject_C() {
  if [ ! -e "$HELD/../inj.C" ]; then : > "$HELD/../inj.C"; start_holder C; wait_for_holders 1 30; fi
}
ps() { command ps "$@"; local r=$?; [ "$*" = "-p $DEAD" ] && inject_C; return $r; }
kill() { builtin kill "$@"; local r=$?; [ "$*" = "-0 $DEAD" ] && inject_C; return $r; }
mv() {
  command mv "$@"; local r=$?
  if [ "$1" = "$LOCK" ] && [ ! -e "$HELD/../inj.D" ]; then
    : > "$HELD/../inj.D"; start_holder D; wait_for_holders 2 15
  fi
  return $r
}
take && hold
SH

race() {  # race <kind>: runs the interleaving, then asserts a single holder
  local kind="$1" lock R n live holder p nested
  lock=$FB; [ "$kind" = fl ] && lock=$FL
  R="$T/race-$kind"; rm -rf "$R"; mkdir -p "$R/held"
  mkdir -p "$lock"; dead_pid > "$lock/pid"
  ( export S W KIND="$kind" LOCK="$lock" HELD="$R/held" DEAD="$(cat "$lock/pid")" FLEET_BOARD_LOCK_WAIT=1
    bash "$W/taker.sh" >"$R/B.log" 2>&1 & echo $! > "$R/B.pid"; wait
    # D contends too even when B never moved the lock dir
    [ -e "$R/inj.D" ] || { . "$W/common.sh"; start_holder D; sleep 1.5; } )
  live=0; holder=""
  for p in $(ls "$R/held"); do
    if command ps -p "$p" >/dev/null 2>&1; then live=$((live + 1)); holder="$holder $p"; fi
  done
  holder="${holder# }"
  nested=$(find "$lock" -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  if [ "$live" = 1 ] && [ "$(cat "$lock/pid" 2>/dev/null)" = "$holder" ] && [ "$nested" = 0 ]; then
    ok "$kind: concurrent stale takeover leaves exactly one holder"
  else
    bad "$kind: concurrent stale takeover: $live live holder(s) [$holder], lock pid $(cat "$lock/pid" 2>/dev/null), $nested nested dir(s)"
  fi
  : > "$R/release"
  for n in B C D; do [ -f "$R/$n.pid" ] && kill "$(cat "$R/$n.pid")" 2>/dev/null; done
  sleep 0.2; rm -rf "$lock" "$lock".*
}
race fb
race fl

# A taker that has claimed a dead lock and is still running is not overtaken
for kind in fb fl; do
  lock=$FB; [ $kind = fl ] && lock=$FL
  mkdir -p "$lock"; dead_pid > "$lock/pid"; sleep 30 & lp=$!; ln -s "$lp" "$lock/claim.1"
  out=$(FLEET_BOARD_LOCK_WAIT=1 run_$kind)
  case "$out" in *acquired*) bad "$kind: a lock claimed by a live taker was taken over" ;; *) ok "$kind: a lock claimed by a live taker is left to that taker" ;; esac
  kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null; rm -rf "$lock"
done

# A claim left by a taker that died does not wedge the lock
for kind in fb fl; do
  lock=$FB; [ $kind = fl ] && lock=$FL
  mkdir -p "$lock"; dead_pid > "$lock/pid"; ln -s "$(dead_pid)" "$lock/claim.1"
  out=$(run_$kind)
  case "$out" in *acquired*) ok "$kind: a dead lock with a dead taker's claim is taken over" ;; *) bad "$kind: a dead taker's claim wedged the lock: $out" ;; esac
  rm -rf "$lock"
done

# --- Fix round 1 -----------------------------------------------------------------

# A release racing a late claim. B reads the dead pid, then pauses. T takes the stale
# lock over and releases it; T's rm -rf is split at its unlink/rmdir boundary (an rm
# override in T, applied to the lock path and to any private release name) and B's
# claim ln runs in between. The lock must not be left behind as a pid-less dir: a
# later waiter takes it.
cat > "$W/taker2.sh" <<'SH'
. "$W/common.sh"
pause() {
  if [ ! -e "$HELD/../b.paused" ]; then
    : > "$HELD/../b.paused"; i=0
    while [ ! -e "$HELD/../t.unlinked" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  fi
}
ps() { command ps "$@"; local r=$?; [ "$*" = "-p $DEAD" ] && pause; return $r; }
kill() { builtin kill "$@"; local r=$?; [ "$*" = "-0 $DEAD" ] && pause; return $r; }
ln() { command ln "$@"; local r=$?; : > "$HELD/../b.linked"; return $r; }
take && hold
SH
cat > "$W/releaser.sh" <<'SH'
. "$W/common.sh"
rm() {
  if [ "$1" = -rf ] && [ ! -e "$HELD/../t.unlinked" ]; then
    case "$2" in
      "$LOCK"|"$LOCK".rel.*)
        [ -d "$2" ] || return 0
        command rm -f "$2"/pid "$2"/.pid.* "$2"/claim.*; : > "$HELD/../t.unlinked"; i=0
        while [ ! -e "$HELD/../b.linked" ] && [ $i -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
        command rmdir "$2"; return ;;
    esac
  fi
  command rm "$@"
}
take && hold
SH
release_race() {
  local kind="$1" lock R out i
  lock=$FB; [ "$kind" = fl ] && lock=$FL
  R="$T/rel-$kind"; rm -rf "$R"; mkdir -p "$R/held"
  mkdir -p "$lock"; dead_pid > "$lock/pid"
  ( export S W KIND="$kind" LOCK="$lock" HELD="$R/held" DEAD="$(cat "$lock/pid")" FLEET_BOARD_LOCK_WAIT=2
    bash "$W/taker2.sh" >"$R/B.log" 2>&1 & bp=$!
    i=0; while [ ! -e "$R/b.paused" ] && [ $i -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
    : > "$R/release"                     # T releases as soon as it holds
    bash "$W/releaser.sh" >"$R/T.log" 2>&1
    wait "$bp" )
  out=$(FLEET_BOARD_LOCK_WAIT=1 run_$kind)
  case "$out" in
    *acquired*) ok "$kind: a release racing a late claim leaves the lock takeable" ;;
    *) bad "$kind: a release racing a late claim wedged the lock (left: $(ls -A "$lock" 2>/dev/null | tr '\n' ' ')): $out" ;;
  esac
  rm -rf "$lock" "$lock".*
}
release_race fb
release_race fl

# An unusable ps (missing, BusyBox, sandboxed) must not make a live owner look dead
FAKE="$T/fakebin"; mkdir -p "$FAKE"; printf '#!/bin/sh\nexit 2\n' > "$FAKE/ps"; chmod +x "$FAKE/ps"
for kind in fb fl; do
  lock=$FB; [ $kind = fl ] && lock=$FL
  R="$T/ps-$kind"; rm -rf "$R"; mkdir -p "$R/held"
  ( export S W KIND="$kind" HELD="$R/held"; bash "$W/holder.sh" >"$R/H.log" 2>&1 & echo $! > "$R/H.pid"
    . "$W/common.sh"; wait_for_holders 1 30 )
  out=$(PATH="$FAKE:$PATH" FLEET_BOARD_LOCK_WAIT=1 run_$kind)
  case "$out" in *acquired*) bad "$kind: a waiter with an unusable ps took a live owner's lock" ;; *) ok "$kind: a waiter with an unusable ps leaves a live owner's lock alone" ;; esac
  : > "$R/release"; kill "$(cat "$R/H.pid")" 2>/dev/null; sleep 0.2; rm -rf "$lock"
done

# Card #254: a lock with no pid file (its creator crashed between mkdir and the pid
# write) is not taken while younger than the pid-less grace, and is taken once older.
# The grace is measured from the lock's first claim link (the dir's own mtime moves
# with every claim), so a fresh lock is kept for the whole grace and a crashed lock
# whose first claim is already old is taken at once.
for kind in fb fl; do
  lock=$FB; [ $kind = fl ] && lock=$FL
  mkdir -p "$lock"
  out=$(FLEET_BOARD_LOCK_PIDLESS_GRACE=60 FLEET_BOARD_LOCK_WAIT=1 run_$kind)
  case "$out" in *acquired*) bad "$kind: a pid-less lock younger than the grace was taken over" ;; *) ok "$kind: a pid-less lock younger than the grace is not taken" ;; esac
  rm -rf "$lock" "$lock".*
  mkdir -p "$lock"
  out=$(FLEET_BOARD_LOCK_PIDLESS_GRACE=1 FLEET_BOARD_LOCK_WAIT=6 run_$kind)
  left=$(ls -d "$lock".* 2>/dev/null | wc -l | tr -d ' ')
  case "$out" in
    *acquired*) [ "$left" = 0 ] && ok "$kind: a pid-less lock older than the grace is taken over" \
                  || bad "$kind: pid-less takeover left $left renamed copies" ;;
    *) bad "$kind: a pid-less lock older than the grace was not taken over: $out" ;;
  esac
  rm -rf "$lock" "$lock".*
  mkdir -p "$lock"; ln -s "$(dead_pid)" "$lock/claim.1"; touch -h -t 200001010000 "$lock/claim.1"
  out=$(FLEET_BOARD_LOCK_PIDLESS_GRACE=60 FLEET_BOARD_LOCK_WAIT=2 run_$kind)
  case "$out" in *acquired*) ok "$kind: a pid-less lock whose first claim is older than the grace is taken at once" ;; *) bad "$kind: a pid-less lock with an old dead claim was not taken: $out" ;; esac
  rm -rf "$lock" "$lock".*
done

# A failed pid write removes the lock only while the lock is still ours
L1="$T/pidw.lock"
( . "$S/board-lib.sh"
  printf() { if [ "$1" = '%s\n' ] && [ "$2" = "$$" ]; then command rm -rf "$L1"; mkdir "$L1"; echo other > "$L1/pid"; return 1; fi; builtin printf "$@"; }
  fb_lock_acquire "$L1" 1 ) >/dev/null 2>&1
if [ "$(cat "$L1/pid" 2>/dev/null)" = other ]; then ok "a failed pid write leaves a lock that is no longer ours"; else bad "a failed pid write removed a lock that was not ours"; fi
rm -rf "$L1"
( . "$S/board-lib.sh"
  mv() { case "$*" in *"$L1/pid") return 1 ;; esac; command mv "$@"; }
  ln() { case "$*" in *"$L1/pid") return 1 ;; esac; command ln "$@"; }
  fb_lock_acquire "$L1" 1 ) >/dev/null 2>&1; r=$?
if [ "$r" != 0 ] && [ ! -e "$L1" ]; then ok "a failed pid rename fails and removes our own lock"; else bad "a failed pid rename: exit $r, lock left: $([ -e "$L1" ] && echo yes || echo no)"; fi
rm -rf "$L1" "$L1".*

# --- Fix round 2 -----------------------------------------------------------------

# The temp pid write itself fails (ENOSPC, EROFS, EACCES): our own pid-less lock
# must not be left behind, and the next waiter takes the lock.
L2="$T/pidw2.lock"
( . "$S/board-lib.sh"
  printf() { if [ "$1" = '%s\n' ] && [ "$2" = "$$" ]; then return 1; fi; builtin printf "$@"; }
  fb_lock_acquire "$L2" 1 ) >/dev/null 2>&1; r=$?
if [ "$r" != 0 ] && [ ! -e "$L2" ]; then ok "a failed temp pid write fails and leaves no pid-less lock"; else bad "a failed temp pid write: exit $r, left at the lock path: [$(ls -A "$L2" 2>/dev/null | tr '\n' ' ')] exists=$([ -d "$L2" ] && echo yes || echo no)"; fi
out=$( ( . "$S/board-lib.sh"; fb_lock_acquire "$L2" 1 && echo acquired ) 2>&1 )
case "$out" in *acquired*) ok "after a failed temp pid write the next waiter takes the lock" ;; *) bad "after a failed temp pid write the lock is wedged: $out" ;; esac
rm -rf "$L2" "$L2".*

# Release leaves a lock whose pid names another live process
L3="$T/rel3.lock"; mkdir -p "$L3"; sleep 30 & lp=$!; echo "$lp" > "$L3/pid"
( . "$S/board-lib.sh"; fb_lock_release "$L3" ) >/dev/null 2>&1
if [ "$(cat "$L3/pid" 2>/dev/null)" = "$lp" ]; then ok "release leaves a lock that another live process holds"; else bad "release removed a lock held by another live process"; fi
kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null; rm -rf "$L3" "$L3".*

# A live owner this process cannot signal (pid 1: kill -0 gives EPERM) is alive
if [ "$(id -u)" = 0 ]; then
  echo "ok - # skip EPERM owner test: running as root, so kill -0 1 succeeds and cannot show EPERM"
else
  for kind in fb fl; do
    lock=$FB; [ $kind = fl ] && lock=$FL
    mkdir -p "$lock"; echo 1 > "$lock/pid"
    out=$(FLEET_BOARD_LOCK_WAIT=1 run_$kind)
    case "$out" in *acquired*) bad "$kind: a lock owned by a live process we cannot signal (EPERM) was taken over" ;; *) ok "$kind: a lock owned by a live process we cannot signal (EPERM) is kept" ;; esac
    rm -rf "$lock"
  done
fi
# --- Card #254: a slow but live owner and the pid-less grace ------------------------

# One grace for both sides: board-lib.sh's takeover and stuck.py's dead_lock / release.
bg=$(sed -n 's/^FB_LOCK_PIDLESS_GRACE=\([0-9][0-9]*\).*/\1/p' "$S/board-lib.sh")
pg=$(sed -n 's/^LOCK_GRACE = \([0-9][0-9]*\).*/\1/p' "$S/supervisor/stuck.py")
if [ -n "$bg" ] && [ "$bg" = "$pg" ]; then ok "board-lib.sh and stuck.py share one pid-less grace (${bg}s)"
else bad "pid-less grace differs: board-lib.sh '${bg}', stuck.py '${pg}'"; fi

# P is a live owner that stalls right after its mkdir (an mkdir override in P's own
# process), so its lock stays pid-less. W, a waiter, takes the lock over once it is
# older than the grace. P's pid write is let through only at a chosen point:
#   after  - once W holds the lock it re-made (the reviewer's late pid rename);
#   ln, mv - while W is inside its takeover: just before W writes its pid into the
#            pid-less lock (ln), or just before W renames that lock aside (mv).
# Every case must end with exactly one live holder, named by the lock's pid.
cat > "$W/slow.sh" <<'SH'
. "$W/common.sh"
mkdir() {
  command mkdir "$@"; local r=$? i=0
  if [ $r = 0 ] && [ "$1" = "$LOCK" ] && [ ! -e "$HELD/../p.stalled" ]; then
    : > "$HELD/../p.stalled"
    while [ ! -e "$HELD/../p.go" ] && [ $i -lt 120 ]; do sleep 0.1; i=$((i + 1)); done
  fi
  return $r
}
placed() { case "$*" in *"$LOCK/pid") : > "$HELD/../p.placed" ;; esac; }
ln() { command ln "$@"; local r=$?; placed "$@"; return $r; }
mv() { command mv "$@"; local r=$?; placed "$@"; return $r; }
take && hold
SH
cat > "$W/waiter.sh" <<'SH'
. "$W/common.sh"
let_p() {
  local i=0
  [ -e "$HELD/../w.trig" ] && return 0
  : > "$HELD/../w.trig"; : > "$HELD/../p.go"
  while [ ! -e "$HELD/../p.placed" ] && [ $i -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
}
case "$TRIG" in
  ln) ln() { case "$*" in *"$LOCK/pid") let_p ;; esac; command ln "$@"; } ;;
  mv) mv() { [ "$1" = "$LOCK" ] && let_p; command mv "$@"; } ;;
esac
take && hold
SH
slow_owner() {  # slow_owner <kind> <after|ln|mv>
  local kind="$1" trig="$2" lock R i live holder p want when
  lock=$FB; [ "$kind" = fl ] && lock=$FL
  R="$T/slow-$kind-$trig"; rm -rf "$R"; mkdir -p "$R/held"
  ( export S W KIND="$kind" LOCK="$lock" HELD="$R/held" TRIG="$trig" FLEET_BOARD_LOCK_PIDLESS_GRACE=1 FLEET_BOARD_LOCK_WAIT=8
    . "$W/common.sh"
    bash "$W/slow.sh" >"$R/P.log" 2>&1 & echo $! > "$R/P.pid"
    i=0; while [ ! -e "$R/p.stalled" ] && [ $i -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
    bash "$W/waiter.sh" >"$R/W.log" 2>&1 & echo $! > "$R/W.pid"
    if [ "$trig" = after ]; then
      wait_for_holders 1 80; : > "$R/p.go"
    else
      i=0; while [ ! -e "$R/w.trig" ] && [ $i -lt 80 ]; do sleep 0.1; i=$((i + 1)); done
      : > "$R/p.go"; wait_for_holders 1 80
    fi
    i=0; while [ ! -e "$R/p.placed" ] && [ $i -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
    wait_for_holders 2 10 )
  live=0; holder=""
  for p in $(ls "$R/held"); do
    if command ps -p "$p" >/dev/null 2>&1; then live=$((live + 1)); holder="$holder $p"; fi
  done
  holder="${holder# }"
  want="$(cat "$R/W.pid")"; [ "$trig" = ln ] && want="$(cat "$R/P.pid")"
  case "$trig" in
    after) when="after the waiter's grace takeover" ;;
    ln) when="just before the waiter writes its pid into the pid-less lock" ;;
    mv) when="just before the waiter renames the pid-less lock aside" ;;
  esac
  if [ "$live" = 1 ] && [ "$holder" = "$want" ] && [ "$(cat "$lock/pid" 2>/dev/null)" = "$holder" ]; then
    ok "$kind: a slow owner whose pid write lands $when leaves one holder"
  else
    bad "$kind: slow owner whose pid write lands $when: $live live holder(s) [$holder], want $want, lock pid $(cat "$lock/pid" 2>/dev/null)"
  fi
  : > "$R/release"
  for p in P W; do [ -f "$R/$p.pid" ] && kill "$(cat "$R/$p.pid")" 2>/dev/null; done
  sleep 0.2; rm -rf "$lock" "$lock".*
}
for kind in fb fl; do
  for trig in after ln mv; do slow_owner "$kind" "$trig"; done
done
exit $fail
