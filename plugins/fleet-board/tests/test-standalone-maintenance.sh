#!/usr/bin/env bash
set -uo pipefail
unset CDPATH
case "${1:-}" in wait|wait-resume|lint|block|block-resume|unblock|unblock-race|file-pending|file-partial|file-race|file-failure-count) ;; *) echo 'usage: test-standalone-maintenance.sh wait|wait-resume|lint' >&2; exit 2 ;; esac
TESTS="$(cd "$(dirname "$0")" && pwd)"; HANDLER="$TESTS/../scripts/standalone/maintenance.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo" "$TMP/bin" "$TMP/state" "$TMP/scratch"
git -C "$TMP/repo" init -q
printf 'board: { repo: acme/toy }\n' > "$TMP/repo/.fleet-board.yml"
printf '[]\n' > "$TMP/state/comments"
printf ready > "$TMP/state/column"
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  'api user') echo '{"login":"bot"}' ;;
  'issue list --repo acme/toy --state open --search '*) if [ -f "$STATE/search-fails" ]; then n="$(cat "$STATE/search-fails")"; if [ "$n" -gt 0 ]; then echo $((n-1)) > "$STATE/search-fails"; exit 1; fi; fi; case "$*" in *first*) echo '[{"number":77,"title":"first"}]' ;; *second*) echo '[{"number":78,"title":"second"}]' ;; *) exit 1 ;; esac ;;
  'issue comment 77 --repo acme/toy --body '*) if [ -e "$STATE/change-pending" ]; then rm "$STATE/change-pending"; bash "$NOTE_SCRIPT" merge 12 "$STATE/new-pending" || exit 1; fi ;;
  'issue comment 78 --repo acme/toy --body '*) exit 1 ;;
  'pr comment 34 --repo acme/toy --body '*) : ;;
  'api repos/acme/toy/issues/12') column="$(cat "$STATE/column")"; jq -n --arg col "$column" '{number:12,title:"test",body:"## Acceptance\n- test",html_url:"https://github.com/acme/toy/issues/12",labels:(if $col == "none" then [] else [{name:("fleet:"+$col)}] end)}' ;;
  'issue edit 12 --repo acme/toy --remove-label fleet:'*) printf none > "$STATE/column" ;;
  'issue edit 12 --repo acme/toy --add-label fleet:'*) if [ -e "$STATE/fail-add" ]; then rm "$STATE/fail-add"; exit 1; fi; printf '%s' "${7#fleet:}" > "$STATE/column" ;;
  'pr view 34 --repo acme/toy --json number,state,mergedAt') echo '{"number":34,"state":"MERGED","mergedAt":"2026-01-01T00:00:00Z"}' ;;
  'api --paginate repos/acme/toy/issues/12/comments') cat "$STATE/comments" ;;
  'issue comment 12 --repo acme/toy --body-file '*) jq --rawfile body "$7" '. + [{id:556,user:{login:"bot"},body:$body}]' "$STATE/comments" > "$STATE/new" && mv "$STATE/new" "$STATE/comments" ;;
  'api -X POST repos/acme/toy/issues/12/comments --input -') if [ -e "$STATE/fail-note" ]; then rm "$STATE/fail-note"; exit 1; fi; body="$(cat)"; jq --argjson x "$body" '. + [{id:555,user:{login:"bot"},body:$x.body}]' "$STATE/comments" > "$STATE/new" && mv "$STATE/new" "$STATE/comments"; echo '{"id":555}' ;;
  'api -X PATCH repos/acme/toy/issues/comments/555 --input -') body="$(cat)"; jq --argjson x "$body" 'map(if .id == 555 then .body = $x.body else . end)' "$STATE/comments" > "$STATE/new" && mv "$STATE/new" "$STATE/comments"; echo '{}' ;;
  'api -X PUT repos/acme/toy/issues/comments/555/pin') echo '{}' ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
