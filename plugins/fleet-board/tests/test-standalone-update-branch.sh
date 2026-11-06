#!/usr/bin/env bash
set -uo pipefail
unset CDPATH
case "${1:-}" in update-branch|update-stale|update-conflict|update-resume|update-cycle|update-rewind) ;; *) echo 'usage: test-standalone-update-branch.sh update-branch|update-stale' >&2; exit 2 ;; esac
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
printf branch > "$TMP/repo/branch"; if [ "$1" = update-conflict ]; then printf branch > "$TMP/repo/base"; fi; git -C "$TMP/repo" add branch base; git -C "$TMP/repo" commit -qm branch
git -C "$TMP/repo" push -q origin fleet/12-example
BEFORE="$(git -C "$TMP/repo" rev-parse HEAD)"
git -C "$TMP/repo" checkout -q main
printf updated > "$TMP/repo/main-only"; if [ "$1" = update-conflict ]; then printf main > "$TMP/repo/base"; fi; git -C "$TMP/repo" add main-only base; git -C "$TMP/repo" commit -qm main
git -C "$TMP/repo" push -q origin main
printf '[]\n' > "$TMP/state/comments"
printf in_review > "$TMP/state/column"
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  'api user') echo '{"login":"bot"}' ;;
  'api repos/acme/toy/issues/12') column="$(cat "$GH_STATE/column")"; jq -n --arg col "$column" '{number:12,title:"test",body:"## Acceptance\n- test",html_url:"https://github.com/acme/toy/issues/12",labels:(if $col == "none" then [] else [{name:("fleet:"+$col)}] end)}' ;;
  'issue edit 12 --repo acme/toy --remove-label fleet:'*) printf none > "$GH_STATE/column" ;;
  'issue edit 12 --repo acme/toy --add-label fleet:'*) printf '%s' "${7#fleet:}" > "$GH_STATE/column" ;;
  'issue comment 12 --repo acme/toy --body-file '*) jq --rawfile body "$7" '. + [{id:556,user:{login:"bot"},body:$body}]' "$GH_STATE/comments" > "$GH_STATE/new" && mv "$GH_STATE/new" "$GH_STATE/comments" ;;
  'api --paginate repos/acme/toy/issues/12/comments') cat "$GH_STATE/comments" ;;
  'api -X POST repos/acme/toy/issues/12/comments --input -') body="$(cat)"; jq --argjson x "$body" '. + [{id:555,user:{login:"bot"},body:$x.body}]' "$GH_STATE/comments" > "$GH_STATE/new" && mv "$GH_STATE/new" "$GH_STATE/comments"; echo '{"id":555}' ;;
  'api -X PATCH repos/acme/toy/issues/comments/555 --input -') if [ -e "$GH_STATE/fail-patch" ]; then rm "$GH_STATE/fail-patch"; exit 1; fi; body="$(cat)"; jq --argjson x "$body" 'map(if .id == 555 then .body = $x.body else . end)' "$GH_STATE/comments" > "$GH_STATE/new" && mv "$GH_STATE/new" "$GH_STATE/comments"; echo '{}' ;;
  'api -X PUT repos/acme/toy/issues/comments/555/pin') echo '{}' ;;
  'pr view 34 --repo acme/toy --json number,state,headRefName,headRefOid,baseRefName,headRepositoryOwner,headRepository,body') sha="$(git --git-dir="$GH_REMOTE" rev-parse refs/heads/fleet/12-example)"; [ ! -f "$GH_STATE/stale" ] || sha=0000000000000000000000000000000000000000; jq -n --arg sha "$sha" '{number:34,state:"OPEN",headRefName:"fleet/12-example",headRefOid:$sha,baseRefName:"main",headRepositoryOwner:{login:"acme"},headRepository:{name:"toy"},body:"<!-- fleet-board:card:12 -->"}' ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
GH
chmod +x "$TMP/bin/gh"
REAL_GIT="$(command -v git)"; export REAL_GIT
cat > "$TMP/bin/git" <<'GIT'
#!/usr/bin/env bash
case " $* " in
  *' push '*) if [ -e "$GH_STATE/rewind" ]; then
    rm "$GH_STATE/rewind"
    "$REAL_GIT" --git-dir="$GH_REMOTE" update-ref refs/heads/fleet/12-example "$REWIND_SHA" || exit 1
  fi ;;
