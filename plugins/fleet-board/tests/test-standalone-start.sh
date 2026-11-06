#!/usr/bin/env bash
# One start action through the standalone CLI with a real local Git remote.
set -uo pipefail
unset CDPATH
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo" "$TMP/bin" "$TMP/state"
git init -q --bare "$TMP/remote.git"
git -C "$TMP/repo" init -q -b main
git -C "$TMP/repo" config user.name Test
git -C "$TMP/repo" config user.email test@example.com
printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\n' > "$TMP/repo/.fleet-board.yml"
printf 'before\n' > "$TMP/repo/source.txt"
git -C "$TMP/repo" add .
git -C "$TMP/repo" commit -qm initial
git -C "$TMP/repo" remote add origin https://github.com/acme/toy.git
git -C "$TMP/repo" config "url.file://$TMP/remote.git.insteadOf" https://github.com/acme/toy.git
git -C "$TMP/repo" push -q -u origin main
git --git-dir="$TMP/remote.git" symbolic-ref HEAD refs/heads/main
printf ready > "$TMP/state/column"
printf '[]\n' > "$TMP/state/comments"
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "$GH_STATE/calls"
case "$*" in
  'api user') printf '{"login":"fleet-bot"}\n' ;;
  'api repos/acme/toy/issues/12')
    column="$(cat "$GH_STATE/column")"
    jq -n --arg label "fleet:$column" '{number:12,title:"Add subtract",html_url:"https://github.com/acme/toy/issues/12",body:"Subtract.\n\n## Acceptance\n- subtract two numbers\n",labels:[{name:$label}]}' ;;
  'api --paginate repos/acme/toy/issues/12/comments') cat "$GH_STATE/comments" ;;
  'issue list --repo acme/toy --label fleet:ready '*)
    if [ "$(cat "$GH_STATE/column")" = ready ]; then printf '[{"number":12,"title":"Add subtract","url":"https://github.com/acme/toy/issues/12","labels":[{"name":"fleet:ready"}]}]\n'; else echo '[]'; fi ;;
  'issue list --repo acme/toy --label '*) echo '[]' ;;
  'issue edit 12 --repo acme/toy --remove-label fleet:ready') : ;;
  'issue edit 12 --repo acme/toy --add-label fleet:in_progress')
    if [ -e "$GH_STATE/fail-move" ]; then rm "$GH_STATE/fail-move"; exit 1; fi
    printf in_progress > "$GH_STATE/column" ;;
  'issue comment 12 --repo acme/toy --body-file '*)
    jq --rawfile body "$6" '. + [{id:556,user:{login:"fleet-bot"},body:$body}]' "$GH_STATE/comments" > "$GH_STATE/new-comments"
    mv "$GH_STATE/new-comments" "$GH_STATE/comments" ;;
  'api -X POST repos/acme/toy/issues/12/comments --input -')
    body="$(cat)"; jq --argjson x "$body" '. + [{id:555,user:{login:"fleet-bot"},body:$x.body}]' "$GH_STATE/comments" > "$GH_STATE/new-comments"; mv "$GH_STATE/new-comments" "$GH_STATE/comments"; echo '{"id":555}' ;;
  'api -X PUT repos/acme/toy/issues/comments/555/pin') echo '{}' ;;
  'pr list '*) if [ -e "$GH_STATE/pr" ]; then echo '[{"number":34}]'; else echo '[]'; fi ;;
  'pr create '*) touch "$GH_STATE/pr"; echo 'https://github.com/acme/toy/pull/34' ;;
  'pr view '*)
    sha="$(git --git-dir="$GH_REMOTE" rev-parse refs/heads/fleet/12-add-subtract)" || exit 1
    jq -n --arg sha "$sha" '{number:34,isDraft:true,state:"OPEN",headRefName:"fleet/12-add-subtract",headRefOid:$sha,baseRefName:"main",baseRepositoryOwner:{login:"acme"},baseRepository:{name:"toy"},headRepositoryOwner:{login:"acme"},headRepository:{name:"toy"}}' ;;
  *) echo "unexpected gh: $*" >&2; exit 1 ;;
