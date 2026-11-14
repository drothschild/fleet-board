#!/usr/bin/env bash
# Card 385: stack-bridge.sh joins a child branch to its parent's squash commit on real git.
# Temp repos only: no network, no gh.
set -u
unset CDPATH
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/stack-bridge.sh"
REAL_GIT="$(command -v git)"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }
check() { # check <name> <command...>
  local name="$1"; shift
  if "$@"; then ok "$name"; else bad "$name"; fi
}

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

g() { git -C "$R" "$@"; }

# Build a repo in $R: main with a.txt (10 lines), parent branch changing line 1 to P,
# child cut from the parent changing line 1 to C. Variants set before squash via hooks
# named by $1 (space separated words): later-parent, main-b, main-line5.
# Leaves HEAD on the child, parent head in $PH, squash sha in $SQ.
build() {
  local variant="$1" i
  R="$T/repo-$2"
  mkdir -p "$R"
  git init -q -b main "$R"
  for i in 1 2 3 4 5 6 7 8 9 10; do echo "line $i"; done > "$R/a.txt"
  g add a.txt; g commit -q -m base
  g checkout -q -b parent
  sed -i.bak '1s/.*/P/' "$R/a.txt"; rm -f "$R/a.txt.bak"
  g commit -q -am "parent change"
  g checkout -q -b child
  sed -i.bak '1s/.*/C/' "$R/a.txt"; rm -f "$R/a.txt.bak"
  g commit -q -am "child change"
  case " $variant " in
    *" later-parent "*)
      g checkout -q parent
      sed -i.bak '3s/.*/Q/' "$R/a.txt"; rm -f "$R/a.txt.bak"
      g commit -q -am "parent later"
      g checkout -q child
      g merge -q --no-edit parent >/dev/null 2>&1 || { g checkout -q --theirs a.txt 2>/dev/null; }
      # resolve to a deterministic child tree: line1 C, line3 Q
      for i in 1 2 3 4 5 6 7 8 9 10; do echo "line $i"; done > "$R/a.txt"
      sed -i.bak -e '1s/.*/C/' -e '3s/.*/Q/' "$R/a.txt"; rm -f "$R/a.txt.bak"
      g add a.txt; g commit -q -m "child merges parent" 2>/dev/null || true
      ;;
  esac
  PH="$(g rev-parse parent)"
  g checkout -q main
  case " $variant " in
    *" main-b "*) echo b > "$R/b.txt"; g add b.txt; g commit -q -m "main adds b" ;;
  esac
  case " $variant " in
    *" main-line5 "*)
      sed -i.bak '5s/.*/M5/' "$R/a.txt"; rm -f "$R/a.txt.bak"
      g commit -q -am "main line 5" ;;
  esac
  g merge -q --squash parent >/dev/null 2>&1
  g commit -q -m "squash parent"
  SQ="$(g rev-parse HEAD)"
  g checkout -q child
  # when the child changed line 5 too
  case " $variant " in
    *" main-line5 "*)
      sed -i.bak '5s/.*/C5/' "$R/a.txt"; rm -f "$R/a.txt.bak"
      g commit -q -am "child line 5" ;;
  esac
}

line() { sed -n "$2p" "$1"; }

# 1. fixture: plain merge of main conflicts
build "" basic
g merge --no-edit main >/dev/null 2>&1; rc=$?
g merge --abort >/dev/null 2>&1
check "fixture: a plain git merge main on the child exits non-zero" test "$rc" -ne 0

# 2. commit joins the child to the squash
before="$(g rev-parse HEAD)"
out="$(bash "$SCRIPT" commit "$R" "$PH" "$SQ" 2>"$T/err")"; rc=$?
check "commit exits 0 on the squash fixture" test "$rc" -eq 0
check "a.txt line 1 is C after commit" test "$(line "$R/a.txt" 1)" = C
check "commit prints the new head" test "$out" = "$(g rev-parse HEAD)"
check "the new commit has the old head first and the squash second" \
  test "$(g rev-parse HEAD^1 HEAD^2 | tr '\n' ' ')" = "$before $SQ "
check "the new commit has exactly two parents" test "$(g rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" = 3
msg="$(g log -1 --format=%s)"
check "bridge commit message names parent head and squash" \
  test "$msg" = "Bridge to the squash of $(g rev-parse --short "$PH") ($(g rev-parse --short "$SQ"))"
g merge main 2>&1 | grep -q "Already up to date"
check "git merge main afterwards reports already up to date" test "$?" -eq 0

