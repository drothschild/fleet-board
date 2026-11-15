#!/usr/bin/env bash
#
# Plain-bash tests: edit.sh sets a card's repo.
# Usage: bash plugins/fleet-board/tests/test-edit-sets-card-repo.sh

set -uo pipefail
unset CDPATH FLEET_BOARD_CONFIG || true
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
EDIT="$SCRIPT_DIR/../scripts/adapters/local/edit.sh"

FAILS=0
ok() { echo "ok - $1"; }
bad() { echo "FAIL - $1: $2"; FAILS=$((FAILS + 1)); }

# Acceptance: grep -c -- --repo edit.sh gives at least 1
n="$(grep -c -- --repo "$EDIT")"
if [ "$n" -ge 1 ]; then ok "grep -c -- --repo edit.sh gives at least 1"; else bad "grep -c -- --repo edit.sh gives at least 1" "got $n"; fi

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

(cd "$REPO" && bash "$EDIT" 1 --repo a/b >/dev/null 2>&1)
got="$(jq -r '.repo // "unset"' "$REPO/.fleet-board/cards/1.json")"
if [ "$got" = "a/b" ]; then ok "edit.sh --repo sets the card repo"; else bad "edit.sh --repo sets the card repo" "repo is $got"; fi

out="$(cd "$REPO" && bash "$EDIT" 1 --repo nope/unlisted 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then ok "edit.sh --repo rejects a repo not in board.repos"; else bad "edit.sh --repo rejects a repo not in board.repos" "exit $rc: $out"; fi
got="$(jq -r '.repo // "unset"' "$REPO/.fleet-board/cards/1.json")"
[ "$got" = "a/b" ] || bad "a rejected repo leaves the card repo unchanged" "repo is $got"

(cd "$REPO" && bash "$EDIT" 1 --title-file /dev/null >/dev/null 2>&1)
got="$(jq -r '.repo // "unset"' "$REPO/.fleet-board/cards/1.json")"
if [ "$got" = "a/b" ]; then ok "an edit without --repo leaves the card repo unchanged"; else bad "an edit without --repo leaves the card repo unchanged" "repo is $got"; fi

(cd "$REPO" && bash "$EDIT" 1 --repo "" >/dev/null 2>&1)
got="$(jq -r '.repo // "unset"' "$REPO/.fleet-board/cards/1.json")"
if [ "$got" = "unset" ]; then ok "edit.sh --repo with an empty value clears the card repo"; else bad "edit.sh --repo with an empty value clears the card repo" "repo is $got"; fi

[ "$FAILS" -eq 0 ] || exit 1
echo "all passed"
