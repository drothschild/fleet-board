#!/usr/bin/env bash
#
# Plain-bash tests for the epic record (epic.sh, adapters/local/epic-lib.sh).
#
# Usage: bash plugins/fleet-board/tests/test-epic.sh

set -uo pipefail
unset CDPATH
unset FLEET_BOARD_ACTOR FLEET_BOARD_CONFIG FLEET_BOARD_LOCK_WAIT FB_CFG_FOR || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPTS="$SCRIPT_DIR/../scripts"
USER="${USER:-$(id -un)}"
export USER FLEET_BOARD_USER="${FLEET_BOARD_USER:-$USER}"

PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi; }

# mkrepo <name>: a git repo with a config and an empty local store (no epics/ dir).
mkrepo() {
  local repo="$WORK/$1"
  git init -q -b main "$repo"
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
  printf 'board:\n  repo: "o/r"\n' > "$repo/.fleet-board.yml"
  mkdir -p "$repo/.fleet-board/cards"
  printf '2\n' > "$repo/.fleet-board/next"
  printf '%s\n' "$repo"
}

# run <repo> <args...>: runs epic.sh with the repo as cwd; sets OUT, ERR and RC.
run() {
  local repo="$1"; shift
  ( cd "$repo" && FLEET_BOARD_CONFIG="$repo/.fleet-board.yml" bash "$SCRIPTS/epic.sh" "$@" ) >"$WORK/out" 2>"$WORK/err"
  RC=$?
  OUT="$(cat "$WORK/out")"; ERR="$(cat "$WORK/err")"
}

# card <repo> <n> <state> <epic|null> [blocked_by-json] [pr_url-json]: writes a card file.
card() {
  jq -n --argjson n "$2" --arg s "$3" --argjson e "$4" --argjson b "${5:-[]}" --argjson p "${6:-null}" \
    '{number: $n, title: ("card " + ($n | tostring)), state: $s, epic: $e, blocked_by: $b, pr_url: $p,
      labels: [], acceptance: [], body: "", created_at: "2020-01-01T00:00:00Z", updated_at: "2020-01-01T00:00:00Z"}' \
    > "$1/.fleet-board/cards/$2.json"
}
ej() { jq -c "$2" "$1/.fleet-board/epics/$3/epic.json"; }
title() { printf '%s' "${2:-An epic}" > "$WORK/title.txt"; printf '%s' "$WORK/title.txt"; }

# --- create ------------------------------------------------------------------
R="$(mkrepo r1)"
[ ! -e "$R/.fleet-board/epics" ] && pass "no epics dir before the first create" || fail "no epics dir before the first create" "exists"
run "$R" create --title-file "$(title)"
eq "create makes the store: rc" "$RC" "0"
eq "create makes the store: prints id" "$(jq -c . <<<"$OUT")" '{"id":1}'
eq "create makes the store: next" "$(tr -d '[:space:]' < "$R/.fleet-board/epics/next")" "2"
eq "create: state open" "$(ej "$R" .state 1)" '"open"'
eq "create: design_rev 0" "$(ej "$R" .design_rev 1)" "0"
eq "create: attention []" "$(ej "$R" .attention 1)" "[]"
eq "create: exported null" "$(ej "$R" .exported 1)" "null"
eq "create: title" "$(ej "$R" .title 1)" '"An epic"'
eq "create: id" "$(ej "$R" .id 1)" "1"
eq "create: repo null" "$(ej "$R" .repo 1)" "null"
eq "create: conversation null" "$(ej "$R" .conversation 1)" "null"
eq "create: intent string" "$(ej "$R" '.intent|type' 1)" '"string"'

printf 'the design\nsecond line\n' > "$WORK/design.md"
run "$R" create --title-file "$(title x Two)" --design-file "$WORK/design.md"
eq "second create prints 2" "$(jq -c . <<<"$OUT")" '{"id":2}'
eq "create with a design: design.md" "$(cat "$R/.fleet-board/epics/2/design.md")" "$(cat "$WORK/design.md")"
eq "create with a design: design_rev 1" "$(ej "$R" .design_rev 2)" "1"

