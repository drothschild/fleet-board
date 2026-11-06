#!/usr/bin/env bash
#
# Plain-bash tests for scripts/migrate-to-local.sh: saved board-read JSON from
# another backend becomes a local board store with the same numbers, states,
# comments and manager note.
#
# Usage: bash plugins/fleet-board/tests/test-migrate-to-local.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPTS="$SCRIPT_DIR/../scripts"
MIGRATE="$SCRIPTS/migrate-to-local.sh"

unset FLEET_BOARD_CONFIG FLEET_BOARD_LOCK_WAIT || true
export FLEET_BOARD_USER="localme"

PASS=0
FAIL=0
LAST_OUT=""
LAST_ERR=""
LAST_EXIT=0
CLEANUP_DIRS=()

if [ -x /bin/bash ]; then BASH_EXE="/bin/bash"; else BASH_EXE="bash"; fi

cleanup() {
  for dir in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do rm -rf "$dir" 2>/dev/null || true; done
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

assert_exit() {
  if [ "$LAST_EXIT" = "$2" ]; then pass "$1"; else fail "$1" "expected exit $2, got $LAST_EXIT (stderr: '$LAST_ERR')"; fi
}
assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}
assert_stdout_contains() {
  case "$LAST_OUT" in *"$2"*) pass "$1" ;; *) fail "$1" "expected '$2' in stdout: '$LAST_OUT'" ;; esac
}
assert_stderr_contains() {
  case "$LAST_ERR" in *"$2"*) pass "$1" ;; *) fail "$1" "expected '$2' in stderr: '$LAST_ERR'" ;; esac
}

# run_in <dir> <cmd...>
run_in() {
  local dir="$1" tmpout tmperr
  shift
  tmpout="$(mktemp)"; tmperr="$(mktemp)"
  ( unset CDPATH; cd "$dir" && "$@" ) > "$tmpout" 2> "$tmperr"
  LAST_EXIT=$?
  LAST_OUT="$(cat "$tmpout")"; LAST_ERR="$(cat "$tmperr")"
  rm -f "$tmpout" "$tmperr"
}

# A gh that fails every call: the migration and the local reads never call gh.
NOGH_DIR="$(mktemp -d)"; CLEANUP_DIRS+=("$NOGH_DIR")
printf '#!/bin/sh\necho "gh must not be called: $*" >&2\nexit 99\n' > "$NOGH_DIR/gh"
chmod +x "$NOGH_DIR/gh"
PATH="$NOGH_DIR:$PATH"

setup_repo() {
  REPO="$(mktemp -d)"; CLEANUP_DIRS+=("$REPO")
  git init -q "$REPO"
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test User"
  cat > "$REPO/.fleet-board.yml" <<'YML'
board:
  backend: local
  repo: acme/toy
worktrees:
  dir: .fw
YML
  git -C "$REPO" add .fleet-board.yml
  git -C "$REPO" commit -q -m "initial"
}