esac
exec "$REAL_GIT" "$@"
GIT
chmod +x "$TMP/bin/git"
export PATH="$TMP/bin:$PATH" GH_STATE="$TMP/state" GH_REMOTE="$TMP/remote.git" FLEET_BOARD_STANDALONE_FIXTURE=1 FLEET_BOARD_FIXTURE_ROOT="$TMP"
cd "$TMP/repo" || exit 1
jq -n --arg sha "$BEFORE" '{pr:34,round:1,last_review:{sha:$sha,round:1,critical:0,important:0,findings:[]}}' > "$TMP/patch"
bash "$TESTS/../scripts/note.sh" merge 12 "$TMP/patch" || exit 1
jq -n '{number:12,state:"in_review",action:"update_branch",pr:34,branch:"fleet/12-example",worktree:"/unused",reason:"conflicts"}' > "$TMP/card"
if [ "$1" = update-rewind ]; then
  export REWIND_SHA="$(git --git-dir="$GH_REMOTE" rev-parse "$BEFORE^")"
  touch "$GH_STATE/rewind"
  if bash "$HANDLER" "$TMP/card" "$TMP/scratch"; then echo 'FAIL: branch rewind accepted' >&2; exit 1; fi
  [ "$(git --git-dir="$GH_REMOTE" rev-parse refs/heads/fleet/12-example)" = "$REWIND_SHA" ] || { echo 'FAIL: rewound remote branch overwritten' >&2; exit 1; }
  note="$(bash "$TESTS/../scripts/note.sh" get 12)" || exit 1
  jq -e --arg sha "$BEFORE" '.last_review.sha == $sha' <<<"$note" >/dev/null || exit 1
elif [ "$1" = update-stale ]; then
  touch "$GH_STATE/stale"
  if bash "$HANDLER" "$TMP/card" "$TMP/scratch"; then echo 'FAIL: stale PR accepted' >&2; exit 1; fi
  [ "$(git --git-dir="$GH_REMOTE" rev-parse refs/heads/fleet/12-example)" = "$BEFORE" ] || exit 1
elif [ "$1" = update-conflict ]; then
  bash "$HANDLER" "$TMP/card" "$TMP/scratch" || exit 1
  [ "$(cat "$GH_STATE/column")" = blocked ] || { echo 'FAIL: conflict did not block card' >&2; exit 1; }
  [ "$(git --git-dir="$GH_REMOTE" rev-parse refs/heads/fleet/12-example)" = "$BEFORE" ] || exit 1
  jq -e 'any(.[]; .body | contains("base"))' "$GH_STATE/comments" >/dev/null || exit 1
else
  if [ "$1" = update-resume ]; then
    touch "$GH_STATE/fail-patch"
    if bash "$HANDLER" "$TMP/card" "$TMP/scratch"; then echo 'FAIL: failed note accepted' >&2; exit 1; fi
    first="$(git --git-dir="$GH_REMOTE" rev-parse refs/heads/fleet/12-example)"
    [ "$first" != "$BEFORE" ] || exit 1
  fi
  bash "$HANDLER" "$TMP/card" "$TMP/scratch" || exit 1
  if [ "$1" = update-resume ]; then [ "$(git --git-dir="$GH_REMOTE" rev-parse refs/heads/fleet/12-example)" = "$first" ] || exit 1; fi
  AFTER="$(git --git-dir="$GH_REMOTE" rev-parse refs/heads/fleet/12-example)"
  if [ "$1" = update-cycle ]; then
    first="$AFTER"
    printf second > "$TMP/repo/main-again"; git -C "$TMP/repo" add main-again; git -C "$TMP/repo" commit -qm second; git -C "$TMP/repo" push -q origin main
    bash "$HANDLER" "$TMP/card" "$TMP/scratch" || exit 1
    AFTER="$(git --git-dir="$GH_REMOTE" rev-parse refs/heads/fleet/12-example)"
    [ "$AFTER" != "$first" ] || { echo 'FAIL: second branch update ignored' >&2; exit 1; }
  fi
  [ "$AFTER" != "$BEFORE" ] && git --git-dir="$GH_REMOTE" merge-base --is-ancestor "$BEFORE" "$AFTER" || exit 1
  note="$(bash "$TESTS/../scripts/note.sh" get 12)" || exit 1
  jq -e --arg sha "$AFTER" '.last_review == null and .last_update.sha == $sha' <<<"$note" >/dev/null || { echo 'FAIL: updated head was not sent for re-review' >&2; exit 1; }
fi
echo "PASS: $1"
