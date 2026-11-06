#!/usr/bin/env bash
# Two independent cards, a real local Git remote and a stateful fake GitHub.
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
printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\nlimits:\n  concurrency: 2\n' > "$TMP/repo/.fleet-board.yml"
git -C "$TMP/repo" add .fleet-board.yml
git -C "$TMP/repo" commit -qm initial
git -C "$TMP/repo" remote add origin https://github.com/acme/toy.git
git -C "$TMP/repo" config "url.file://$TMP/remote.git.insteadOf" https://github.com/acme/toy.git
git -C "$TMP/repo" push -q -u origin main
git --git-dir="$TMP/remote.git" symbolic-ref HEAD refs/heads/main
for n in 12 13; do printf ready > "$TMP/state/column-$n"; printf '[]\n' > "$TMP/state/comments-$n"; done
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "$GH_STATE/calls"
case "$1 $2" in
  'api user') echo '{"login":"fleet-bot"}' ;;
  'issue list')
    label="$6"; rows='[]'
    for n in 12 13; do
      column="$(cat "$GH_STATE/column-$n")"; [ "$label" = "fleet:$column" ] || continue
      if [ "$n" = 12 ]; then title='Add subtract'; else title='Add multiply'; fi
      rows="$(jq -cn --argjson rows "$rows" --argjson n "$n" --arg title "$title" --arg label "$label" '$rows + [{number:$n,title:$title,url:("https://github.com/acme/toy/issues/" + ($n|tostring)),labels:[{name:$label}]}]')"
    done
    printf '%s\n' "$rows" ;;
  'issue edit')
    n="$3"; flag="$6"; label="$7"
    if [ "$flag" = --remove-label ]; then printf none > "$GH_STATE/column-$n"; else printf '%s' "${label#fleet:}" > "$GH_STATE/column-$n"; fi ;;
  'issue comment')
    n="$3"; jq --rawfile body "$7" '. + [{id:900,user:{login:"fleet-bot"},body:$body}]' "$GH_STATE/comments-$n" > "$GH_STATE/tmp-$n" && mv "$GH_STATE/tmp-$n" "$GH_STATE/comments-$n" ;;
  'pr list')
    branch=''; while [ "$#" -gt 0 ]; do if [ "$1" = --head ]; then branch="$2"; break; fi; shift; done
    case "$branch" in fleet/12-*) n=12; pr=34 ;; fleet/13-*) n=13; pr=35 ;; *) exit 1 ;; esac
    if [ -e "$GH_STATE/pr-$n" ]; then printf '[{"number":%s}]\n' "$pr"; else echo '[]'; fi ;;
  'pr create')
    if [ "${GH_HOLD_CREATE:-}" = 1 ] && [ ! -e "$GH_STATE/held-once" ]; then
      touch "$GH_STATE/held-once" "$GH_STATE/create-blocked"
      while [ ! -e "$GH_STATE/release-create" ]; do sleep 1; done
    fi
    branch=''; while [ "$#" -gt 0 ]; do if [ "$1" = --head ]; then branch="$2"; break; fi; shift; done
    case "$branch" in fleet/12-*) n=12; pr=34 ;; fleet/13-*) n=13; pr=35 ;; *) exit 1 ;; esac
    touch "$GH_STATE/pr-$n"; printf 'https://github.com/acme/toy/pull/%s\n' "$pr" ;;
  'pr view')
    pr="$3"; case "$pr" in 34) branch=fleet/12-add-subtract; n=12 ;; 35) branch=fleet/13-add-multiply; n=13 ;; *) exit 1 ;; esac
    sha="$(git --git-dir="$GH_REMOTE" rev-parse "refs/heads/$branch")" || exit 1
    jq -n --argjson pr "$pr" --argjson n "$n" --arg branch "$branch" --arg sha "$sha" '{number:$pr,isDraft:true,state:"OPEN",headRefName:$branch,headRefOid:$sha,baseRefName:"main",headRepositoryOwner:{login:"acme"},headRepository:{name:"toy"},body:("Closes #" + ($n|tostring) + "\n\n<!-- fleet-board:card:" + ($n|tostring) + " -->")}' ;;
  'api --paginate')
    path="$3"; n="${path%/comments}"; n="${n##*/}"; cat "$GH_STATE/comments-$n" ;;
  'api -X')
    method="$3"; path="$4"
    case "$method:$path" in
      POST:repos/acme/toy/issues/*/comments)
        n="${path%/comments}"; n="${n##*/}"; body="$(cat)"; id=$((500+n))
        jq --argjson x "$body" --argjson id "$id" '. + [{id:$id,user:{login:"fleet-bot"},body:$x.body}]' "$GH_STATE/comments-$n" > "$GH_STATE/tmp-$n" && mv "$GH_STATE/tmp-$n" "$GH_STATE/comments-$n"
        printf '{"id":%s}\n' "$id" ;;
      PUT:repos/acme/toy/issues/comments/*/pin) echo '{}' ;;
      *) echo "unexpected API mutation: $*" >&2; exit 1 ;;
    esac ;;
  'api repos/acme/toy/issues/'*)
    n="${2##*/}"; column="$(cat "$GH_STATE/column-$n")"
    if [ "$n" = 12 ]; then title='Add subtract'; else title='Add multiply'; fi
    body='## Acceptance