# Fixture: two cards as board-read.sh printed them on the Projects backend.
FIX="$(mktemp -d)"; CLEANUP_DIRS+=("$FIX")
NOTE_JSON='```json
{"round":1,"pr":12,"branch":"fleet/7-add-widget"}
```'
jq -n --arg note "$NOTE_JSON" '{
  number: 7, title: "Add widget", url: "https://github.com/acme/toy/issues/7",
  state: "ready",
  body: "## Acceptance\n- widget renders\n\n## Depends on\n- acme/toy#3\n",
  labels: ["area:ui"],
  manager_note: $note, manager_note_id: 9000000002, item_id: "PVTI_x",
  created_at: "2026-10-01T10:00:00Z", updated_at: "2026-10-02T11:00:00Z",
  comments: [
    {id: 9000000001, author: "ghuser", body: "A plain comment", created_at: "2026-10-01T12:00:00Z"},
    {id: 9000000002, author: "ghuser", body: ("<!-- fleet-board:manager-note -->\n" + $note), created_at: "2026-10-01T13:00:00Z"}
  ]}' > "$FIX/7.json"
jq -n '{
  number: 3, title: "Base work", url: "https://github.com/acme/toy/issues/3",
  state: "in_review", body: "Body three", labels: [],
  manager_note: null, manager_note_id: null, item_id: "PVTI_y",
  created_at: "2026-09-01T10:00:00Z", updated_at: "2026-09-02T10:00:00Z",
  comments: [{id: 9000000003, author: "someone", body: "Looks fine", created_at: "2026-09-03T10:00:00Z"}]
}' > "$FIX/3.json"

echo "migrate-to-local: fresh store"
setup_repo
run_in "$REPO" "$BASH_EXE" "$MIGRATE" "$FIX/7.json" "$FIX/3.json"
assert_exit "migration exits 0" 0
assert_eq "fresh migration writes nothing to stderr" "$LAST_ERR" ""
assert_stdout_contains "prints a line for card 7" "#7"
assert_stdout_contains "prints a line for card 3" "#3"
assert_eq "one line per card" "$(printf '%s\n' "$LAST_OUT" | grep -c .)" "2"
STORE="$REPO/.fleet-board"
assert_eq "card 7 file exists" "$([ -f "$STORE/cards/7.json" ] && echo yes)" "yes"
assert_eq "card 3 file exists" "$([ -f "$STORE/cards/3.json" ] && echo yes)" "yes"
assert_eq "next is highest number plus one" "$(tr -d '[:space:]' < "$STORE/next")" "8"
C7="$(cat "$STORE/cards/7.json" 2>/dev/null)"
assert_eq "card 7 keeps its number" "$(jq -r .number <<<"$C7" 2>/dev/null)" "7"
assert_eq "card 7 keeps its title" "$(jq -r .title <<<"$C7" 2>/dev/null)" "Add widget"
assert_eq "card 7 keeps its state" "$(jq -r .state <<<"$C7" 2>/dev/null)" "ready"
assert_eq "card 7 keeps its labels" "$(jq -c .labels <<<"$C7" 2>/dev/null)" '["area:ui"]'
assert_eq "card 7 keeps its Depends on bullet" "$(jq -r .body <<<"$C7" 2>/dev/null | grep -c '^- acme/toy#3$')" "1"
assert_eq "card 7 keeps created_at" "$(jq -r .created_at <<<"$C7" 2>/dev/null)" "2026-10-01T10:00:00Z"
assert_eq "card 7 keeps updated_at" "$(jq -r .updated_at <<<"$C7" 2>/dev/null)" "2026-10-02T11:00:00Z"
assert_eq "card 7 has both comments" "$(jq -r '.comments | length' <<<"$C7" 2>/dev/null)" "2"
assert_eq "card 7 comment ids are local" "$(jq -c '[.comments[].id]' <<<"$C7" 2>/dev/null)" "[1,2]"
assert_eq "card 7 next_comment_id follows" "$(jq -r .next_comment_id <<<"$C7" 2>/dev/null)" "3"
assert_eq "plain comment keeps its author" "$(jq -r '.comments[0].author' <<<"$C7" 2>/dev/null)" "ghuser"
assert_eq "plain comment keeps created_at" "$(jq -r '.comments[0].created_at' <<<"$C7" 2>/dev/null)" "2026-10-01T12:00:00Z"
assert_eq "note comment is authored by the local user" "$(jq -r '.comments[1].author' <<<"$C7" 2>/dev/null)" "localme"
assert_eq "card 7 drops the Projects-only fields" "$(jq -c '[has("url"), has("item_id"), has("manager_note")]' <<<"$C7" 2>/dev/null)" "[false,false,false]"
assert_eq "card 3 keeps its state" "$(jq -r .state "$STORE/cards/3.json" 2>/dev/null)" "in_review"

run_in "$REPO" "$BASH_EXE" "$SCRIPTS/board-read.sh" 7
assert_exit "board-read on the migrated store exits 0" 0
assert_eq "board-read returns the fixture's manager_note" "$(jq -r .manager_note <<<"$LAST_OUT" 2>/dev/null)" "$NOTE_JSON"
assert_eq "board-read manager_note_id is the local id" "$(jq -r .manager_note_id <<<"$LAST_OUT" 2>/dev/null)" "2"
run_in "$REPO" "$BASH_EXE" "$SCRIPTS/note.sh" get 7
assert_exit "note.sh get exits 0" 0
assert_eq "note.sh get finds the note" "$(jq -r .branch <<<"$LAST_OUT" 2>/dev/null)" "fleet/7-add-widget"
run_in "$REPO" "$BASH_EXE" "$SCRIPTS/board-list.sh" in_review
assert_eq "board-list in_review lists card 3" "$(jq -c '[.[].number]' <<<"$LAST_OUT" 2>/dev/null)" "[3]"

echo "migrate-to-local: refuses an existing store"
BEFORE="$(cat "$STORE/cards/7.json")"
run_in "$REPO" "$BASH_EXE" "$MIGRATE" "$FIX/3.json"
assert_exit "second run without --force exits 1" 1
assert_stderr_contains "names --force" "--force"
assert_eq "existing card left untouched" "$(cat "$STORE/cards/7.json")" "$BEFORE"
run_in "$REPO" "$BASH_EXE" "$MIGRATE" --force "$FIX/3.json"
assert_exit "--force run exits 0" 0
assert_eq "next still covers card 7" "$(tr -d '[:space:]' < "$STORE/next")" "8"

echo "migrate-to-local: bad input writes nothing"
setup_repo
printf '{"title":"no number"}\n' > "$FIX/bad.json"
run_in "$REPO" "$BASH_EXE" "$MIGRATE" "$FIX/7.json" "$FIX/bad.json"
assert_exit "bad card exits 1" 1
assert_eq "no store written" "$([ -e "$REPO/.fleet-board/next" ] || [ -e "$REPO/.fleet-board/cards/7.json" ] && echo written)" ""
run_in "$REPO" "$BASH_EXE" "$MIGRATE"
assert_exit "no files is a usage error" 2

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