esac
GH
chmod +x "$TMP/bin/gh"
cat > "$TMP/worker.sh" <<'WORKER'
#!/bin/sh
set -eu
printf 'after\n' > source.txt
git add source.txt
git -c user.name=Fixture -c user.email=fixture@example.com commit -qm implement
git config core.fsmonitor '@HOOK@'
printf '%s\n' '{"version":1,"outcome":"done","report":"## Status\ndone\n## Findings\n- none\n## For the card\nImplemented\n## PR\n#34\nVERIFIED: `cat source.txt` -> 1 file"}' > /scratch/result.json
WORKER
cat > "$TMP/host-hook" <<HOOK
#!/bin/sh
touch "$TMP/hook-ran"
HOOK
chmod +x "$TMP/host-hook"
sed "s|@HOOK@|$TMP/host-hook|" "$TMP/worker.sh" > "$TMP/worker.tmp"
mv "$TMP/worker.tmp" "$TMP/worker.sh"
export PATH="$TMP/bin:$PATH" GH_STATE="$TMP/state" GH_REMOTE="$TMP/remote.git"
export FLEET_BOARD_STANDALONE_FIXTURE=1 FLEET_BOARD_FIXTURE_ROOT="$TMP"
export FLEET_BOARD_WORKER_SCRIPT="$TMP/worker.sh" FLEET_BOARD_WORKER_IMAGE=ghcr.io/home-assistant/home-assistant:stable
cd "$TMP/repo"
if [ "${1:-start}" = resume ]; then
  touch "$TMP/state/fail-move"
  if bash "$ROOT/bin/fleet-board" tick > "$TMP/first-out" 2>/dev/null; then echo 'FAIL: simulated interruption succeeded' >&2; exit 1; fi
  [ -e "$TMP/state/pr" ] || { echo 'FAIL: interruption preceded PR creation' >&2; exit 1; }
  jq -e '[.[] | select(.body | contains("fleet-board:standalone-start:"))] | length == 1' "$TMP/state/comments" >/dev/null || { echo 'FAIL: official report missing before interruption' >&2; exit 1; }
fi
if ! bash "$ROOT/bin/fleet-board" tick > "$TMP/out"; then echo 'FAIL: start tick failed' >&2; exit 1; fi
[ ! -e "$TMP/hook-ran" ] || { echo 'FAIL: worker Git config executed on controller' >&2; exit 1; }
if ! jq -e '.outcome == "progress" and .cards[0].action == "start"' "$TMP/out" >/dev/null; then echo 'FAIL: start outcome' >&2; exit 1; fi
[ "$(cat "$TMP/state/column")" = in_progress ] || { echo 'FAIL: card did not move' >&2; exit 1; }
[ -e "$TMP/state/pr" ] || { echo 'FAIL: draft PR missing' >&2; exit 1; }
[ "$(git --git-dir="$TMP/remote.git" show fleet/12-add-subtract:source.txt)" = after ] || { echo 'FAIL: worker commit not published' >&2; exit 1; }
jq -e 'any(.[]; .body | contains("\"pr\": 34"))' "$TMP/state/comments" >/dev/null || { echo 'FAIL: verified PR not recorded' >&2; exit 1; }
if [ "${1:-start}" = resume ]; then
  jq -e '[.[] | select(.body | contains("fleet-board:standalone-start:"))] | length == 1' "$TMP/state/comments" >/dev/null || { echo 'FAIL: report duplicated' >&2; exit 1; }
  [ "$(grep -c '^pr create ' "$TMP/state/calls")" = 1 ] || { echo 'FAIL: draft PR duplicated' >&2; exit 1; }
fi
echo "PASS: ${1:-start}"