- complete the card'
    if [ "$n" = 13 ] && [ "${GH_SKIP13:-}" = 1 ]; then body='No acceptance section yet.'; fi
    jq -n --argjson n "$n" --arg title "$title" --arg label "fleet:$column" --arg body "$body" '{number:$n,title:$title,html_url:("https://github.com/acme/toy/issues/" + ($n|tostring)),body:$body,labels:[{name:$label}]}' ;;
  *) echo "unexpected gh: $*" >&2; exit 1 ;;
esac
GH
chmod +x "$TMP/bin/gh"
cat > "$TMP/worker.sh" <<'WORKER'
#!/bin/sh
set -eu
if grep -q '"card": 12' /scratch/request.json; then n=12; else n=13; fi
printf 'implemented\n' > "card-$n.txt"
git add "card-$n.txt"
git -c user.name=Fixture -c user.email=fixture@example.com commit -qm implement
printf '%s\n' '{"version":1,"outcome":"done","report":"## Status\ndone\n## Findings\n- none\n## For the card\nImplemented\n## PR\n#1\nVERIFIED: `true` -> 0 failures"}' > /scratch/result.json
WORKER
if [ "${1:-multi-card}" = multi-card-parallel ]; then
  MARKER="fixture-ready-$(basename "$TMP")"
  python3 - "$TMP/worker.sh" "$MARKER" <<'PY_WORKER'
import sys
p, marker = sys.argv[1:]
s = open(p).read()
needle = 'git add "card-$n.txt"'
assert needle in s
s = s.replace(needle, 'hostname > "/scratch/' + marker + '-$n"\nwhile [ ! -e /scratch/release ]; do sleep 1; done\n' + needle)
open(p, 'w').write(s)
PY_WORKER
fi
export PATH="$TMP/bin:$PATH" GH_STATE="$TMP/state" GH_REMOTE="$TMP/remote.git"
if [ "${1:-multi-card}" = multi-card-skip ]; then export GH_SKIP13=1; fi
export FLEET_BOARD_STANDALONE_FIXTURE=1 FLEET_BOARD_FIXTURE_ROOT="$TMP"
export FLEET_BOARD_WORKER_SCRIPT="$TMP/worker.sh" FLEET_BOARD_WORKER_IMAGE=ghcr.io/home-assistant/home-assistant:stable
cd "$TMP/repo"
if [ "${1:-multi-card}" = multi-card-provider ]; then
  bash "$ROOT/plugins/fleet-board/scripts/tick-plan.sh" > "$TMP/base-plan" || exit 1
  jq '.cards[1].action = "review_stage" | .cards[1].state = "review_security" | .cards[1].stage = {name:"security",agent:null,provider:"openai",model:"test"}' "$TMP/base-plan" > "$TMP/provider-plan"
  cat > "$TMP/planner" <<PLAN
#!/bin/bash
cat "$TMP/provider-plan"
PLAN
  if FLEET_BOARD_TICK_PLAN="$TMP/planner" bash "$ROOT/bin/fleet-board" tick > "$TMP/provider-out" 2> "$TMP/provider-err"; then echo 'FAIL: unsupported provider stage accepted' >&2; exit 1; fi
  if git --git-dir="$TMP/remote.git" show-ref --verify --quiet refs/heads/fleet/12-add-subtract || [ -e "$TMP/state/pr-12" ]; then echo 'FAIL: earlier card published before unsupported provider rejected' >&2; exit 1; fi
  [ "$(cat "$TMP/state/column-12")" = ready ] || { echo 'FAIL: earlier card moved before provider rejection' >&2; exit 1; }
  echo 'PASS: multi-card-provider'
  exit 0
