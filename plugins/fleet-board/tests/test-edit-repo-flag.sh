#!/usr/bin/env bash
#
# Plain-bash tests: edit.sh accepts --repo for a repo listed in board.repos
# instead of rejecting it as an unknown flag.
# Usage: bash plugins/fleet-board/tests/test-edit-repo-flag.sh

set -uo pipefail
unset CDPATH FLEET_BOARD_CONFIG || true
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
EDIT="$SCRIPT_DIR/../scripts/adapters/local/edit.sh"

FAILS=0
ok() { echo "ok - $1"; }
bad() { echo "FAIL - $1: $2"; FAILS=$((FAILS + 1)); }

REPO="$(mktemp -d)"
trap 'rm -rf "$REPO"' EXIT
git init -q "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name T
printf 'board:\n  repo: acme/toy\n  repos:\n    - repo: a/b\n      path: /abs/x\nworktrees:\n  dir: .fw\n' > "$REPO/.fleet-board.yml"
git -C "$REPO" add .fleet-board.yml
git -C "$REPO" commit -q -m initial
mkdir -p "$REPO/.fleet-board/cards"
echo 2 > "$REPO/.fleet-board/next"
printf '{"number":1,"title":"t","body":"x","labels":[],"acceptance":[],"blocked_by":[]}\n' > "$REPO/.fleet-board/cards/1.json"

out="$(cd "$REPO" && bash "$EDIT" 1 --repo a/b 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "edit.sh 1 --repo a/b exits 0 for a repo listed in board.repos"; else bad "edit.sh 1 --repo a/b exits 0 for a repo listed in board.repos" "exit $rc: $out"; fi
case "$out" in
  *usage:*) bad "--repo is not reported as a usage error" "$out" ;;
  *) ok "--repo is not reported as a usage error" ;;
esac

out="$(cd "$REPO" && bash "$EDIT" 1 --repo 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then ok "--repo without a value exits 2"; else bad "--repo without a value exits 2" "exit $rc: $out"; fi

[ "$FAILS" -eq 0 ] || exit 1
echo "all passed"
