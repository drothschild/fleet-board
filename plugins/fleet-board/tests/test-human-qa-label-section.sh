#!/usr/bin/env bash
#
# Plain-bash tests: applying the needs-human-qa label adds a "## Human QA"
# section to the card body (label.sh, board-create.sh --label).
#
# Usage: bash plugins/fleet-board/tests/test-human-qa-label-section.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPTS="$SCRIPT_DIR/../scripts"
unset FLEET_BOARD_CONFIG FLEET_BOARD_USER FLEET_BOARD_LOCK_WAIT || true

PASS=0
FAIL=0
CLEANUP_DIRS=()
cleanup() { for d in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do rm -rf "$d" 2>/dev/null || true; done; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

NOGH_DIR="$(mktemp -d)"
CLEANUP_DIRS+=("$NOGH_DIR")
printf '#!/bin/sh\necho "gh must not be called: $*" >&2\nexit 99\n' > "$NOGH_DIR/gh"
chmod +x "$NOGH_DIR/gh"
PATH="$NOGH_DIR:$PATH"

setup_case() {
  REPO="$(mktemp -d)"
  CLEANUP_DIRS+=("$REPO")
  git init -q "$REPO"
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test User"
  printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\n' > "$REPO/.fleet-board.yml"
  git -C "$REPO" add .fleet-board.yml
  git -C "$REPO" commit -q -m initial
  mkdir -p "$REPO/.fleet-board/cards"
  echo 1 > "$REPO/.fleet-board/next"
}

seed_card() { # n body [labels-json]
  jq -n --argjson n "$1" --arg b "$2" --argjson l "${3:-[]}" \
    '{number: $n, title: "T", body: $b, state: "ready", labels: $l, next_comment_id: 1, comments: [], created_at: "2026-01-01T00:00:00Z"}' \
    > "$REPO/.fleet-board/cards/$1.json"
}

body_of() { jq -r '.body' "$REPO/.fleet-board/cards/$1.json"; }
raw_body_of() { jq -r ".body | @json" "$REPO/.fleet-board/cards/$1.json"; }
enc() { jq -nr --arg s "$1" "\$s | @json"; }

in_repo() { ( unset CDPATH; cd "$REPO" && "$@" ) >/dev/null 2>&1; }

PROSE=$'## Why\nBecause.\n'
QA_BODY=$'## Why\nBecause.\n\n## Human QA\n- open the page and look\n'

echo "Applying the needs-human-qa label with label.sh to a card whose body has no QA section appends an empty QA section heading to the body"
setup_case
seed_card 1 "$PROSE"
in_repo bash "$SCRIPTS/adapters/local/label.sh" 1 add needs-human-qa
got="$(raw_body_of 1)"
want=$'## Why\nBecause.\n\n## Human QA\n'
if [ "$got" = "$(enc "$want")" ]; then pass "label.sh add appends an empty QA heading"; else fail "label.sh add appends an empty QA heading" "got: $(printf '%s' "$got" | jq -Rs .)"; fi

echo "board-create.sh --label needs-human-qa with a body that has no QA section creates a card whose body ends with the QA section heading"
setup_case
printf '## Why\nBecause.\n' > "$REPO/body.md"
( unset CDPATH; cd "$REPO" && bash "$SCRIPTS/board-create.sh" Made "$REPO/body.md" --label needs-human-qa ) >/dev/null 2>&1
last="$(body_of 1 | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' | tail -n 1)"
if [ "$last" = "## Human QA" ]; then pass "board-create.sh --label needs-human-qa ends the body with the QA heading"; else fail "board-create.sh --label needs-human-qa ends the body with the QA heading" "last line: '$last'"; fi

echo "Applying the label to a card whose body already has a QA section with bullets leaves the body unchanged"
setup_case
seed_card 1 "$QA_BODY"
in_repo bash "$SCRIPTS/adapters/local/label.sh" 1 add needs-human-qa
got="$(raw_body_of 1)"
if [ "$got" = "$(enc "$QA_BODY")" ]; then pass "existing QA section with bullets leaves the body unchanged"; else fail "existing QA section with bullets leaves the body unchanged" "got: $(printf '%s' "$got" | jq -Rs .)"; fi

echo "Applying any other label leaves the body unchanged"
setup_case
seed_card 1 "$PROSE"
in_repo bash "$SCRIPTS/adapters/local/label.sh" 1 add bug
got="$(raw_body_of 1)"
if [ "$got" = "$(enc "$PROSE")" ]; then pass "other label leaves the body unchanged"; else fail "other label leaves the body unchanged" "got: $(printf '%s' "$got" | jq -Rs .)"; fi

echo "Removing the needs-human-qa label leaves the QA section in the body"
setup_case
seed_card 1 "$PROSE"
in_repo bash "$SCRIPTS/adapters/local/label.sh" 1 add needs-human-qa
in_repo bash "$SCRIPTS/adapters/local/label.sh" 1 remove needs-human-qa
got="$(raw_body_of 1)"
labels="$(jq -c '.labels' "$REPO/.fleet-board/cards/1.json")"
want=$'## Why\nBecause.\n\n## Human QA\n'
if [ "$got" = "$(enc "$want")" ] && [ "$labels" = "[]" ]; then pass "removing the label leaves the QA section"; else fail "removing the label leaves the QA section" "labels $labels body: $(printf '%s' "$got" | jq -Rs .)"; fi

echo "A card with a QA section and no needs-human-qa label makes needs-human-qa.sh report false, unless a human_qa_paths glob matches"
setup_case
seed_card 1 "$QA_BODY"
out="$( cd "$REPO" && bash "$SCRIPTS/needs-human-qa.sh" 1 5 2>/dev/null )"
if [ "$out" = false ]; then pass "QA section alone reports false"; else fail "QA section alone reports false" "got: '$out'"; fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