fi
if [ "${1:-multi-card}" = multi-card-parallel ]; then
  bash "$ROOT/bin/fleet-board" tick > "$TMP/out" 2> "$TMP/first-err" & TICK_PID=$!
  READY=""
  for unused in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    READY="$(find "${TMPDIR:-/tmp}" -name "$MARKER-*" -type f -print 2>/dev/null)"
    [ "$(printf '%s\n' "$READY" | sed '/^$/d' | wc -l | tr -d ' ')" -ge 2 ] && break
    sleep 1
  done
  if [ "$(printf '%s\n' "$READY" | sed '/^$/d' | wc -l | tr -d ' ')" -lt 2 ]; then
    kill -TERM "$TICK_PID" 2>/dev/null || true
    for unused in 1 2 3 4 5 6 7 8 9 10 11 12; do kill -0 "$TICK_PID" 2>/dev/null || break; sleep 1; done
    kill -KILL "$TICK_PID" 2>/dev/null || true; wait "$TICK_PID" 2>/dev/null || true
    while IFS= read -r path; do [ -n "$path" ] && [ -f "$path" ] || continue; docker rm -f "$(cat "$path")" >/dev/null 2>&1 || true; done <<<"$READY"
    cat "$TMP/first-err" >&2; echo 'FAIL: two workers did not overlap' >&2; exit 1
  fi
  while IFS= read -r path; do [ -n "$path" ] || continue; touch "$(dirname "$path")/release"; done <<<"$READY"
  wait "$TICK_PID" || { cat "$TMP/first-err" >&2; echo 'FAIL: parallel tick failed after release' >&2; exit 1; }
elif [ "${1:-multi-card}" = multi-card-lock ]; then
  export GH_HOLD_CREATE=1
  bash "$ROOT/bin/fleet-board" tick > "$TMP/out" 2> "$TMP/first-err" & TICK_PID=$!
  for unused in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do [ -e "$TMP/state/create-blocked" ] && break; sleep 1; done
  if [ ! -e "$TMP/state/create-blocked" ]; then
    touch "$TMP/state/release-create"; kill -TERM "$TICK_PID" 2>/dev/null || true; wait "$TICK_PID" 2>/dev/null || true
    cat "$TMP/first-err" >&2; echo 'FAIL: first tick did not reach held publication' >&2; exit 1
  fi
  if bash "$ROOT/bin/fleet-board" tick > "$TMP/second-out" 2> "$TMP/second-err"; then
    touch "$TMP/state/release-create"; wait "$TICK_PID" 2>/dev/null || true
    echo 'FAIL: concurrent tick acquired repository lock' >&2; exit 1
  fi
  if ! grep -q 'another standalone tick holds the repository lock' "$TMP/second-err"; then
    touch "$TMP/state/release-create"; wait "$TICK_PID" 2>/dev/null || true
    echo 'FAIL: concurrent tick did not fail on repository lock' >&2; exit 1
  fi
  [ "$(grep -c '^pr create ' "$TMP/state/calls")" = 1 ] || { touch "$TMP/state/release-create"; wait "$TICK_PID" 2>/dev/null || true; echo 'FAIL: duplicate dispatch during lock' >&2; exit 1; }
  touch "$TMP/state/release-create"
  wait "$TICK_PID" || { cat "$TMP/first-err" >&2; echo 'FAIL: first tick failed after release' >&2; exit 1; }
else
  if ! bash "$ROOT/bin/fleet-board" tick > "$TMP/out"; then echo 'FAIL: multi-card tick failed' >&2; exit 1; fi
fi
if [ "${1:-multi-card}" = multi-card-skip ]; then
  jq -e '.outcome == "progress" and ([.cards[].action] == ["start","skip_no_acceptance"])' "$TMP/out" >/dev/null || { echo 'FAIL: mixed actions not reported' >&2; exit 1; }
  [ "$(cat "$TMP/state/column-13")" = ready ] && [ ! -e "$TMP/state/pr-13" ] || { echo 'FAIL: card without acceptance progressed' >&2; exit 1; }
  jq -e 'any(.[]; .body | startswith("<!-- fleet-board:skip-no-acceptance -->"))' "$TMP/state/comments-13" >/dev/null || { echo 'FAIL: missing acceptance comment' >&2; exit 1; }
  NUMBERS=12
else
  jq -e '.outcome == "progress" and ([.cards[].action] == ["start","start"])' "$TMP/out" >/dev/null || { echo 'FAIL: both actions not reported' >&2; exit 1; }
  NUMBERS='12 13'
fi
for n in $NUMBERS; do
  [ "$(cat "$TMP/state/column-$n")" = in_progress ] && [ -e "$TMP/state/pr-$n" ] || { echo "FAIL: card $n did not progress" >&2; exit 1; }
  if [ "$n" = 12 ]; then branch=fleet/12-add-subtract; else branch=fleet/13-add-multiply; fi
  git --git-dir="$TMP/remote.git" cat-file -e "$branch:card-$n.txt" || { echo "FAIL: card $n commit missing" >&2; exit 1; }
done
echo "PASS: ${1:-multi-card}"