: > "$WORK/empty.md"
run "$R" create --title-file "$(title)" --design-file "$WORK/empty.md"
eq "create with an empty design: no design.md" "$([ -e "$R/.fleet-board/epics/3/design.md" ] && echo yes || echo no)" "no"
eq "create with an empty design: design_rev 0" "$(ej "$R" .design_rev 3)" "0"

printf 'why we do it\n' > "$WORK/intent.md"
run "$R" create --title-file "$(title)" --intent-file "$WORK/intent.md" --repo o/r
eq "create with intent and repo: rc" "$RC" "0"
eq "create with intent: intent" "$(ej "$R" .intent 4)" "$(jq -Rs . < "$WORK/intent.md")"
eq "create with repo: repo" "$(ej "$R" .repo 4)" '"o/r"'

NEXT_BEFORE="$(cat "$R/.fleet-board/epics/next")"
run "$R" create --title-file "$(title)" --repo nobody/nothing
eq "create bad repo: exit 2" "$RC" "2"
eq "create bad repo: no folder" "$([ -e "$R/.fleet-board/epics/5" ] && echo yes || echo no)" "no"
eq "create bad repo: next unchanged" "$(cat "$R/.fleet-board/epics/next")" "$NEXT_BEFORE"

# --- read --------------------------------------------------------------------
run "$R" read 9
eq "read missing: exit 3" "$RC" "3"
eq "read missing: stderr" "$ERR" "fleet-board: epic E9 does not exist"
printf '"x"\n' > "$R/.fleet-board/epics/1/epic.json"
run "$R" read 1
eq "read malformed: exit 3" "$RC" "3"
printf '{"id": 7, "title": "x"}\n' > "$R/.fleet-board/epics/1/epic.json"
run "$R" read 1
eq "read wrong id: exit 3" "$RC" "3"

# --- children and progress ---------------------------------------------------
R="$(mkrepo r2)"
run "$R" create --title-file "$(title)"; run "$R" create --title-file "$(title)"
card "$R" 4 backlog 1; card "$R" 7 backlog 1; card "$R" 5 backlog 2
run "$R" read 1
eq "read children: numbers" "$(jq -c '[.children[].number]' <<<"$OUT")" "[4,7]"
eq "read children: shape" "$(jq -c '.children[0] | keys' <<<"$OUT")" '["blocked_by","number","pr_url","progress","repo","state","title"]'
eq "progress backlog" "$(jq -r '.children[0].progress' <<<"$OUT")" "waiting"
eq "read: design empty" "$(jq -c .design <<<"$OUT")" '""'
eq "read: log empty" "$(jq -c .log <<<"$OUT")" "[]"

R="$(mkrepo r3)"
run "$R" create --title-file "$(title)"
card "$R" 4 in_review null; card "$R" 5 ready 1 '[4]'
run "$R" read 1
eq "progress ready, dep unmet" "$(jq -r '.children[0].progress' <<<"$OUT")" "waiting"
card "$R" 4 done null
run "$R" read 1
eq "progress ready, dep met" "$(jq -r '.children[0].progress' <<<"$OUT")" "ready"

R="$(mkrepo r4)"
run "$R" create --title-file "$(title)"
card "$R" 1 in_progress 1; card "$R" 2 in_review 1; card "$R" 3 merging 1; card "$R" 4 human_qa 1
card "$R" 5 review_documentation 1; card "$R" 6 blocked 1; card "$R" 7 wont_do 1; card "$R" 8 done 1
run "$R" read 1
eq "progress in flight" "$(jq -c '[.children[0:5][].progress] | unique' <<<"$OUT")" '["in_flight"]'
eq "progress blocked" "$(jq -r '.children[5].progress' <<<"$OUT")" "blocked"
eq "progress dropped" "$(jq -r '.children[6].progress' <<<"$OUT")" "dropped"
eq "progress done" "$(jq -r '.children[7].progress' <<<"$OUT")" "done"
eq "progress counts" "$(jq -c '.progress' <<<"$OUT")" '{"waiting":0,"ready":0,"in_flight":5,"blocked":1,"done":1,"dropped":1}'
eq "progress counts sum to children" "$(jq '(.children | length) as $c | [.progress[]] | add == $c' <<<"$OUT")" "true"

