#!/usr/bin/env bash
set -uo pipefail
unset CDPATH
case "${1:-}" in move-to-review|move-resume|stage-advance|settle-pass|settle-unknown|run-settle) ;; *) echo 'usage: test-standalone-settle.sh move-to-review|run-settle' >&2; exit 2 ;; esac
TESTS="$(cd "$(dirname "$0")" && pwd)"; SCRIPTS="$TESTS/../scripts"; ROOT="$(cd "$TESTS/../../.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo" "$TMP/bin" "$TMP/state" "$TMP/scratch" "$TMP/log"
git -C "$TMP/repo" init -q
printf 'board: { repo: acme/toy }\nlimits: { tick_interval: 0 }\n' > "$TMP/repo/.fleet-board.yml"
printf '[]\n' > "$TMP/state/comments"; printf in_progress > "$TMP/state/column"
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  'api user') echo '{"login":"bot"}' ;;
  'issue list --repo acme/toy --label fleet:in_progress '*) if [ "$(cat "$GH_STATE/column")" = in_progress ]; then echo '[{"number":12,"title":"test","url":"https://github.com/acme/toy/issues/12","labels":[{"name":"fleet:in_progress"}]}]'; else echo '[]'; fi ;;
  'issue list --repo acme/toy --label fleet:in_review '*) echo '[]' ;;
  'api repos/acme/toy/issues/12') col="$(cat "$GH_STATE/column")"; jq -n --arg col "$col" '{number:12,title:"test",body:"## Acceptance\n- test",html_url:"https://github.com/acme/toy/issues/12",labels:(if $col == "none" then [] else [{name:("fleet:"+$col)}] end)}' ;;
  'api --paginate repos/acme/toy/issues/12/comments') cat "$GH_STATE/comments" ;;
  'issue edit 12 --repo acme/toy --remove-label fleet:in_review') printf none > "$GH_STATE/column" ;;
  'issue edit 12 --repo acme/toy --add-label fleet:review_security') printf review_security > "$GH_STATE/column" ;;
  'issue edit 12 --repo acme/toy --remove-label fleet:in_progress') printf none > "$GH_STATE/column" ;;
  'issue edit 12 --repo acme/toy --add-label fleet:in_review') printf in_review > "$GH_STATE/column" ;;
  'api -X POST repos/acme/toy/issues/12/comments --input -') if [ -e "$GH_STATE/fail-note" ]; then rm "$GH_STATE/fail-note"; exit 1; fi; body="$(cat)"; jq --argjson x "$body" '. + [{id:555,user:{login:"bot"},body:$x.body}]' "$GH_STATE/comments" > "$GH_STATE/new" && mv "$GH_STATE/new" "$GH_STATE/comments"; echo '{"id":555}' ;;
  'api -X PATCH repos/acme/toy/issues/comments/555 --input -') body="$(cat)"; jq --argjson x "$body" 'map(if .id == 555 then .body = $x.body else . end)' "$GH_STATE/comments" > "$GH_STATE/new" && mv "$GH_STATE/new" "$GH_STATE/comments"; echo '{}' ;;
  'api -X PUT repos/acme/toy/issues/comments/555/pin') echo '{}' ;;
  'pr view 34 --repo acme/toy --json number,isDraft,state,headRefName,headRefOid,baseRefName,headRepositoryOwner,headRepository,body'|'pr view 34 --repo acme/toy --json number,state,headRefName,headRefOid,baseRefName,headRepositoryOwner,headRepository,body') echo '{"number":34,"state":"OPEN","headRefName":"fleet/12-example","headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","baseRefName":"main","headRepositoryOwner":{"login":"acme"},"headRepository":{"name":"toy"},"body":"<!-- fleet-board:card:12 -->"}' ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
GH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" GH_STATE="$TMP/state" FLEET_BOARD_STANDALONE_FIXTURE=1 FLEET_BOARD_FIXTURE_ROOT="$TMP"
cd "$TMP/repo" || exit 1
if [ "$1" = settle-pass ] || [ "$1" = settle-unknown ]; then
  jq -n '{dispatchable:false,warnings:[],cards:[{number:12,state:"in_progress",action:"move_to_review",pr:34,branch:"fleet/12-example",reason:"PR exists"}]}' > "$TMP/plan"
  if [ "$1" = settle-unknown ]; then jq '.cards[0].action = "merge"' "$TMP/plan" > "$TMP/plan.new" && mv "$TMP/plan.new" "$TMP/plan"; fi
  printf '#!/bin/sh\ncat "$PLAN_FIXTURE"\n' > "$TMP/plan-command"
  export PLAN_FIXTURE="$TMP/plan" FLEET_BOARD_TICK_PLAN="$TMP/plan-command"
  if [ "$1" = settle-unknown ]; then
    if bash "$SCRIPTS/standalone/settle.sh"; then echo 'FAIL: unexpected settle action accepted' >&2; exit 1; fi
    [ "$(cat "$GH_STATE/column")" = in_progress ] || exit 1
    echo 'PASS: settle-unknown'; exit 0
  fi
  bash "$SCRIPTS/standalone/settle.sh" || exit 1
  [ "$(cat "$GH_STATE/column")" = in_review ] || exit 1
  echo 'PASS: settle-pass'; exit 0