GH
chmod +x "$TMP/bin/gh"
export NOTE_SCRIPT="$TESTS/../scripts/note.sh"
export PATH="$TMP/bin:$PATH" STATE="$TMP/state" FLEET_BOARD_STANDALONE_FIXTURE=1 FLEET_BOARD_FIXTURE_ROOT="$TMP"
cd "$TMP/repo" || exit 1
if [ "$1" = file-race ]; then
  printf '%s\n' '{"pr":34,"pending_followups":{"out_of_scope":[{"title":"first","detail":"no testable check"}],"bugs":[],"pr":34}}' > "$TMP/patch"
  bash "$NOTE_SCRIPT" merge 12 "$TMP/patch" || exit 1
  printf '%s\n' '{"pending_followups":{"out_of_scope":[{"title":"first","detail":"no testable check"},{"title":"second","detail":"no testable check"}],"bugs":[],"pr":34}}' > "$STATE/new-pending"
  touch "$STATE/change-pending"
  jq -n '{number:12,state:"ready",action:"file_pending",pr:34,reason:"pending follow-ups"}' > "$TMP/card"
  if bash "$HANDLER" "$TMP/card" "$TMP/scratch"; then echo 'FAIL: concurrent pending change ignored' >&2; exit 1; fi
  note="$(bash "$NOTE_SCRIPT" get 12)" || exit 1
  jq -e '.pending_followups.out_of_scope | length == 2' <<<"$note" >/dev/null || { echo 'FAIL: new pending item lost' >&2; exit 1; }
  echo 'PASS: file-race'; exit 0
fi
if [ "$1" = file-failure-count ]; then
  printf '%s\n' '{"pr":34,"pending_followups":{"out_of_scope":[{"title":"first","detail":"no testable check"},{"title":"second","detail":"no testable check"}],"bugs":[],"pr":34}}' > "$TMP/patch"
  bash "$NOTE_SCRIPT" merge 12 "$TMP/patch" || exit 1
  jq -n '{number:12,state:"ready",action:"file_pending",pr:34,reason:"pending follow-ups"}' > "$TMP/card"
  echo 2 > "$STATE/search-fails"
  for attempt in 1 2 3; do
    if bash "$HANDLER" "$TMP/card" "$TMP/scratch"; then echo 'FAIL: filing unexpectedly succeeded' >&2; exit 1; fi
  done
  note="$(bash "$NOTE_SCRIPT" get 12)" || exit 1
  jq -e '.action_failures == 3 and .out_of_scope_created[0].title == "first" and .pending_followups.out_of_scope[0].title == "second"' <<<"$note" >/dev/null || { echo "FAIL: latest failure count not retained: $note" >&2; exit 1; }
  echo 'PASS: file-failure-count'; exit 0
fi
if [ "$1" = file-partial ]; then
  printf '%s\n' '{"pr":34,"pending_followups":{"out_of_scope":[{"title":"first","detail":"no testable check"},{"title":"second","detail":"no testable check"}],"bugs":[],"pr":34}}' > "$TMP/patch"
  bash "$TESTS/../scripts/note.sh" merge 12 "$TMP/patch" || exit 1
  jq -n '{number:12,state:"ready",action:"file_pending",pr:34,reason:"pending follow-ups"}' > "$TMP/card"
  if bash "$HANDLER" "$TMP/card" "$TMP/scratch"; then echo 'FAIL: partial filing accepted as complete' >&2; exit 1; fi
  note="$(bash "$TESTS/../scripts/note.sh" get 12)" || exit 1
  jq -e '.out_of_scope_created[0].title == "first" and .pending_followups.out_of_scope == [{"title":"second","detail":"no testable check"}] and .action_failures == 1' <<<"$note" >/dev/null || { echo 'FAIL: partial filing lost or not counted' >&2; exit 1; }
  echo 'PASS: file-partial'; exit 0
fi
if [ "$1" = file-pending ]; then
  printf '%s\n' '{"pr":34,"pending_followups":{"out_of_scope":[],"bugs":[],"pr":34}}' > "$TMP/patch"
  bash "$TESTS/../scripts/note.sh" merge 12 "$TMP/patch" || exit 1
  jq -n '{number:12,state:"ready",action:"file_pending",pr:34,reason:"pending follow-ups"}' > "$TMP/card"
  bash "$HANDLER" "$TMP/card" "$TMP/scratch" || exit 1
  bash "$HANDLER" "$TMP/card" "$TMP/scratch" || exit 1
  note="$(bash "$TESTS/../scripts/note.sh" get 12)" || exit 1
  jq -e '.pending_followups == null and .action_failures == 0' <<<"$note" >/dev/null || { echo 'FAIL: pending not cleared' >&2; exit 1; }
  echo 'PASS: file-pending'; exit 0