# --- effective_state ---------------------------------------------------------
R="$(mkrepo r5)"
run "$R" create --title-file "$(title)"
run "$R" read 1
eq "effective open, no children" "$(jq -r .effective_state <<<"$OUT")" "open"
card "$R" 4 done 1; card "$R" 5 wont_do 1
run "$R" read 1
eq "effective complete" "$(jq -r .effective_state <<<"$OUT")" "complete"
card "$R" 4 done 1 '[]' '"https://example.com/o/r/pull/9"'
run "$R" read 1
eq "effective not complete: no log line" "$(jq -r .effective_state <<<"$OUT")" "open"
printf '{"card": 4, "pr_url": "x"}\n' > "$R/.fleet-board/epics/1/log.jsonl"
run "$R" read 1
eq "effective complete with log" "$(jq -r .effective_state <<<"$OUT")" "complete"
eq "read: log lines" "$(jq -c '[.log[].card]' <<<"$OUT")" "[4]"
card "$R" 6 in_progress 1
run "$R" read 1
eq "effective open with a live child" "$(jq -r .effective_state <<<"$OUT")" "open"

run "$R" list
eq "list: open epic present" "$(jq -c '[.[].id]' <<<"$OUT")" "[1]"
run "$R" set-state 1 closed
eq "set-state closed: rc" "$RC" "0"
run "$R" read 1
eq "closed wins" "$(jq -r .effective_state <<<"$OUT")" "closed"
run "$R" list
eq "list omits closed" "$OUT" "[]"
run "$R" list --all
eq "list --all has it" "$(jq -c '[.[] | [.id, .effective_state]]' <<<"$OUT")" '[[1,"closed"]]'
eq "list shape" "$(jq -c '.[0] | keys' <<<"$OUT")" '["attention","effective_state","id","progress","title"]'
run "$R" set-state 1 open
eq "set-state reopen" "$(ej "$R" .state 1)" '"open"'

# --- set-intent, clear-attention ---------------------------------------------
R="$(mkrepo r6)"
printf 'D\n' > "$WORK/d.md"
run "$R" create --title-file "$(title)" --design-file "$WORK/d.md"
OLD_UPD="$(ej "$R" .updated_at 1)"
sleep 1
printf 'new intent\n' > "$WORK/i.md"
run "$R" set-intent 1 "$WORK/i.md"
eq "set-intent: rc" "$RC" "0"
eq "set-intent: intent" "$(ej "$R" .intent 1)" "$(jq -Rs . < "$WORK/i.md")"
[ "$(ej "$R" .updated_at 1)" != "$OLD_UPD" ] && pass "set-intent: updated_at changes" || fail "set-intent: updated_at changes" "unchanged $OLD_UPD"
eq "set-intent: design untouched" "$(cat "$R/.fleet-board/epics/1/design.md")" "D"
run "$R" set-intent 9 "$WORK/i.md"
eq "set-intent missing epic: exit 3" "$RC" "3"

jq '.attention = [{reason: "a", card: 4, at: "2020-01-01T00:00:00Z"}, {reason: "b", card: null, at: "2020-01-02T00:00:00Z"}]' \
  "$R/.fleet-board/epics/1/epic.json" > "$WORK/e.json" && mv "$WORK/e.json" "$R/.fleet-board/epics/1/epic.json"
run "$R" list
eq "list: attention count" "$(jq -c '.[0].attention' <<<"$OUT")" "2"
run "$R" clear-attention 1 0
eq "clear-attention: rc" "$RC" "0"
eq "clear-attention: second left" "$(ej "$R" '[.attention[].reason]' 1)" '["b"]'
run "$R" clear-attention 1 5
eq "clear-attention out of range: exit 1" "$RC" "1"
run "$R" clear-attention 1 x
eq "clear-attention bad index: exit 2" "$RC" "2"

# --- usage -------------------------------------------------------------------
run "$R"
eq "usage: no verb" "$RC" "2"
run "$R" frobnicate
eq "usage: unknown verb" "$RC" "2"
run "$R" read
eq "usage: read with no id" "$RC" "2"
run "$R" set-state 1 nonsense
eq "usage: set-state nonsense" "$RC" "2"
run "$R" create
eq "usage: create with no title" "$RC" "2"

printf '\npassed: %s\nfailed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
