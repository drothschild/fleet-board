#!/usr/bin/env bash
set -uo pipefail
unset CDPATH
case "${1:-}" in update-branch|update-stale) ;; *) echo 'usage: test-standalone-update-branch.sh update-branch|update-stale' >&2; exit 2 ;; esac
TESTS="$(cd "$(dirname "$0")" && pwd)"; HANDLER="$TESTS/../scripts/standalone/update-branch.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo" "$TMP/bin" "$TMP/state" "$TMP/scratch"
git init -q --bare "$TMP/remote.git"
git -C "$TMP/repo" init -q -b main
git -C "$TMP/repo" config user.name Test; git -C "$TMP/repo" config user.email test@example.com
printf 'board: { repo: acme/toy }\n' > "$TMP/repo/.fleet-board.yml"
printf base > "$TMP/repo/base"; git -C "$TMP/repo" add .; git -C "$TMP/repo" commit -qm initial
git -C "$TMP/repo" remote add origin "file://$TMP/remote.git"
git -C "$TMP/repo" push -q origin main
git -C "$TMP/repo" checkout -qb fleet/12-example
printf branch > "$TMP/repo/branch"; git -C "$TMP/repo" add branch; git -C "$TMP/repo" commit -qm branch
git -C "$TMP/repo" push -q origin fleet/12-example
BEFORE="$(git -C "$TMP/repo" rev-parse HEAD)"
git -C "$TMP/repo" checkout -q main
printf updated > "$TMP/repo/main-only"; git -C "$TMP/repo" add main-only; git -C "$TMP/repo" commit -qm main
git -C "$TMP/repo" push -q origin main
printf '[]\n' > "$TMP/state/comments"
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  'api user') echo '{"login":"bot"}' ;;
  'api repos/acme/toy/issues/12') echo '{"number":12,"title":"test","body":"## Acceptance\n- test","html_url":"https://github.com/acme/toy/issues/12","labels":[{"name":"fleet:in_review"}]}' ;;
  'api --paginate repos/acme/toy/issues/12/comments') cat "$STATE/comments" ;;
  'api -X POST repos/acme/toy/issues/12/comments --input -') body="$(cat)"; jq --argjson x "$body" '. + [{id:555,user:{login:"bot"},body:$x.body}]' "$STATE/comments" > "$STATE/new" && mv "$STATE/new" "$STATE/comments"; echo '{"id":555}' ;;
  'api -X PATCH repos/acme/toy/issues/comments/555 --input -') body="$(cat)"; jq --argjson x "$body" 'map(if .id == 555 then .body = $x.body else . end)' "$STATE/comments" > "$STATE/new" && mv "$STATE/new" "$STATE/comments"; echo '{}' ;;
  'api -X PUT repos/acme/toy/issues/comments/555/pin') echo '{}' ;;
  'pr view 34 --repo acme/toy --json number,state,headRefName,headRefOid,baseRefName,headRepositoryOwner,headRepository,body') sha="$(git --git-dir="$REMOTE" rev-parse refs/heads/fleet/12-example)"; [ ! -f "$STATE/stale" ] || sha=0000000000000000000000000000000000000000; jq -n --arg sha "$sha" '{number:34,state:"OPEN",headRefName:"fleet/12-example",headRefOid:$sha,baseRefName:"main",headRepositoryOwner:{login:"acme"},headRepository:{name:"toy"},body:"<!-- fleet-board:card:12 -->"}' ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
GH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" STATE="$TMP/state" REMOTE="$TMP/remote.git" FLEET_BOARD_STANDALONE_FIXTURE=1 FLEET_BOARD_FIXTURE_ROOT="$TMP"
cd "$TMP/repo" || exit 1
jq -n --arg sha "$BEFORE" '{pr:34,round:1,last_review:{sha:$sha,round:1,critical:0,important:0,findings:[]}}' > "$TMP/patch"
bash "$TESTS/../scripts/note.sh" merge 12 "$TMP/patch" || exit 1
jq -n '{number:12,state:"in_review",action:"update_branch",pr:34,branch:"fleet/12-example",worktree:"/unused",reason:"conflicts"}' > "$TMP/card"
if [ "$1" = update-stale ]; then
  touch "$STATE/stale"
  if bash "$HANDLER" "$TMP/card" "$TMP/scratch"; then echo 'FAIL: stale PR accepted' >&2; exit 1; fi
  [ "$(git --git-dir="$REMOTE" rev-parse refs/heads/fleet/12-example)" = "$BEFORE" ] || exit 1
else
  bash "$HANDLER" "$TMP/card" "$TMP/scratch" || exit 1
  AFTER="$(git --git-dir="$REMOTE" rev-parse refs/heads/fleet/12-example)"
  [ "$AFTER" != "$BEFORE" ] && git --git-dir="$REMOTE" merge-base --is-ancestor "$BEFORE" "$AFTER" || exit 1
  note="$(bash "$TESTS/../scripts/note.sh" get 12)" || exit 1
  jq -e --arg sha "$AFTER" '.last_review == null and .last_update.sha == $sha' <<<"$note" >/dev/null || { echo 'FAIL: updated head was not sent for re-review' >&2; exit 1; }
fi
echo "PASS: $1"