fi
if [ "$1" = stage-advance ]; then
  cat >> "$TMP/repo/.fleet-board.yml" <<'YML'
review:
  stages:
    - name: security
      agent: fixture-reviewer
      model: opus
      paths: ["source.txt"]
      label: needs-security-review
      advisory: false
YML
  printf in_review > "$GH_STATE/column"
  printf '%s\n' '{"round":1,"last_review":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","round":1,"critical":0,"important":0,"findings":[]}}' > "$TMP/patch"
  bash "$SCRIPTS/note.sh" merge 12 "$TMP/patch" || exit 1
  jq -n '{number:12,state:"in_review",action:"advance_stage",pr:34,branch:"fleet/12-example",stage:{name:"security",provider:null,agent:"fixture-reviewer",model:"opus"}}' > "$TMP/card"
  jq -n --slurpfile c "$TMP/card" '{cards:[$c[0]]}' > "$TMP/plan"
  printf '#!/bin/sh\ncat "$PLAN_FIXTURE"\n' > "$TMP/plan-command"
  export PLAN_FIXTURE="$TMP/plan" FLEET_BOARD_TICK_PLAN="$TMP/plan-command"
  bash "$SCRIPTS/standalone/settle-stage.sh" "$TMP/card" "$TMP/scratch" || exit 1
  [ "$(cat "$GH_STATE/column")" = review_security ] || exit 1
  note="$(bash "$SCRIPTS/note.sh" get 12)" || exit 1
  jq -e '.stage == "security" and .round == 1' <<<"$note" >/dev/null || exit 1
  echo 'PASS: stage-advance'; exit 0
fi
if [ "$1" = move-to-review ] || [ "$1" = move-resume ]; then
  jq -n '{number:12,state:"in_progress",action:"move_to_review",pr:34,branch:"fleet/12-example",reason:"PR exists"}' > "$TMP/card"
  if [ "$1" = move-resume ]; then
    touch "$GH_STATE/fail-note"
    if bash "$SCRIPTS/standalone/settle-move.sh" "$TMP/card" "$TMP/scratch"; then echo 'FAIL: failed note accepted' >&2; exit 1; fi
    [ "$(cat "$GH_STATE/column")" = in_review ] || exit 1
  fi
  bash "$SCRIPTS/standalone/settle-move.sh" "$TMP/card" "$TMP/scratch" || exit 1
  [ "$(cat "$GH_STATE/column")" = in_review ] || exit 1
  note="$(bash "$SCRIPTS/note.sh" get 12)" || exit 1
  jq -e '.pr == 34 and .round == 1 and .state == "in_review"' <<<"$note" >/dev/null || exit 1
  echo "PASS: $1"; exit 0
fi
cat > "$TMP/tick" <<'TICK'
#!/bin/sh
echo '{"outcome":"idle","dispatchable":false,"cost_usd":0}'
TICK
cat > "$TMP/settle" <<'SETTLE'
#!/bin/sh
echo settle >> "$GH_STATE/order"
SETTLE
cat > "$TMP/cleanup" <<'CLEANUP'
#!/bin/sh
echo cleanup >> "$GH_STATE/order"
CLEANUP
export FLEET_BOARD_STANDALONE_TICK="$TMP/tick" FLEET_BOARD_STANDALONE_SETTLE="$TMP/settle" FLEET_BOARD_CLEANUP="$TMP/cleanup" FLEET_BOARD_LOG_DIR="$TMP/log"
bash "$ROOT/bin/fleet-board" run > "$TMP/out" || exit 1
printf 'settle\ncleanup\n' > "$TMP/expected"
cmp -s "$TMP/expected" "$GH_STATE/order" || { echo 'FAIL: settle did not precede cleanup' >&2; exit 1; }
echo 'PASS: run-settle'
