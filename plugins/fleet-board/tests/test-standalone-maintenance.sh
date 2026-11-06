#!/usr/bin/env bash
set -uo pipefail
unset CDPATH
case "${1:-}" in wait|lint) ;; *) echo 'usage: test-standalone-maintenance.sh wait|lint' >&2; exit 2 ;; esac
TESTS="$(cd "$(dirname "$0")" && pwd)"; HANDLER="$TESTS/../scripts/standalone/maintenance.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo" "$TMP/bin" "$TMP/state" "$TMP/scratch"
git -C "$TMP/repo" init -q
printf 'board: { repo: acme/toy }\n' > "$TMP/repo/.fleet-board.yml"
printf '[]\n' > "$TMP/state/comments"
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  'api user') echo '{"login":"bot"}' ;;
  'api repos/acme/toy/issues/12') echo '{"number":12,"title":"test","body":"","html_url":"https://github.com/acme/toy/issues/12","labels":[{"name":"fleet:ready"}]}' ;;
  'api --paginate repos/acme/toy/issues/12/comments') cat "$STATE/comments" ;;
  'issue comment 12 --repo acme/toy --body-file '*) jq --rawfile body "$7" '. + [{id:556,user:{login:"bot"},body:$body}]' "$STATE/comments" > "$STATE/new" && mv "$STATE/new" "$STATE/comments" ;;
  'api -X POST repos/acme/toy/issues/12/comments --input -') body="$(cat)"; jq --argjson x "$body" '. + [{id:555,user:{login:"bot"},body:$x.body}]' "$STATE/comments" > "$STATE/new" && mv "$STATE/new" "$STATE/comments"; echo '{"id":555}' ;;
  'api -X PATCH repos/acme/toy/issues/comments/555 --input -') body="$(cat)"; jq --argjson x "$body" 'map(if .id == 555 then .body = $x.body else . end)' "$STATE/comments" > "$STATE/new" && mv "$STATE/new" "$STATE/comments"; echo '{}' ;;
  'api -X PUT repos/acme/toy/issues/comments/555/pin') echo '{}' ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
GH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" STATE="$TMP/state" FLEET_BOARD_STANDALONE_FIXTURE=1 FLEET_BOARD_FIXTURE_ROOT="$TMP"
cd "$TMP/repo" || exit 1
if [ "$1" = wait ]; then
  jq -n '{number:12,state:"ready",action:"wait",waiting_on:["acme/toy#3"]}' > "$TMP/card"
  bash "$HANDLER" "$TMP/card" "$TMP/scratch" || exit 1
  bash "$HANDLER" "$TMP/card" "$TMP/scratch" || exit 1
  jq -e '[.[] | select(.body | startswith("Waiting for "))] | length == 1 and .[0].body == "Waiting for acme/toy#3"' "$TMP/state/comments" >/dev/null || { echo 'FAIL: wait notice duplicated or malformed' >&2; exit 1; }
else
  jq -n '{number:12,state:"ready",action:"skip_card_lint",comment_needed:true,lint:["title: too short"],lint_marker:"<!-- fleet-board:card-lint:123 -->"}' > "$TMP/card"
  bash "$HANDLER" "$TMP/card" "$TMP/scratch" || exit 1
  bash "$HANDLER" "$TMP/card" "$TMP/scratch" || exit 1
  jq -e '[.[] | select(.body | startswith("<!-- fleet-board:card-lint:123 -->"))] | length == 1 and (.[0].body | contains("title: too short"))' "$TMP/state/comments" >/dev/null || { echo 'FAIL: lint notice duplicated or malformed' >&2; exit 1; }
fi
echo "PASS: $1"
