#!/usr/bin/env bash
#
# Plain-bash tests: board-create.sh passes --repo through instead of rejecting it
# as an unknown argument.
# Usage: bash plugins/fleet-board/tests/test-board-create-repo-flag.sh

set -uo pipefail
unset CDPATH FLEET_BOARD_CONFIG || true
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CREATE="$SCRIPT_DIR/../scripts/board-create.sh"

FAILS=0
ok() { echo "ok - $1"; }
bad() { echo "FAIL - $1: $2"; FAILS=$((FAILS + 1)); }

REPO="$(mktemp -d)"
trap 'rm -rf "$REPO"' EXIT
git init -q "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name T
printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\n' > "$REPO/.fleet-board.yml"
git -C "$REPO" add .fleet-board.yml
git -C "$REPO" commit -q -m initial
mkdir -p "$REPO/.fleet-board/cards"
echo 1 > "$REPO/.fleet-board/next"
BODY="$REPO/body.md"
printf '## Why\nx\n' > "$BODY"

# board-create.sh passes --repo through: no usage error for the flag
out="$(cd "$REPO" && bash "$CREATE" t "$BODY" --repo a/b 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "board-create.sh with --repo a/b exits 0"; else bad "board-create.sh with --repo a/b exits 0" "exit $rc: $out"; fi
case "$out" in
  *usage:*|*"unknown argument"*) bad "--repo is not reported as a usage error or unknown argument" "$out" ;;
  *) ok "--repo is not reported as a usage error or unknown argument" ;;
esac

# the card is still created
if [ -f "$REPO/.fleet-board/cards/1.json" ]; then ok "the card is created when --repo is given"; else bad "the card is created when --repo is given" "no cards/1.json"; fi

# --repo without a value stays a usage error
out="$(cd "$REPO" && bash "$CREATE" t2 "$BODY" --repo 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then ok "--repo without a value exits 2"; else bad "--repo without a value exits 2" "exit $rc: $out"; fi

[ "$FAILS" -eq 0 ] || exit 1
echo "all passed"