# 7. second commit is idempotent
head1="$(g rev-parse HEAD)"; cnt1="$(g rev-list --count HEAD)"
out2="$(bash "$SCRIPT" commit "$R" "$PH" "$SQ" 2>/dev/null)"; rc=$?
check "a second commit exits 0" test "$rc" -eq 0
check "a second commit prints the same head" test "$out2" = "$head1"
check "a second commit adds no commit" test "$(g rev-list --count HEAD)" = "$cnt1"

# 10. tree prints the tree of the commit that commit made
build "" treeeq
htree_before="$(g rev-parse 'HEAD^{tree}')"; ours="$(g rev-parse HEAD)"
tout="$(bash "$SCRIPT" tree "$R" "$PH" "$ours" "$SQ" 2>/dev/null)"; trc=$?
bash "$SCRIPT" commit "$R" "$PH" "$SQ" >/dev/null 2>&1
check "tree exits 0 on the same inputs" test "$trc" -eq 0
check "tree prints the tree of the commit that commit made" test "$tout" = "$(g rev-parse 'HEAD^{tree}')"

# 3. child had merged a later parent commit before the squash
build "later-parent" later
tree_before="$(g rev-parse 'HEAD^{tree}')"
out="$(bash "$SCRIPT" commit "$R" "$PH" "$SQ" 2>/dev/null)"; rc=$?
check "commit exits 0 after the child merged a later parent commit" test "$rc" -eq 0
check "the tree equals the child's tree before the bridge" test "$(g rev-parse 'HEAD^{tree}')" = "$tree_before"

# 4. main gained b.txt before the squash
build "main-b" mainb
out="$(bash "$SCRIPT" commit "$R" "$PH" "$SQ" 2>/dev/null)"; rc=$?
check "commit exits 0 when main gained b.txt" test "$rc" -eq 0
check "b.txt exists after commit" test -f "$R/b.txt"
check "a.txt line 1 is still C when main gained b.txt" test "$(line "$R/a.txt" 1)" = C

# 5. conflict on line 5
build "main-line5" conflict
head_before="$(g rev-parse HEAD)"; sum_before="$(cat "$R/a.txt")"
out="$(bash "$SCRIPT" commit "$R" "$PH" "$SQ" 2>/dev/null)"; rc=$?
check "commit exits 3 on a line 5 conflict" test "$rc" -eq 3
check "commit prints the conflicted path a.txt" test "$out" = "a.txt"
check "HEAD is unchanged after a conflict" test "$(g rev-parse HEAD)" = "$head_before"
check "the working tree is unchanged after a conflict" test "$(cat "$R/a.txt")" = "$sum_before"
check "the working tree is clean after a conflict" test -z "$(g status --porcelain)"

# 6. parent head not an ancestor of HEAD
build "" notanc
head_before="$(g rev-parse HEAD)"
bash "$SCRIPT" commit "$R" "$SQ" "$SQ" >/dev/null 2>&1; rc=$?
check "commit exits 1 when the parent head is not an ancestor of HEAD" test "$rc" -eq 1
check "nothing changes when the parent head is not an ancestor" test "$(g rev-parse HEAD)" = "$head_before"

# 7. dirty tracked file
build "" dirty
head_before="$(g rev-parse HEAD)"
echo dirty >> "$R/a.txt"
bash "$SCRIPT" commit "$R" "$PH" "$SQ" >/dev/null 2>&1; rc=$?
check "commit exits 1 when a tracked file has changes" test "$rc" -eq 1
check "nothing changes when a tracked file has changes" \
  test "$(g rev-parse HEAD)" = "$head_before" -a "$(tail -1 "$R/a.txt")" = dirty

# 9. old git
build "" oldgit
head_before="$(g rev-parse HEAD)"
mkdir -p "$T/stub"
{
  echo '#!/bin/sh'
  echo 'if [ "$1" = "--version" ] || [ "$1" = "version" ]; then echo "git version 2.39.5"; exit 0; fi'
  echo "exec $REAL_GIT \"\$@\""
} > "$T/stub/git"
chmod +x "$T/stub/git"
PATH="$T/stub:$PATH" bash "$SCRIPT" commit "$R" "$PH" "$SQ" >"$T/o" 2>"$T/e"; rc=$?
check "commit exits 4 with git 2.39.5" test "$rc" -eq 4
check "stderr says stacking needs git 2.40 or later" grep -q "stacking needs git 2.40 or later" "$T/e"
check "nothing changes with old git" test "$(g rev-parse HEAD)" = "$head_before"

# usage
bash "$SCRIPT" >/dev/null 2>&1; rc=$?
check "no arguments exits 2" test "$rc" -eq 2

exit $fail