fi
if [ "$1" = block ] || [ "$1" = block-resume ] || [ "$1" = unblock ] || [ "$1" = unblock-race ]; then
  if [ "$1" = unblock ] || [ "$1" = unblock-race ]; then
    printf blocked > "$STATE/column"
    printf '%s\n' '{"blocking_pr":34,"blocked_from":"ready","blocked_findings":[{"severity":"Important","text":"old"}],"action_failures":2,"last_action_error":"old"}' > "$TMP/patch"
    bash "$TESTS/../scripts/note.sh" merge 12 "$TMP/patch" || exit 1
    jq -n '{number:12,state:"blocked",action:"unblock",reason:"blocking PR #34 merged"}' > "$TMP/card"
  else
    jq -n '{number:12,state:"ready",action:"block",reason:"no progress after 3 attempts: failed"}' > "$TMP/card"
  fi
  if [ "$1" = unblock-race ]; then
    touch "$STATE/fail-add"
    if bash "$HANDLER" "$TMP/card" "$TMP/scratch"; then echo 'FAIL: interrupted unblock succeeded' >&2; exit 1; fi
    printf '%s\n' '{"blocking_pr":35}' > "$TMP/patch"
    bash "$TESTS/../scripts/note.sh" merge 12 "$TMP/patch" || exit 1
    if bash "$HANDLER" "$TMP/card" "$TMP/scratch"; then echo 'FAIL: changed blocker was ignored' >&2; exit 1; fi
    note="$(bash "$TESTS/../scripts/note.sh" get 12)" || exit 1
    jq -e '.blocking_pr == 35' <<<"$note" >/dev/null || exit 1
    [ "$(cat "$STATE/column")" = none ] || exit 1
    echo 'PASS: unblock-race'; exit 0
  fi
  if [ "$1" = block-resume ]; then
    touch "$STATE/fail-add"
    if bash "$HANDLER" "$TMP/card" "$TMP/scratch"; then echo 'FAIL: interrupted move unexpectedly succeeded' >&2; exit 1; fi
  fi
  bash "$HANDLER" "$TMP/card" "$TMP/scratch" || exit 1
  bash "$HANDLER" "$TMP/card" "$TMP/scratch" || exit 1
  note="$(bash "$TESTS/../scripts/note.sh" get 12)" || exit 1
  if [ "$1" = block ] || [ "$1" = block-resume ]; then
    [ "$(cat "$STATE/column")" = blocked ] && jq -e '.blocked_from == "ready" and .blocked_findings[0].text == "no progress after 3 attempts: failed" and .action_failures == 0' <<<"$note" >/dev/null || exit 1
    jq -e '[.[] | select(.body | contains("fleet-board:maintenance:block:"))] | length == 1' "$STATE/comments" >/dev/null || exit 1
  else
    [ "$(cat "$STATE/column")" = ready ] && jq -e '.blocking_pr == null and .blocked_from == null and .blocked_findings == null and .action_failures == 0' <<<"$note" >/dev/null || exit 1
  fi
  echo "PASS: $1"; exit 0
fi
if [ "$1" = wait ] || [ "$1" = wait-resume ]; then
  jq -n '{number:12,state:"ready",action:"wait",waiting_on:["acme/toy#3"]}' > "$TMP/card"
  if [ "$1" = wait-resume ]; then
    touch "$STATE/fail-note"
    if bash "$HANDLER" "$TMP/card" "$TMP/scratch"; then echo 'FAIL: note write unexpectedly succeeded' >&2; exit 1; fi
  else
    bash "$HANDLER" "$TMP/card" "$TMP/scratch" || exit 1
  fi
  bash "$HANDLER" "$TMP/card" "$TMP/scratch" || exit 1
  jq -e '[.[] | select(.body | startswith("Waiting for "))] | length == 1 and .[0].body == "Waiting for acme/toy#3"' "$TMP/state/comments" >/dev/null || { echo 'FAIL: wait notice duplicated or malformed' >&2; exit 1; }
else
  jq -n '{number:12,state:"ready",action:"skip_card_lint",comment_needed:true,lint:["title: too short"],lint_marker:"<!-- fleet-board:card-lint:123 -->"}' > "$TMP/card"
  bash "$HANDLER" "$TMP/card" "$TMP/scratch" || exit 1
  bash "$HANDLER" "$TMP/card" "$TMP/scratch" || exit 1
  jq -e '[.[] | select(.body | startswith("<!-- fleet-board:card-lint:123 -->"))] | length == 1 and (.[0].body | contains("title: too short"))' "$TMP/state/comments" >/dev/null || { echo 'FAIL: lint notice duplicated or malformed' >&2; exit 1; }
fi
echo "PASS: $1"
