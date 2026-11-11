#!/usr/bin/env bash
# Card 228: the version-guidance suites must not assert anything about the current branch's diff.
set -u
unset CDPATH
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }
S1=plugins/fleet-board/tests/test-repo-version-guidance.sh
S2=plugins/fleet-board/tests/test-repo-version-guidance-strict.sh

# Acceptance 1: the Acceptance 3 diff block is gone from both suites.
for s in "$S1" "$S2"; do
  if grep -Eq 'shipped files changed|diff --name-only' "$ROOT/$s"; then
    bad "$s still asserts on the branch diff against origin/main"
  else
    ok "$s has no branch-diff assertion"
  fi
done

# Acceptance 3: on a scratch branch changing a file under scripts/, neither suite prints "not ok".
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
git clone -q "$ROOT" "$T/c" 2>/dev/null
g() { git -C "$T/c" -c user.email=t@t -c user.name=t "$@"; }
g remote remove origin
g update-ref refs/remotes/origin/main HEAD
g checkout -q -b scratch
echo "# scratch change" >> "$T/c/plugins/fleet-board/scripts/board-comment.sh"
g commit -qam "scratch change under scripts"
for s in "$S1" "$S2"; do
  out=$(cd "$T/c" && bash "$s" 2>&1)
  n=$(printf '%s\n' "$out" | grep -c '^not ok')
  if [ "$n" = 0 ]; then ok "$s prints no not ok on a branch changing scripts/"; else bad "$s printed $n not ok on a branch changing scripts/"; fi
done
exit $fail
