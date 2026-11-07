#!/usr/bin/env bash
# Run a partially completed maintenance action through the standalone CLI.
set -uo pipefail
unset CDPATH
case "${1:-}" in maintenance-block-resume|maintenance-file-pending) ;; *) exit 2 ;; esac
TESTS="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$TESTS/../../.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo" "$TMP/bin" "$TMP/state"
git -C "$TMP/repo" init -q
printf 'board: { repo: acme/toy }\nworktrees: { dir: .fw }\n' > "$TMP/repo/.fleet-board.yml"
printf in_review > "$TMP/state/column"; printf '[]\n' > "$TMP/state/comments"; touch "$TMP/state/fail-move"
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
set -uo pipefail
case "$*" in
  'api user') echo '{"login":"bot"}' ;;
  'issue list --repo acme/toy --state open --search '*) echo '[{"number":77,"title":"first"}]' ;;
  'issue comment 77 --repo acme/toy --body '*) touch "$STATE/filed" ;;
  'pr comment 34 --repo acme/toy --body '*) : ;;
  'api -X PATCH repos/acme/toy/issues/comments/555 --input -')
    body="$(cat)"; jq --argjson x "$body" 'map(if .id == 555 then .body = $x.body else . end)' "$STATE/comments" > "$STATE/new" && mv "$STATE/new" "$STATE/comments"; echo '{}' ;;

  'api repos/acme/toy/issues/12')
    column="$(cat "$STATE/column")"
    jq -n --arg label "fleet:$column" '{number:12,title:"test",body:"## Acceptance\n- complete\n",html_url:"https://github.com/acme/toy/issues/12",labels:[{name:$label}]}' ;;
  'api --paginate repos/acme/toy/issues/12/comments') cat "$STATE/comments" ;;
  'issue edit 12 --repo acme/toy --remove-label fleet:in_review') printf none > "$STATE/column" ;;
  'issue edit 12 --repo acme/toy --add-label fleet:blocked')
    if [ -e "$STATE/fail-move" ]; then rm "$STATE/fail-move"; exit 1; fi
    printf blocked > "$STATE/column" ;;
  'issue comment 12 --repo acme/toy --body-file '*) jq --rawfile body "$7" '. + [{id:556,user:{login:"bot"},body:$body}]' "$STATE/comments" > "$STATE/new" && mv "$STATE/new" "$STATE/comments" ;;
  'api -X POST repos/acme/toy/issues/12/comments --input -')
    body="$(cat)"; jq --argjson x "$body" '. + [{id:555,user:{login:"bot"},body:$x.body}]' "$STATE/comments" > "$STATE/new" && mv "$STATE/new" "$STATE/comments"; echo '{"id":555}' ;;
  'api -X PUT repos/acme/toy/issues/comments/555/pin') echo '{}' ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
GH
chmod +x "$TMP/bin/gh"
jq -n --arg wt "$TMP/repo/.fw/12-test" '{dispatchable:true,warnings:[],cards:[{number:12,title:"test",state:"in_review",action:"block",reason:"findings remain",branch:"fleet/12-test",worktree:$wt,pr:null,round:1,models:{implementor:"sonnet",reviewer:"opus",fixer:"sonnet"},escalated:false,stage:null,needs_human_qa:null}]}' > "$TMP/plan"
cat > "$TMP/planner" <<PLAN
#!/bin/bash
cat "$TMP/plan"
PLAN
export PATH="$TMP/bin:$PATH" STATE="$TMP/state" FLEET_BOARD_STANDALONE_FIXTURE=1 FLEET_BOARD_FIXTURE_ROOT="$TMP" FLEET_BOARD_TICK_PLAN="$TMP/planner"
cd "$TMP/repo"
if [ "$1" = maintenance-file-pending ]; then
  printf ready > "$STATE/column"
  printf '%s\n' '{"pr":34,"pending_followups":{"out_of_scope":[{"title":"first","detail":"no testable check"}],"bugs":[],"pr":34}}' > "$TMP/patch"
  bash "$ROOT/plugins/fleet-board/scripts/note.sh" merge 12 "$TMP/patch" || exit 1
  jq -n --arg wt "$TMP/repo/.fw/12-test" '{dispatchable:false,warnings:[],cards:[{number:12,title:"test",state:"ready",action:"file_pending",reason:"pending follow-ups",branch:"fleet/12-test",worktree:$wt,pr:34,round:0,models:{implementor:"sonnet",reviewer:"opus",fixer:"sonnet"},escalated:false,stage:null,needs_human_qa:null}]}' > "$TMP/plan"
  if ! bash "$ROOT/bin/fleet-board" tick > "$TMP/file-out"; then echo 'FAIL: pending follow-up tick failed' >&2; exit 1; fi
  jq -e '.outcome == "progress" and .dispatchable == true' "$TMP/file-out" >/dev/null || { echo 'FAIL: filing did not keep run dispatchable' >&2; exit 1; }
  [ -e "$STATE/filed" ] || { echo 'FAIL: follow-up not filed' >&2; exit 1; }
  note="$(bash "$ROOT/plugins/fleet-board/scripts/note.sh" get 12)" || exit 1
  jq -e '.pending_followups == null and .out_of_scope_created[0].number == 77' <<<"$note" >/dev/null || { echo 'FAIL: pending result not reconciled' >&2; exit 1; }
  echo 'PASS: maintenance-file-pending'
  exit 0
fi
if bash "$ROOT/bin/fleet-board" tick > "$TMP/first" 2> "$TMP/first-err"; then echo 'FAIL: simulated block interruption succeeded' >&2; exit 1; fi
[ "$(cat "$STATE/column")" = none ] || { cat "$TMP/first-err" >&2; echo 'FAIL: block did not reach partial transition' >&2; exit 1; }
if ! bash "$ROOT/bin/fleet-board" tick > "$TMP/second"; then echo 'FAIL: block recovery failed' >&2; exit 1; fi
[ "$(cat "$STATE/column")" = blocked ] || { echo 'FAIL: card not blocked after recovery' >&2; exit 1; }
jq -e '[.[] | select(.body | contains("fleet-board:maintenance:block:"))] | length == 1' "$STATE/comments" >/dev/null || { echo 'FAIL: block report missing or duplicated' >&2; exit 1; }
echo 'PASS: maintenance-block-resume'
