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
printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\nmerge:\n  policy: auto\n' > "$TMP/repo/.fleet-board.yml"
if [ "${1:-start}" = projects-review ] || [ "${1:-start}" = projects-qa-race ]; then
  printf 'board:\n  backend: github-projects\n  repo: acme/toy\n  project_number: 1\nworktrees:\n  dir: .fw\nmerge:\n  policy: auto\n' > "$TMP/repo/.fleet-board.yml"
  export GH_PROJECT=1
fi
if [ "${1:-start}" = advisory-stage ] || [ "${1:-start}" = stage-fix ] || [ "${1:-start}" = stage-standard ]; then
  cat >> "$TMP/repo/.fleet-board.yml" <<'YML'
review:
  stages:
    - name: security
      agent: fixture-reviewer
      model: opus
      paths: ["source.txt"]
      label: needs-security-review
      advisory: true
YML
  if [ "${1:-start}" = stage-fix ]; then sed 's/advisory: true/advisory: false/' "$TMP/repo/.fleet-board.yml" > "$TMP/repo/config.tmp" && mv "$TMP/repo/config.tmp" "$TMP/repo/.fleet-board.yml"; fi
  if [ "${1:-start}" = stage-standard ]; then sed 's/name: security/name: standard/' "$TMP/repo/.fleet-board.yml" > "$TMP/repo/config.tmp" && mv "$TMP/repo/config.tmp" "$TMP/repo/.fleet-board.yml"; fi
fi
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
  'auth status') echo authenticated ;;
  'project view 1 --owner acme --format json') echo '{"id":"PVT_fixture"}' ;;
  'project field-list 1 --owner acme --format json --limit 100')
    jq -n '{fields:[{name:"Status",id:"field",options:[{name:"Backlog",id:"backlog"},{name:"Ready",id:"ready"},{name:"In Progress",id:"in_progress"},{name:"In Review",id:"in_review"},{name:"Human QA",id:"human_qa"},{name:"Blocked",id:"blocked"},{name:"Done",id:"done"},{name:"Wont Do",id:"wont_do"}]}]}' ;;
  'project item-list 1 --owner acme --format json --limit '*)
    column="$(cat "$GH_STATE/column")"
    case "$column" in ready) status=Ready ;; in_progress) status='In Progress' ;; in_review) status='In Review' ;; human_qa) status='Human QA' ;; done) status=Done ;; *) status='' ;; esac
    jq -n --arg status "$status" '{items:[{status:$status,content:{type:"Issue",repository:"acme/toy",number:12,title:"Add subtract",url:"https://github.com/acme/toy/issues/12"}}]}' ;;
  'api graphql '*)
    if [ -e "$GH_STATE/project-move-race" ] && jq -e 'any(.[]; .body | contains("fleet-board:standalone-review:"))' "$GH_STATE/comments" >/dev/null; then
      count=0; [ ! -e "$GH_STATE/project-reads" ] || count="$(cat "$GH_STATE/project-reads")"
      count=$((count + 1)); printf '%s' "$count" > "$GH_STATE/project-reads"
      if [ "$count" -eq 2 ]; then printf human_qa > "$GH_STATE/column"; fi
    fi
    column="$(cat "$GH_STATE/column")"
    case "$column" in ready) status=Ready ;; in_progress) status='In Progress' ;; in_review) status='In Review' ;; human_qa) status='Human QA' ;; done) status=Done ;; *) status='' ;; esac
    jq -n --arg status "$status" '{data:{repository:{issue:{projectItems:{nodes:[{id:"ITEM_fixture",project:{number:1},fieldValueByName:{name:$status}}]}}}}}' ;;
  'project item-edit '*)
    for value in "$@"; do :; done
    case "$value" in ready|in_progress|in_review|human_qa|done) printf '%s' "$value" > "$GH_STATE/column" ;; *) exit 1 ;; esac
    echo '{}' ;;

  'api repos/acme/toy/compare/'*) echo '{"commits":[]}' ;;
  'api repos/acme/toy/issues/12')
    if [ -e "$GH_STATE/move-at-adapter" ] && jq -e 'any(.[]; .body | contains("fleet-board:standalone-review:"))' "$GH_STATE/comments" >/dev/null; then
      count=0; [ ! -e "$GH_STATE/adapter-reads" ] || count="$(cat "$GH_STATE/adapter-reads")"
      count=$((count + 1)); printf '%s' "$count" > "$GH_STATE/adapter-reads"
      if [ "$count" -eq 2 ]; then printf human_qa > "$GH_STATE/column"; fi
    fi
    column="$(cat "$GH_STATE/column")"
    qa=false; [ ! -e "$GH_STATE/qa-flag" ] || qa=true
    stage=false; [ ! -e "$GH_STATE/stage-label" ] || stage=true
    project=false; [ "${GH_PROJECT:-}" != 1 ] || project=true
    jq -n --arg label "fleet:$column" --argjson qa "$qa" --argjson stage "$stage" --argjson project "$project" '{number:12,title:"Add subtract",html_url:"https://github.com/acme/toy/issues/12",body:"Subtract.\n\n## Acceptance\n- subtract two numbers\n",labels:((if $project then [] else [{name:$label}] end) + (if $qa then [{name:"needs-human-qa"}] else [] end) + (if $stage then [{name:"needs-security-review"}] else [] end))}' ;;
  'api --paginate repos/acme/toy/issues/12/comments') cat "$GH_STATE/comments" ;;
  'issue list --repo acme/toy --label fleet:ready '*)
    if [ "$(cat "$GH_STATE/column")" = ready ]; then printf '[{"number":12,"title":"Add subtract","url":"https://github.com/acme/toy/issues/12","labels":[{"name":"fleet:ready"}]}]\n'; else echo '[]'; fi ;;
  'issue list --repo acme/toy --label fleet:in_progress '*)
    if [ "$(cat "$GH_STATE/column")" = in_progress ]; then printf '[{"number":12,"title":"Add subtract","url":"https://github.com/acme/toy/issues/12","labels":[{"name":"fleet:in_progress"}]}]\n'; else echo '[]'; fi ;;
  'issue list --repo acme/toy --label fleet:in_review '*)
    if [ "$(cat "$GH_STATE/column")" = in_review ]; then printf '[{"number":12,"title":"Add subtract","url":"https://github.com/acme/toy/issues/12","labels":[{"name":"fleet:in_review"}]}]\n'; else echo '[]'; fi ;;
  'issue list --repo acme/toy --label fleet:review_security '*|'issue list --repo acme/toy --label fleet:review_standard '*)
    label="$6"; column="${label#fleet:}"
    if [ "$(cat "$GH_STATE/column")" = "$column" ]; then jq -n --arg label "$label" '[{number:12,title:"Add subtract",url:"https://github.com/acme/toy/issues/12",labels:[{name:$label}]}]'; else echo '[]'; fi ;;
  'issue list --repo acme/toy --label '*) echo '[]' ;;
  'issue edit 12 --repo acme/toy --remove-label fleet:ready'|'issue edit 12 --repo acme/toy --remove-label fleet:in_progress') printf none > "$GH_STATE/column" ;;
  'issue edit 12 --repo acme/toy --add-label needs-security-review') touch "$GH_STATE/stage-label" ;;
  'issue edit 12 --repo acme/toy --add-label fleet:review_security'|'issue edit 12 --repo acme/toy --add-label fleet:review_standard') printf '%s' "${7#fleet:}" > "$GH_STATE/column" ;;
  'issue edit 12 --repo acme/toy --add-label fleet:in_review')
    if [ -e "$GH_STATE/fail-review-move" ]; then rm "$GH_STATE/fail-review-move"; exit 1; fi
    printf in_review > "$GH_STATE/column" ;;
  'issue edit 12 --repo acme/toy --remove-label fleet:in_review') printf none > "$GH_STATE/column" ;;
  'issue edit 12 --repo acme/toy --add-label fleet:blocked') printf blocked > "$GH_STATE/column" ;;
  'issue edit 12 --repo acme/toy --add-label fleet:done')
    if [ -e "$GH_STATE/fail-done-move" ]; then rm "$GH_STATE/fail-done-move"; exit 1; fi
    printf done > "$GH_STATE/column" ;;
  'issue edit 12 --repo acme/toy --add-label fleet:human_qa')
    if [ -e "$GH_STATE/fail-qa-move" ]; then rm "$GH_STATE/fail-qa-move"; exit 1; fi
    printf human_qa > "$GH_STATE/column" ;;
  'issue edit 12 --repo acme/toy --add-label fleet:in_progress')
    if [ -e "$GH_STATE/fail-move" ]; then rm "$GH_STATE/fail-move"; exit 1; fi
    printf in_progress > "$GH_STATE/column" ;;
  'issue comment 12 --repo acme/toy --body-file '*)
    if [ -e "$GH_STATE/fail-blocked-report" ] && grep -q 'fleet-board:implementor-blocked:' "$7"; then rm "$GH_STATE/fail-blocked-report"; exit 1; fi
    jq --rawfile body "$7" '. + [{id:556,user:{login:"fleet-bot"},body:$body}]' "$GH_STATE/comments" > "$GH_STATE/new-comments" || exit 1
    mv "$GH_STATE/new-comments" "$GH_STATE/comments" ;;
  'api -X POST repos/acme/toy/issues/12/comments --input -')
    if [ -e "$GH_STATE/fail-note" ]; then rm "$GH_STATE/fail-note"; exit 1; fi
    body="$(cat)"; jq --argjson x "$body" '. + [{id:555,user:{login:"fleet-bot"},body:$x.body}]' "$GH_STATE/comments" > "$GH_STATE/new-comments"; mv "$GH_STATE/new-comments" "$GH_STATE/comments"; echo '{"id":555}' ;;
  'api -X PUT repos/acme/toy/issues/comments/555/pin') echo '{}' ;;
  'api -X PATCH repos/acme/toy/issues/comments/555 --input -')
    if [ -e "$GH_STATE/fail-patch" ]; then rm "$GH_STATE/fail-patch"; exit 1; fi
    if [ -e "$GH_STATE/fail-patch-at" ]; then
      count=0; [ ! -e "$GH_STATE/patch-count" ] || count="$(cat "$GH_STATE/patch-count")"
      count=$((count + 1)); printf '%s' "$count" > "$GH_STATE/patch-count"
      if [ "$count" = "$(cat "$GH_STATE/fail-patch-at")" ]; then rm "$GH_STATE/fail-patch-at"; exit 1; fi
    fi
    body="$(cat)"; jq --argjson x "$body" 'map(if .id == 555 then .body = $x.body else . end)' "$GH_STATE/comments" > "$GH_STATE/new-comments" || exit 1
    mv "$GH_STATE/new-comments" "$GH_STATE/comments"; echo '{}' ;;
  'pr list '*) if [ -e "$GH_STATE/pr" ]; then echo '[{"number":34}]'; else echo '[]'; fi ;;
  'pr create '*)
    if [ -e "$GH_STATE/slow-pr" ]; then
      trap '' TERM
      sleep 30 & child=$!
      printf '%s %s\n' "$$" "$child" > "$GH_STATE/pr-pids"
      wait "$child"
    fi
    touch "$GH_STATE/pr"
    sha="$(git --git-dir="$GH_REMOTE" rev-parse refs/heads/fleet/12-add-subtract)"
    git --git-dir="$GH_REMOTE" update-ref refs/pull/34/head "$sha"
    echo 'https://github.com/acme/toy/pull/34' ;;
  'pr view 34 --repo acme/toy --json isDraft,state,mergedAt,statusCheckRollup,headRefOid')
    sha="$(git --git-dir="$GH_REMOTE" rev-parse refs/heads/fleet/12-add-subtract)"
    draft=true; [ ! -e "$GH_STATE/ready" ] || draft=false
    state=OPEN; merged=null; if [ -e "$GH_STATE/merged" ]; then state=MERGED; merged='"2026-01-01T00:00:00Z"'; fi
    jq -n --arg sha "$sha" --arg state "$state" --argjson draft "$draft" --argjson merged "$merged" '{isDraft:$draft,state:$state,mergedAt:$merged,statusCheckRollup:[{__typename:"CheckRun",conclusion:"SUCCESS"}],headRefOid:$sha}' ;;
  'pr view 34 --repo acme/toy --json files,changedFiles') echo '{"files":[{"path":"source.txt"}],"changedFiles":1}' ;;
  'pr view 34 --repo acme/toy --json mergeable') echo '{"mergeable":"MERGEABLE"}' ;;
  'pr ready 34 --repo acme/toy') touch "$GH_STATE/ready" ;;
  'pr merge 34 --repo acme/toy --squash --match-head-commit '*)
    sha="$(git --git-dir="$GH_REMOTE" rev-parse refs/heads/fleet/12-add-subtract)"
    if [ -e "$GH_STATE/force-merge" ]; then
      rm "$GH_STATE/force-merge"
      tree="$(git --git-dir="$GH_REMOTE" rev-parse "$sha^{tree}")"
      new="$(printf 'race\n' | GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.com GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.com git --git-dir="$GH_REMOTE" commit-tree "$tree" -p "$sha")"
      git --git-dir="$GH_REMOTE" update-ref refs/heads/fleet/12-add-subtract "$new"
      sha="$new"
    fi
    [ "$8" = "$sha" ] && [ -e "$GH_STATE/ready" ] || exit 1
    git --git-dir="$GH_REMOTE" update-ref refs/heads/main "$sha"
    touch "$GH_STATE/merged" ;;
  'pr view 34 --repo acme/toy --json number,isDraft,state,headRefName,headRefOid,baseRefName,headRepositoryOwner,headRepository,body,statusCheckRollup,mergeable')
    if [ -e "$GH_STATE/merge-qa-race" ]; then rm "$GH_STATE/merge-qa-race"; touch "$GH_STATE/qa-flag"; fi
    if [ -e "$GH_STATE/merge-state-race" ]; then rm "$GH_STATE/merge-state-race"; printf human_qa > "$GH_STATE/column"; fi
    sha="$(git --git-dir="$GH_REMOTE" rev-parse refs/heads/fleet/12-add-subtract)"
    draft=true; [ ! -e "$GH_STATE/ready" ] || draft=false
    state=OPEN; [ ! -e "$GH_STATE/merged" ] || state=MERGED
    jq -n --arg sha "$sha" --arg state "$state" --argjson draft "$draft" '{number:34,isDraft:$draft,state:$state,headRefName:"fleet/12-add-subtract",headRefOid:$sha,baseRefName:"main",headRepositoryOwner:{login:"acme"},headRepository:{name:"toy"},body:"Closes #12\n\n<!-- fleet-board:card:12 -->",statusCheckRollup:[{__typename:"CheckRun",conclusion:"SUCCESS"}],mergeable:"MERGEABLE"}' ;;
  'pr view 34 --repo acme/toy --json isDraft,mergeable,statusCheckRollup') echo '{"isDraft":true,"mergeable":"MERGEABLE","statusCheckRollup":[]}' ;;
  'pr view 34 --repo acme/toy --json number,isDraft,state,headRefName,headRefOid,baseRefName,headRepositoryOwner,headRepository,body')
    if [ -e "$GH_STATE/force-review" ]; then
      count=0; [ ! -e "$GH_STATE/review-views" ] || count="$(cat "$GH_STATE/review-views")"
      count=$((count + 1)); printf '%s' "$count" > "$GH_STATE/review-views"
      if [ "$count" -eq 2 ]; then
        old="$(git --git-dir="$GH_REMOTE" rev-parse refs/heads/fleet/12-add-subtract)"
        tree="$(git --git-dir="$GH_REMOTE" rev-parse "$old^{tree}")"
        new="$(printf 'force push\n' | GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.com GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.com git --git-dir="$GH_REMOTE" commit-tree "$tree" -p "$old")"
        git --git-dir="$GH_REMOTE" update-ref refs/heads/fleet/12-add-subtract "$new"
      fi
    fi
    if [ -e "$GH_STATE/move-to-human" ]; then
      count=0; [ ! -e "$GH_STATE/human-views" ] || count="$(cat "$GH_STATE/human-views")"
      count=$((count + 1)); printf '%s' "$count" > "$GH_STATE/human-views"
      if [ "$count" -eq 2 ]; then printf human_qa > "$GH_STATE/column"; fi
    fi
    sha="$(git --git-dir="$GH_REMOTE" rev-parse refs/heads/fleet/12-add-subtract)" || exit 1
    git --git-dir="$GH_REMOTE" update-ref refs/pull/34/head "$sha"
    draft=true; [ ! -e "$GH_STATE/ready" ] || draft=false
    state=OPEN; [ ! -e "$GH_STATE/merged" ] || state=MERGED
    jq -n --arg sha "$sha" --arg state "$state" --argjson draft "$draft" '{number:34,isDraft:$draft,state:$state,headRefName:"fleet/12-add-subtract",headRefOid:$sha,baseRefName:"main",baseRepositoryOwner:{login:"acme"},baseRepository:{name:"toy"},headRepositoryOwner:{login:"acme"},headRepository:{name:"toy"},body:"Closes #12\n\n<!-- fleet-board:card:12 -->"}' ;;
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
if [ "${1:-start}" = continue-implementor ] || [ "${1:-start}" = continue-resume ] || [ "${1:-start}" = continue-blocked ] || [ "${1:-start}" = continue-blocked-resume ] || [ "${1:-start}" = blocked-changed-blocker ]; then
  printf in_progress > "$TMP/state/column"
  cat > "$TMP/existing-note" <<'NOTE'
<!-- fleet-board:manager-note -->
### fleet-board manager note

```json
{"state":"in_progress","branch":"fleet/12-add-subtract","round":0,"implementor_attempts":2}
```
NOTE
  jq -n --rawfile body "$TMP/existing-note" '[{id:555,user:{login:"fleet-bot"},body:$body}]' > "$TMP/state/comments"
fi
if [ "${1:-start}" = resume-ref ]; then
  REAL_GIT="$(command -v git)"
  touch "$TMP/state/fail-ref"
  cat > "$TMP/bin/git" <<WRAPPER
#!/bin/bash
for arg in "\$@"; do
  if [ "\$arg" = update-ref ] && [ -e "$TMP/state/fail-ref" ]; then rm "$TMP/state/fail-ref"; exit 1; fi
done
exec "$REAL_GIT" "\$@"
WRAPPER
  chmod +x "$TMP/bin/git"
  if bash "$ROOT/bin/fleet-board" tick > "$TMP/ref-out" 2>&1; then echo 'FAIL: simulated ref failure succeeded' >&2; exit 1; fi
  [ -s "$TMP/repo/.git/fleet-board-standalone/start-12.json" ] || { echo 'FAIL: worker evidence missing after ref failure' >&2; exit 1; }
  if [ -e "$TMP/state/pr" ] || git --git-dir="$TMP/remote.git" show-ref --verify --quiet refs/heads/fleet/12-add-subtract; then echo 'FAIL: ref failure published work' >&2; exit 1; fi
fi
if [ "${1:-start}" = implementor-blocked ] || [ "${1:-start}" = continue-blocked ] || [ "${1:-start}" = continue-blocked-resume ] || [ "${1:-start}" = blocked-changed-blocker ]; then
  cat > "$TMP/worker.sh" <<'BLOCKED'
#!/bin/sh
set -eu
printf '%s\n' '{"version":1,"outcome":"blocked","report":"## Status\nblocked\n## Findings\n- none\n## For the card\nCannot proceed.\nBlocked by: #44\n## PR\nNone\nVERIFIED: `true` -> 0 failures"}' > /scratch/result.json
BLOCKED
  if [ "$1" = continue-blocked-resume ]; then
    REAL_JQ="$(command -v jq)"
    touch "$GH_STATE/fail-continue-complete"
    cat > "$TMP/bin/jq" <<WRAPPER
#!/bin/bash
for arg in "\$@"; do
  case "\$arg" in */continue-12-3.json) if [ -e "$GH_STATE/fail-continue-complete" ] && [ "\$1" = '.completed = true' ]; then rm "$GH_STATE/fail-continue-complete"; exit 1; fi ;; esac
done
exec "$REAL_JQ" "\$@"
WRAPPER
    chmod +x "$TMP/bin/jq"
    if bash "$ROOT/bin/fleet-board" tick > "$TMP/blocked-first" 2>&1; then echo 'FAIL: simulated continuation completion failure succeeded' >&2; exit 1; fi
    [ "$(cat "$GH_STATE/column")" = blocked ] || { echo 'FAIL: interruption preceded blocked outcome' >&2; exit 1; }
    if ! bash "$ROOT/bin/fleet-board" tick > "$TMP/blocked-resumed"; then echo 'FAIL: blocked continuation recovery failed' >&2; exit 1; fi
    jq -e '.completed == true' "$TMP/repo/.git/fleet-board-standalone/continue-12-3.json" >/dev/null || { echo 'FAIL: continuation journal remained pending' >&2; exit 1; }
    jq -e '[.[] | select(.body | contains("fleet-board:implementor-blocked:"))] | length == 1' "$GH_STATE/comments" >/dev/null || { echo 'FAIL: blocked report duplicated' >&2; exit 1; }
    echo 'PASS: continue-blocked-resume'
    exit 0
  fi
  if [ "$1" = blocked-changed-blocker ]; then
    touch "$GH_STATE/fail-blocked-report"
    if bash "$ROOT/bin/fleet-board" tick > "$TMP/blocked-first" 2>&1; then echo 'FAIL: simulated report interruption succeeded' >&2; exit 1; fi
    [ "$(cat "$GH_STATE/column")" = blocked ] || { echo 'FAIL: interruption preceded blocked move' >&2; exit 1; }
    printf '%s\n' '{"blocking_pr":55}' > "$TMP/human-blocker"
    bash "$ROOT/plugins/fleet-board/scripts/note.sh" merge 12 "$TMP/human-blocker" || exit 1
    if bash "$ROOT/bin/fleet-board" tick > "$TMP/blocked-resumed" 2>&1; then echo 'FAIL: changed blocker was overwritten' >&2; exit 1; fi
    note="$(bash "$ROOT/plugins/fleet-board/scripts/note.sh" get 12)" || exit 1
    jq -e '.blocking_pr == 55' <<<"$note" >/dev/null || { echo 'FAIL: human blocker changed' >&2; exit 1; }
    echo 'PASS: blocked-changed-blocker'
    exit 0
  fi
  if ! bash "$ROOT/bin/fleet-board" tick > "$TMP/blocked-out"; then echo 'FAIL: blocked implementor was not reconciled' >&2; exit 1; fi
  if [ "$1" = continue-blocked ]; then ACTION=continue_implementor; ATTEMPTS=3; else ACTION=start; ATTEMPTS=1; fi
  jq -e --arg action "$ACTION" '.outcome == "progress" and .cards[0].action == $action' "$TMP/blocked-out" >/dev/null || { echo 'FAIL: blocked outcome malformed' >&2; exit 1; }
  [ "$(cat "$GH_STATE/column")" = blocked ] || { echo 'FAIL: blocked card did not move' >&2; exit 1; }
  [ ! -e "$GH_STATE/pr" ] && ! git --git-dir="$TMP/remote.git" show-ref --verify --quiet refs/heads/fleet/12-add-subtract || { echo 'FAIL: blocked worker published a branch or PR' >&2; exit 1; }
  note="$(bash "$ROOT/plugins/fleet-board/scripts/note.sh" get 12)" || exit 1
  jq -e --argjson attempts "$ATTEMPTS" '.state == "blocked" and .blocked_from == "in_progress" and .blocking_pr == 44 and .implementor_attempts == $attempts and (.last_verified | contains("VERIFIED:"))' <<<"$note" >/dev/null || { echo 'FAIL: blocked evidence not recorded' >&2; exit 1; }
  jq -e '[.[] | select(.body | contains("fleet-board:implementor-blocked:"))] | length == 1' "$GH_STATE/comments" >/dev/null || { echo 'FAIL: blocked report missing or duplicated' >&2; exit 1; }
  echo "PASS: $1"
  exit 0
fi
if [ "${1:-start}" = continue-resume ]; then
  printf 2 > "$GH_STATE/fail-patch-at"
  if bash "$ROOT/bin/fleet-board" tick > "$TMP/continue-first" 2>&1; then echo 'FAIL: simulated continuation note interruption succeeded' >&2; exit 1; fi
  [ -e "$GH_STATE/pr" ] || { echo 'FAIL: interruption preceded PR creation' >&2; exit 1; }
  FIRST_SHA="$(git --git-dir="$TMP/remote.git" rev-parse refs/heads/fleet/12-add-subtract)"
  bash "$ROOT/bin/fleet-board" tick > "$TMP/continue-second" || { echo 'FAIL: start evidence recovery failed' >&2; exit 1; }
  bash "$ROOT/bin/fleet-board" tick > "$TMP/continue-third" || { echo 'FAIL: continuation journal recovery failed' >&2; exit 1; }
  [ "$(git --git-dir="$TMP/remote.git" rev-parse refs/heads/fleet/12-add-subtract)" = "$FIRST_SHA" ] || { echo 'FAIL: continuation re-dispatched worker' >&2; exit 1; }
  [ "$(grep -c '^pr create ' "$GH_STATE/calls")" = 1 ] || { echo 'FAIL: continuation duplicated PR' >&2; exit 1; }
  jq -e '[.[] | select(.body | contains("fleet-board:standalone-start:"))] | length == 1' "$GH_STATE/comments" >/dev/null || { echo 'FAIL: continuation duplicated report' >&2; exit 1; }
  jq -e 'any(.[]; .id == 555 and (.body | contains("\"implementor_attempts\": 3")))' "$GH_STATE/comments" >/dev/null || { echo 'FAIL: attempt changed during recovery' >&2; exit 1; }
  echo 'PASS: continue-resume'
  exit 0
fi
if [ "${1:-start}" = real-run ]; then
  cat >> "$TMP/repo/.fleet-board.yml" <<'YML'
limits:
  tick_interval: 0
  min_tick_gap: 0
  max_consecutive_failures: 2
YML
  cat > "$TMP/worker.sh" <<'WORKER'
#!/bin/sh
set -eu
if grep -q '"role": "implementor"' /scratch/request.json; then
  printf 'after\n' > source.txt
  git add source.txt
  git -c user.name=Fixture -c user.email=fixture@example.com commit -qm implement
  printf '%s\n' '{"version":1,"outcome":"done","report":"## Status\ndone\n## Findings\n- none\n## For the card\nImplemented\n## PR\n#34\nVERIFIED: `cat source.txt` -> 1 file"}' > /scratch/result.json
else
  grep -q '"role": "reviewer"' /scratch/request.json
  printf '%s\n' '{"version":1,"outcome":"clean","report":"## Status\nclean\n## Findings\n- none\n## For the card\nReviewed.\n## Acceptance map\n- subtract -> CHECKED: `cat source.txt`\n## Mutation\nskipped: review.mutation is off\n## Claim check\nskipped: review.verify_claim is off\nVERIFIED: `cat source.txt` -> 1 file"}' > /scratch/result.json
fi
WORKER
  cat > "$TMP/verify-main" <<'VERIFY'
#!/bin/bash
sha="$(git --git-dir="$GH_REMOTE" rev-parse refs/heads/main)"
jq -n --arg sha "$sha" '{commit:$sha,ok:true,results:[]}'
VERIFY
  export FLEET_BOARD_VERIFY_MAIN="$TMP/verify-main" FLEET_BOARD_LOG_DIR="$TMP/logs"
  if ! bash "$ROOT/bin/fleet-board" run --repo "$TMP/repo" > "$TMP/run-out" 2> "$TMP/run-err"; then cat "$TMP/run-out" "$TMP/run-err" >&2; echo 'FAIL: real fixture run failed' >&2; exit 1; fi
  grep -q 'stopped: nothing-dispatchable' "$TMP/run-out" || { cat "$TMP/run-out" >&2; echo 'FAIL: run did not settle idle' >&2; exit 1; }
  [ "$(cat "$TMP/state/column")" = done ] || { echo 'FAIL: run did not finish card' >&2; exit 1; }
  [ "$(grep -c '^pr merge ' "$TMP/state/calls")" = 1 ] || { echo 'FAIL: run did not merge exactly once' >&2; exit 1; }
  jq -e 'any(.[]; .id == 555 and (.body | contains("\"ok\": true")))' "$TMP/state/comments" >/dev/null || { echo 'FAIL: run did not record verified main' >&2; exit 1; }
  echo 'PASS: real-run'
  exit 0
fi
if [ "${1:-start}" = symlink-checkout ]; then
  cat > "$TMP/worker.sh" <<'MALICIOUS'
#!/bin/sh
set -eu
printf 'after\n' > source.txt
git add source.txt
git -c user.name=Fixture -c user.email=fixture@example.com commit -qm implement
mv /scratch/checkout /scratch/evil
ln -s evil /scratch/checkout
printf '%s\n' '{"version":1,"outcome":"done","report":"## Status\ndone\n## Findings\n- none\n## For the card\nImplemented\n## PR\n#34\nVERIFIED: `true` -> 0 failures"}' > /scratch/result.json
MALICIOUS
  if bash "$ROOT/bin/fleet-board" tick > "$TMP/symlink-out" 2>&1; then echo 'FAIL: symlink checkout accepted' >&2; exit 1; fi
  if ! grep -q 'unsafe worker checkout root' "$TMP/symlink-out"; then cat "$TMP/symlink-out" >&2; echo 'FAIL: checkout root rejection not observed' >&2; exit 1; fi
  if git --git-dir="$TMP/remote.git" show-ref --verify --quiet refs/heads/fleet/12-add-subtract || [ -e "$TMP/state/pr" ]; then echo 'FAIL: symlink checkout published' >&2; exit 1; fi
  [ "$(cat "$TMP/state/column")" = ready ] || { echo 'FAIL: symlink checkout moved card' >&2; exit 1; }
  echo 'PASS: symlink-checkout'
  exit 0
fi
if [ "${1:-start}" = tick-interrupt ]; then
  cat > "$TMP/worker.sh" <<'STUBBORN'
#!/bin/sh
hostname > /scratch/@MARKER@
trap '' TERM
while :; do sleep 1; done
STUBBORN
  MARKER="running-$(basename "$TMP")"
  sed "s/@MARKER@/$MARKER/" "$TMP/worker.sh" > "$TMP/worker.tmp"
  mv "$TMP/worker.tmp" "$TMP/worker.sh"
  TMPDIR="$TMP" bash "$ROOT/bin/fleet-board" tick > "$TMP/interrupted-out" 2>&1 & TICK_PID=$!
  RUNNING=""
  for unused in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    RUNNING="$(find "${TMPDIR:-/tmp}" -name "$MARKER" -type f -print -quit 2>/dev/null)"
    [ -n "$RUNNING" ] && break
    if ! kill -0 "$TICK_PID" 2>/dev/null; then cat "$TMP/interrupted-out" >&2; cat "$TMP/state/calls" >&2; echo 'FAIL: tick exited before worker started' >&2; exit 1; fi
    sleep 1
  done
  [ -n "$RUNNING" ] || { kill "$TICK_PID" 2>/dev/null || true; cat "$TMP/interrupted-out" >&2; echo 'FAIL: tick worker did not start' >&2; exit 1; }
  CONTAINER="$(cat "$RUNNING")"
  kill -TERM "$TICK_PID"
  for unused in 1 2 3 4 5; do kill -0 "$TICK_PID" 2>/dev/null || break; sleep 1; done
  if kill -0 "$TICK_PID" 2>/dev/null; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    kill -KILL "$TICK_PID" 2>/dev/null || true
    wait "$TICK_PID" 2>/dev/null || true
    echo 'FAIL: interrupted top-level tick did not stop' >&2; exit 1
  fi
  wait "$TICK_PID" 2>/dev/null || true
  if docker inspect "$CONTAINER" >/dev/null 2>&1; then docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; echo 'FAIL: interrupted tick left a container' >&2; exit 1; fi
  if git --git-dir="$TMP/remote.git" show-ref --verify --quiet refs/heads/fleet/12-add-subtract || [ -e "$TMP/state/pr" ]; then echo 'FAIL: interrupted tick published work' >&2; exit 1; fi
  [ "$(cat "$TMP/state/column")" = ready ] || { echo 'FAIL: interrupted tick moved card' >&2; exit 1; }
  echo 'PASS: tick-interrupt'
  exit 0
fi
if [ "${1:-start}" = interrupt-pr ]; then
  touch "$TMP/state/slow-pr"
  bash "$ROOT/bin/fleet-board" tick > "$TMP/pr-interrupted" 2>&1 & TICK_PID=$!
  for unused in 1 2 3 4 5 6 7 8 9 10 11 12; do [ -s "$TMP/state/pr-pids" ] && break; sleep 1; done
  [ -s "$TMP/state/pr-pids" ] || { kill -KILL "$TICK_PID" 2>/dev/null || true; cat "$TMP/pr-interrupted" >&2; echo 'FAIL: PR call not reached' >&2; exit 1; }
  read -r PR_PID PR_CHILD < "$TMP/state/pr-pids"
  kill -TERM "$TICK_PID"
  for unused in 1 2 3 4 5 6 7 8; do kill -0 "$TICK_PID" 2>/dev/null || break; sleep 1; done
  if kill -0 "$TICK_PID" 2>/dev/null; then
    kill -KILL "$PR_CHILD" "$PR_PID" "$TICK_PID" 2>/dev/null || true
    wait "$TICK_PID" 2>/dev/null || true
    echo 'FAIL: interrupted publication did not stop' >&2; exit 1
  fi
  wait "$TICK_PID" 2>/dev/null || true
  [ ! -e "$TMP/state/pr" ] && [ "$(cat "$TMP/state/column")" = ready ] || { echo 'FAIL: interrupted publication mutated PR or board' >&2; exit 1; }
  rm "$TMP/state/slow-pr"
fi
if [ "${1:-start}" = push-destination ]; then
  git init -q --bare "$TMP/unexpected.git"
  git config remote.origin.pushurl "file://$TMP/unexpected.git"
  if bash "$ROOT/bin/fleet-board" tick > "$TMP/bad-out" 2>/dev/null; then echo 'FAIL: mismatched push destination accepted' >&2; exit 1; fi
  if git --git-dir="$TMP/unexpected.git" show-ref --verify --quiet refs/heads/fleet/12-add-subtract; then
    echo 'FAIL: pushed to mismatched remote' >&2; exit 1
  fi
  if git --git-dir="$TMP/remote.git" show-ref --verify --quiet refs/heads/fleet/12-add-subtract; then
    echo 'FAIL: published despite mismatched push destination' >&2; exit 1
  fi
  [ "$(cat "$TMP/state/column")" = ready ] || { echo 'FAIL: board changed' >&2; exit 1; }
  echo 'PASS: push-destination'
  exit 0
fi
if [ "${1:-start}" = resume ] || [ "${1:-start}" = resume-note ]; then
  if [ "$1" = resume ]; then touch "$TMP/state/fail-move"; else touch "$TMP/state/fail-note"; fi
  if bash "$ROOT/bin/fleet-board" tick > "$TMP/first-out" 2>"$TMP/first-err"; then echo 'FAIL: simulated interruption succeeded' >&2; exit 1; fi
  [ -e "$TMP/state/pr" ] || { echo 'FAIL: interruption preceded PR creation' >&2; exit 1; }
  jq -e '[.[] | select(.body | contains("fleet-board:standalone-start:"))] | length == 1' "$TMP/state/comments" >/dev/null || { cat "$TMP/first-err" >&2; cat "$TMP/state/comments" >&2; echo 'FAIL: official report missing before interruption' >&2; exit 1; }
fi
if ! bash "$ROOT/bin/fleet-board" tick > "$TMP/out"; then echo 'FAIL: start tick failed' >&2; exit 1; fi
[ ! -e "$TMP/hook-ran" ] || { echo 'FAIL: worker Git config executed on controller' >&2; exit 1; }
if [ "${1:-start}" = continue-implementor ]; then EXPECTED_ACTION=continue_implementor; else EXPECTED_ACTION=start; fi
if ! jq -e --arg action "$EXPECTED_ACTION" '.outcome == "progress" and .cards[0].action == $action' "$TMP/out" >/dev/null; then echo 'FAIL: start outcome' >&2; exit 1; fi
if [ "${1:-start}" = continue-implementor ]; then
  jq -e 'any(.[]; .id == 555 and (.body | contains("\"implementor_attempts\": 3")))' "$TMP/state/comments" >/dev/null || { echo 'FAIL: continuation attempt not recorded' >&2; exit 1; }
fi
if [ "${1:-start}" = resume-ref ] && ! jq -e '.cost_usd == 0' "$TMP/out" >/dev/null; then echo 'FAIL: recovered fixture tick cost missing' >&2; exit 1; fi
[ "$(cat "$TMP/state/column")" = in_progress ] || { echo 'FAIL: card did not move' >&2; exit 1; }
[ -e "$TMP/state/pr" ] || { echo 'FAIL: draft PR missing' >&2; exit 1; }
[ "$(git --git-dir="$TMP/remote.git" show fleet/12-add-subtract:source.txt)" = after ] || { echo 'FAIL: worker commit not published' >&2; exit 1; }
jq -e 'any(.[]; .body | contains("\"pr\": 34"))' "$TMP/state/comments" >/dev/null || { echo 'FAIL: verified PR not recorded' >&2; exit 1; }
if [ "${1:-start}" = clean-review ] || [ "${1:-start}" = review-stale ] || [ "${1:-start}" = review-human-race ] || [ "${1:-start}" = review-followups ] || [ "${1:-start}" = findings-review ] || [ "${1:-start}" = review-move-race ] || [ "${1:-start}" = fix-re-review ] || [ "${1:-start}" = fix-resume-note ] || [ "${1:-start}" = fix-two-rounds ] || [ "${1:-start}" = review-resume-verdict ] || [ "${1:-start}" = human-qa ] || [ "${1:-start}" = review-resume-label ] || [ "${1:-start}" = human-qa-resume-label ] || [ "${1:-start}" = merge-verification ] || [ "${1:-start}" = stale-head ] || [ "${1:-start}" = merge-qa-race ] || [ "${1:-start}" = merge-state-race ] || [ "${1:-start}" = merge-done-resume ] || [ "${1:-start}" = advisory-stage ] || [ "${1:-start}" = stage-fix ] || [ "${1:-start}" = stage-standard ] || [ "${1:-start}" = projects-review ] || [ "${1:-start}" = projects-qa-race ]; then
  SHA="$(git --git-dir="$TMP/remote.git" rev-parse refs/heads/fleet/12-add-subtract)"
  cat > "$TMP/worker.sh" <<'REVIEWER'
#!/bin/sh
set -eu
printf '%s\n' '{"version":1,"outcome":"clean","report":"## Status\nclean\n## Findings\n- none\n## For the card\nReviewed the implementation.\n## Acceptance map\n- subtract -> CHECKED: `cat source.txt`\n## Mutation\nskipped: review.mutation is off\n## Claim check\nskipped: review.verify_claim is off\nVERIFIED: `cat source.txt` -> 1 file"}' > /scratch/result.json
REVIEWER
  if [ "${1:-start}" = review-move-race ]; then
    touch "$TMP/state/move-at-adapter"
    if bash "$ROOT/bin/fleet-board" tick > "$TMP/review-out" 2> "$TMP/review-err"; then echo 'FAIL: adapter Human QA race accepted' >&2; exit 1; fi
    grep -q 'refusing to move.*Human QA' "$TMP/review-err" || { cat "$TMP/review-err" >&2; echo 'FAIL: Human QA adapter gate not reached' >&2; exit 1; }
    [ "$(cat "$TMP/state/column")" = human_qa ] || { echo 'FAIL: card moved out of Human QA' >&2; exit 1; }
    jq -e --arg sha "$SHA" 'all(.[]; .id != 555 or ((.body | contains("\"sha\": \"" + $sha + "\"")) | not))' "$TMP/state/comments" >/dev/null || { echo 'FAIL: review note updated after Human QA move' >&2; exit 1; }
    echo 'PASS: review-move-race'
    exit 0
  fi
  if [ "${1:-start}" = findings-review ] || [ "${1:-start}" = fix-re-review ] || [ "${1:-start}" = fix-resume-note ] || [ "${1:-start}" = fix-two-rounds ]; then
    python3 - "$TMP/worker.sh" <<'PY_WORKER'
import sys
p = sys.argv[1]
s = open(p).read().replace('"outcome":"clean"', '"outcome":"findings"').replace(r'## Status\nclean\n## Findings\n- none', r'## Status\nfindings\n## Findings\n- [Important] Incorrect result')
open(p, 'w').write(s)
PY_WORKER
    if ! bash "$ROOT/bin/fleet-board" tick > "$TMP/review-out"; then echo 'FAIL: findings review tick failed' >&2; exit 1; fi
    jq -e '.outcome == "progress" and .cards[0].action == "start_review" and (.cards | length == 1)' "$TMP/review-out" >/dev/null || { echo 'FAIL: review was not a single planned card action' >&2; exit 1; }
    [ "$(cat "$TMP/state/column")" = in_review ] || { echo 'FAIL: findings review did not move card' >&2; exit 1; }
    jq -e --arg sha "$SHA" 'any(.[]; .id == 555 and (.body | contains("\"sha\": \"" + $sha + "\"")) and (.body | contains("\"important\": 1")))' "$TMP/state/comments" >/dev/null || { echo 'FAIL: findings not recorded against reviewed head' >&2; exit 1; }
    if [ "$1" = findings-review ]; then echo 'PASS: findings-review'; exit 0; fi
    cat > "$TMP/worker.sh" <<'FIXER'
#!/bin/sh
set -eu
if grep -q '"role": "fixer"' /scratch/request.json; then
  grep -q 'Incorrect result' /scratch/request.json
  printf 'fixed\n' > source.txt
  git add source.txt
  git -c user.name=Fixture -c user.email=fixture@example.com commit -qm fix
  printf '%s\n' '{"version":1,"outcome":"done","report":"## Status\ndone\n## Findings\n- none\n## For the card\nFixed.\n## PR\n#34\n## Resolutions\n- Incorrect result :: fixed\nVERIFIED: `cat source.txt` -> 1 file"}' > /scratch/result.json
else
  grep -q '"role": "reviewer"' /scratch/request.json
  printf '%s\n' '{"version":1,"outcome":"clean","report":"## Status\nclean\n## Findings\n- none\n## For the card\nRe-reviewed.\n## Acceptance map\n- subtract -> CHECKED: `cat source.txt`\n## Mutation\nskipped: review.mutation is off\n## Claim check\nskipped: review.verify_claim is off\nVERIFIED: `cat source.txt` -> 1 file"}' > /scratch/result.json
fi
FIXER
    if [ "$1" = fix-two-rounds ]; then
      cat > "$TMP/worker.sh" <<'FIXER_TWO'
#!/bin/sh
set -eu
if grep -q '"role": "fixer"' /scratch/request.json; then
  if grep -q fixed-1 source.txt; then printf 'fixed-2\n' > source.txt; else printf 'fixed-1\n' > source.txt; fi
  git add source.txt
  git -c user.name=Fixture -c user.email=fixture@example.com commit -qm fix
  printf '%s\n' '{"version":1,"outcome":"done","report":"## Status\ndone\n## Findings\n- none\n## For the card\nFixed.\n## PR\n#34\n## Resolutions\n- Incorrect result :: fixed\nVERIFIED: `cat source.txt` -> 1 file"}' > /scratch/result.json
elif grep -q fixed-1 source.txt; then
  printf '%s\n' '{"version":1,"outcome":"findings","report":"## Status\nfindings\n## Findings\n- [Important] Incorrect result\n## For the card\nStill wrong.\n## Acceptance map\n- subtract -> CHECKED: `cat source.txt`\n## Mutation\nskipped: review.mutation is off\n## Claim check\nskipped: review.verify_claim is off\nVERIFIED: `cat source.txt` -> 1 file"}' > /scratch/result.json
else
  printf '%s\n' '{"version":1,"outcome":"clean","report":"## Status\nclean\n## Findings\n- none\n## For the card\nRe-reviewed.\n## Acceptance map\n- subtract -> CHECKED: `cat source.txt`\n## Mutation\nskipped: review.mutation is off\n## Claim check\nskipped: review.verify_claim is off\nVERIFIED: `cat source.txt` -> 1 file"}' > /scratch/result.json
fi
FIXER_TWO
    fi
    if [ "$1" = fix-resume-note ]; then
      REAL_JQ="$(command -v jq)"
      touch "$TMP/state/fail-fix-complete"
      cat > "$TMP/bin/jq" <<WRAPPER
#!/bin/bash
for arg in "\$@"; do
  case "\$arg" in */fix-12*.json) if [ -e "$TMP/state/fail-fix-complete" ] && [ "\$1" = '.completed = true' ]; then rm "$TMP/state/fail-fix-complete"; exit 1; fi ;; esac
done
exec "$REAL_JQ" "\$@"
WRAPPER
      chmod +x "$TMP/bin/jq"
      if bash "$ROOT/bin/fleet-board" tick > "$TMP/first-fix-out" 2>&1; then echo 'FAIL: simulated fix completion failure succeeded' >&2; exit 1; fi
      FIRST_SHA="$(git --git-dir="$TMP/remote.git" rev-parse refs/heads/fleet/12-add-subtract)"
      jq -e --arg sha "$FIRST_SHA" 'any(.[]; .id == 555 and (.body | contains("\"sha\": \"" + $sha + "\"")))' "$TMP/state/comments" >/dev/null || { echo 'FAIL: interruption preceded re-review note' >&2; exit 1; }
    fi
    if ! bash "$ROOT/bin/fleet-board" tick > "$TMP/fix-out"; then echo 'FAIL: fix and re-review tick failed' >&2; exit 1; fi
    jq -e '.outcome == "progress" and .cards[0].action == "fix" and (.cards | length == 1)' "$TMP/fix-out" >/dev/null || { echo 'FAIL: fix was not a single planned card action' >&2; exit 1; }
    if [ "$1" = fix-resume-note ]; then
      [ "$(git --git-dir="$TMP/remote.git" rev-parse refs/heads/fleet/12-add-subtract)" = "$FIRST_SHA" ] || { echo 'FAIL: fix repeated on resume' >&2; exit 1; }
      jq -e '[.[] | select(.body | contains("fleet-board:standalone-fix:"))] | length == 1' "$TMP/state/comments" >/dev/null || { echo 'FAIL: fix report duplicated' >&2; exit 1; }
    fi
    if [ "$1" = fix-two-rounds ]; then
      jq -e 'any(.[]; .id == 555 and (.body | contains("\"round\": 2")) and (.body | contains("\"important\": 1")))' "$TMP/state/comments" >/dev/null || { echo 'FAIL: second-round findings missing' >&2; exit 1; }
      if ! bash "$ROOT/bin/fleet-board" tick > "$TMP/second-fix-out"; then echo 'FAIL: second fix tick failed' >&2; exit 1; fi
      jq -e 'any(.[]; .id == 555 and (.body | contains("\"round\": 3")) and (.body | contains("\"important\": 0")))' "$TMP/state/comments" >/dev/null || { echo 'FAIL: third-round clean verdict missing' >&2; exit 1; }
      echo 'PASS: fix-two-rounds'
      exit 0
    fi
    NEW_SHA="$(git --git-dir="$TMP/remote.git" rev-parse refs/heads/fleet/12-add-subtract)"
    [ "$NEW_SHA" != "$SHA" ] || { echo 'FAIL: fix did not advance branch' >&2; exit 1; }
    jq -e --arg sha "$NEW_SHA" 'any(.[]; .id == 555 and (.body | contains("\"sha\": \"" + $sha + "\"")) and (.body | contains("\"round\": 2")) and (.body | contains("\"important\": 0")))' "$TMP/state/comments" >/dev/null || { echo 'FAIL: clean re-review not recorded on new head' >&2; exit 1; }
    echo 'PASS: fix-re-review'
    exit 0
  fi
  if [ "${1:-start}" = review-resume-verdict ] || [ "${1:-start}" = review-resume-label ]; then
    cp "$TMP/worker.sh" "$TMP/clean-reviewer"
    python3 - "$TMP/worker.sh" <<'PY_WORKER'
import sys
p = sys.argv[1]
s = open(p).read().replace('"outcome":"clean"', '"outcome":"findings"').replace(r'## Status\nclean\n## Findings\n- none', r'## Status\nfindings\n## Findings\n- [Important] Original finding')
open(p, 'w').write(s)
PY_WORKER
    if [ "$1" = review-resume-label ]; then touch "$TMP/state/fail-review-move"; else touch "$TMP/state/fail-patch"; fi
    if bash "$ROOT/bin/fleet-board" tick > "$TMP/review-first" 2>&1; then echo 'FAIL: simulated review-note failure succeeded' >&2; exit 1; fi
    jq -e 'any(.[]; (.body | contains("fleet-board:standalone-review:")) and (.body | contains("Original finding")))' "$TMP/state/comments" >/dev/null || { echo 'FAIL: original review report missing' >&2; exit 1; }
    if [ "$1" = review-resume-label ] && [ "$(cat "$TMP/state/column")" != none ]; then echo 'FAIL: interruption did not remove the state label' >&2; exit 1; fi
    cp "$TMP/clean-reviewer" "$TMP/worker.sh"
    if ! bash "$ROOT/bin/fleet-board" tick > "$TMP/review-resumed"; then echo 'FAIL: review recovery failed' >&2; exit 1; fi
    jq -e 'any(.[]; .id == 555 and (.body | contains("\"important\": 1")) and (.body | contains("Original finding")))' "$TMP/state/comments" >/dev/null || { echo 'FAIL: review verdict changed on retry' >&2; exit 1; }
    jq -e '[.[] | select(.body | contains("fleet-board:standalone-review:"))] | length == 1' "$TMP/state/comments" >/dev/null || { echo 'FAIL: review report duplicated' >&2; exit 1; }
    echo "PASS: $1"
    exit 0
  fi
  if [ "${1:-start}" = projects-qa-race ]; then
    touch "$TMP/state/project-move-race"
    if bash "$ROOT/bin/fleet-board" tick > "$TMP/review-out" 2> "$TMP/review-err"; then echo 'FAIL: Projects Human QA race accepted' >&2; exit 1; fi
    grep -q 'refusing to move.*Human QA' "$TMP/review-err" || { cat "$TMP/review-err" >&2; echo 'FAIL: Projects adapter gate not reached' >&2; exit 1; }
    [ "$(cat "$TMP/state/column")" = human_qa ] || { echo 'FAIL: Projects Human QA state lost' >&2; exit 1; }
    echo 'PASS: projects-qa-race'
    exit 0
  fi
  if [ "${1:-start}" = review-human-race ]; then
    touch "$TMP/state/move-to-human"
    if bash "$ROOT/bin/fleet-board" tick > "$TMP/review-out" 2> "$TMP/review-err"; then echo 'FAIL: Human QA race accepted' >&2; exit 1; fi
    [ "$(cat "$TMP/state/column")" = human_qa ] || { cat "$TMP/review-err" >&2; cat "$TMP/state/column" >&2; echo 'FAIL: review moved card out of Human QA' >&2; exit 1; }
    jq -e 'all(.[]; (.body | contains("fleet-board:standalone-review:")) | not)' "$TMP/state/comments" >/dev/null || { echo 'FAIL: review recorded after Human QA move' >&2; exit 1; }
    echo 'PASS: review-human-race'
    exit 0
  fi
  if [ "${1:-start}" = review-followups ]; then
    python3 - "$TMP/worker.sh" <<'PY_WORKER'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(r'Reviewed the implementation.\n## Acceptance map', r'Reviewed.\nOut of scope:\n- Extra :: no testable check\n## Acceptance map')
open(p, 'w').write(s)
PY_WORKER
    if bash "$ROOT/bin/fleet-board" tick > "$TMP/review-out" 2> "$TMP/review-err"; then echo 'FAIL: unhandled review follow-up accepted' >&2; exit 1; fi
    [ "$(cat "$TMP/state/column")" = in_progress ] || { echo 'FAIL: unfiled follow-up moved card' >&2; exit 1; }
    jq -e 'all(.[]; (.body | contains("fleet-board:standalone-review:")) | not)' "$TMP/state/comments" >/dev/null || { echo 'FAIL: unfiled follow-up report recorded' >&2; exit 1; }
    echo 'PASS: review-followups'
    exit 0
  fi
  if [ "${1:-start}" = review-stale ]; then
    touch "$TMP/state/force-review"
    if bash "$ROOT/bin/fleet-board" tick > "$TMP/review-out" 2> "$TMP/review-err"; then echo 'FAIL: changed review head accepted' >&2; exit 1; fi
    grep -q 'PR head changed during review' "$TMP/review-err" || { cat "$TMP/review-err" >&2; echo 'FAIL: stale head was not detected' >&2; exit 1; }
    [ "$(cat "$TMP/state/column")" = in_progress ] || { echo 'FAIL: stale review moved the card' >&2; exit 1; }
    jq -e 'all(.[]; (.body | contains("fleet-board:standalone-review:")) | not)' "$TMP/state/comments" >/dev/null || { echo 'FAIL: stale review was recorded' >&2; exit 1; }
    echo 'PASS: review-stale'
    exit 0
  fi
  if ! bash "$ROOT/bin/fleet-board" tick > "$TMP/review-out"; then echo 'FAIL: clean review tick failed' >&2; exit 1; fi
  if ! jq -e '.outcome == "progress" and .cards[0].action == "start_review"' "$TMP/review-out" >/dev/null; then echo 'FAIL: review outcome' >&2; exit 1; fi
  [ "$(cat "$TMP/state/column")" = in_review ] || { echo 'FAIL: card did not reach review' >&2; exit 1; }
  jq -e --arg sha "$SHA" 'any(.[]; .id == 555 and (.body | contains("\"sha\": \"" + $sha + "\"")))' "$TMP/state/comments" >/dev/null || { echo 'FAIL: exact reviewed head missing from manager note' >&2; exit 1; }
  if [ "${1:-start}" = merge-qa-race ] || [ "${1:-start}" = merge-state-race ]; then
    bash "$ROOT/bin/fleet-board" tick > "$TMP/ready-out" || { echo 'FAIL: mark-ready tick failed' >&2; exit 1; }
    touch "$TMP/state/$1"
    if bash "$ROOT/bin/fleet-board" tick > "$TMP/race-out" 2>&1; then echo 'FAIL: merge accepted changed QA or card state' >&2; exit 1; fi
    if [ -e "$TMP/state/merged" ] || grep -q '^pr merge ' "$TMP/state/calls"; then echo 'FAIL: merge attempted after QA or state changed' >&2; exit 1; fi
    if [ "$1" = merge-state-race ] && [ "$(cat "$TMP/state/column")" != human_qa ]; then echo 'FAIL: Human QA move lost' >&2; exit 1; fi
    echo "PASS: $1"
    exit 0
  fi
  if [ "${1:-start}" = advisory-stage ] || [ "${1:-start}" = stage-fix ] || [ "${1:-start}" = stage-standard ]; then
    STAGE=security; [ "$1" != stage-standard ] || STAGE=standard
    [ -e "$TMP/state/stage-label" ] || { echo 'FAIL: stage routing label missing before review movement' >&2; exit 1; }
    cat > "$TMP/worker.sh" <<'STAGE'
#!/bin/sh
set -eu
grep -q '"role": "stage-reviewer"' /scratch/request.json
printf '%s\n' '{"version":1,"outcome":"findings","report":"## Status\nfindings\n## Findings\n- [Important] Advisory issue\n## For the card\nAdvisory review.\nVERIFIED: `cat source.txt` -> 1 file"}' > /scratch/result.json
STAGE
    if ! bash "$ROOT/bin/fleet-board" tick > "$TMP/stage-out"; then echo 'FAIL: stage advance and review failed' >&2; exit 1; fi
    jq -e '.outcome == "progress" and .cards[0].action == "advance_stage"' "$TMP/stage-out" >/dev/null || { echo 'FAIL: stage outcome' >&2; exit 1; }
    [ "$(cat "$TMP/state/column")" = "review_$STAGE" ] || { echo 'FAIL: stage move missing' >&2; exit 1; }
    jq -e --arg sha "$SHA" --arg stage "$STAGE" 'any(.[]; .id == 555 and (.body | contains("\"sha\": \"" + $sha + "\"")) and (.body | contains("\"stage\": \"" + $stage + "\"")) and (.body | contains("\"important\": 1")))' "$TMP/state/comments" >/dev/null || { echo 'FAIL: stage finding not recorded' >&2; exit 1; }
    if [ "$1" = stage-fix ]; then
      cat > "$TMP/worker.sh" <<'STAGE_FIX'
#!/bin/sh
set -eu
if grep -q '"role": "fixer"' /scratch/request.json; then
  grep -q 'Advisory issue' /scratch/request.json
  printf 'stage fixed\n' > source.txt
  git add source.txt
  git -c user.name=Fixture -c user.email=fixture@example.com commit -qm fix-stage
  printf '%s\n' '{"version":1,"outcome":"done","report":"## Status\ndone\n## Findings\n- none\n## For the card\nFixed.\n## PR\n#34\n## Resolutions\n- Advisory issue :: fixed\nVERIFIED: `cat source.txt` -> 1 file"}' > /scratch/result.json
else
  grep -q '"role": "stage-reviewer"' /scratch/request.json
  grep -q 'Advisory issue' /scratch/request.json
  grep -q '## Resolutions' /scratch/request.json
  printf '%s\n' '{"version":1,"outcome":"clean","report":"## Status\nclean\n## Findings\n- none\n## For the card\nStage re-reviewed.\nVERIFIED: `cat source.txt` -> 1 file"}' > /scratch/result.json
fi
STAGE_FIX
      if ! bash "$ROOT/bin/fleet-board" tick > "$TMP/stage-fix-out"; then echo 'FAIL: stage fix and re-review failed' >&2; exit 1; fi
      NEW_SHA="$(git --git-dir="$TMP/remote.git" rev-parse refs/heads/fleet/12-add-subtract)"
      [ "$NEW_SHA" != "$SHA" ] || { echo 'FAIL: stage fix did not change head' >&2; exit 1; }
      jq -e --arg sha "$NEW_SHA" 'any(.[]; .id == 555 and (.body | contains("\"sha\": \"" + $sha + "\"")) and (.body | contains("\"round\": 2")) and (.body | contains("\"stage\": \"security\"")) and (.body | contains("\"important\": 0")))' "$TMP/state/comments" >/dev/null || { echo 'FAIL: stage re-review missing' >&2; exit 1; }
      echo 'PASS: stage-fix'
      exit 0
    fi
    bash "$ROOT/bin/fleet-board" tick --plan-only > "$TMP/stage-next" || exit 1
    jq -e '.cards[0].action == "mark_ready"' "$TMP/stage-next" >/dev/null || { echo 'FAIL: advisory finding incorrectly blocked progress' >&2; exit 1; }
    echo "PASS: $1"
    exit 0
  fi
  if [ "${1:-start}" = stale-head ]; then
    bash "$ROOT/bin/fleet-board" tick > "$TMP/ready-out" || { echo 'FAIL: mark-ready tick failed' >&2; exit 1; }
    touch "$TMP/state/force-merge"
    if bash "$ROOT/bin/fleet-board" tick > "$TMP/stale-out" 2>&1; then echo 'FAIL: stale merge was accepted' >&2; exit 1; fi
    [ ! -e "$TMP/state/merged" ] || { echo 'FAIL: changed head was merged' >&2; exit 1; }
    [ "$(cat "$TMP/state/column")" = in_review ] || { echo 'FAIL: stale merge moved card' >&2; exit 1; }
    NEW_SHA="$(git --git-dir="$TMP/remote.git" rev-parse refs/heads/fleet/12-add-subtract)"
    [ "$NEW_SHA" != "$SHA" ] || { echo 'FAIL: race did not change head' >&2; exit 1; }
    jq -e --arg sha "$SHA" 'any(.[]; .id == 555 and (.body | contains("\"sha\": \"" + $sha + "\"")))' "$TMP/state/comments" >/dev/null || { echo 'FAIL: original review evidence changed' >&2; exit 1; }
    bash "$ROOT/bin/fleet-board" tick --plan-only > "$TMP/stale-plan" || exit 1
    jq -e '.cards[0].action == "review"' "$TMP/stale-plan" >/dev/null || { echo 'FAIL: changed head did not require re-review' >&2; exit 1; }
    echo 'PASS: stale-head'
    exit 0
  fi
  if [ "${1:-start}" = merge-verification ] || [ "${1:-start}" = merge-done-resume ]; then
    cat > "$TMP/verify-main" <<'VERIFY'
#!/bin/bash
mode="$(cat "$GH_STATE/verify-mode")"
[ "$mode" != infra ] || exit 1
sha="$(git --git-dir="$GH_REMOTE" rev-parse refs/heads/main)"
if [ "$mode" = false ]; then ok=false; else ok=true; fi
jq -n --arg sha "$sha" --argjson ok "$ok" '{commit:$sha,ok:$ok,results:[]}'
VERIFY
    export FLEET_BOARD_VERIFY_MAIN="$TMP/verify-main"
    printf infra > "$TMP/state/verify-mode"
    bash "$ROOT/bin/fleet-board" tick > "$TMP/ready-out" || { echo 'FAIL: mark-ready tick failed' >&2; exit 1; }
    [ -e "$TMP/state/ready" ] || { echo 'FAIL: draft was not marked ready' >&2; exit 1; }
    if bash "$ROOT/bin/fleet-board" tick > "$TMP/merge-out" 2>&1; then echo 'FAIL: verification infrastructure failure accepted' >&2; exit 1; fi
    [ -e "$TMP/state/merged" ] || { echo 'FAIL: eligible PR was not merged' >&2; exit 1; }
    [ "$(cat "$TMP/state/column")" = in_review ] || { echo 'FAIL: infra failure moved card' >&2; exit 1; }
    printf false > "$TMP/state/verify-mode"
    if bash "$ROOT/bin/fleet-board" tick > "$TMP/false-out" 2>&1; then echo 'FAIL: semantic verification failure accepted' >&2; exit 1; fi
    [ "$(cat "$TMP/state/column")" = in_review ] || { echo 'FAIL: false verification moved card' >&2; exit 1; }
    jq -e 'any(.[]; .id == 555 and (.body | contains("\"ok\": false")))' "$TMP/state/comments" >/dev/null || { echo 'FAIL: false verification not recorded' >&2; exit 1; }
    printf true > "$TMP/state/verify-mode"
    if [ "$1" = merge-done-resume ]; then
      touch "$TMP/state/fail-done-move"
      if bash "$ROOT/bin/fleet-board" tick > "$TMP/done-first" 2>&1; then echo 'FAIL: simulated Done move interruption succeeded' >&2; exit 1; fi
      [ "$(cat "$TMP/state/column")" = none ] || { echo 'FAIL: Done move did not remove source label' >&2; exit 1; }
    fi
    bash "$ROOT/bin/fleet-board" tick > "$TMP/verified-out" || { echo 'FAIL: successful verification failed' >&2; exit 1; }
    [ "$(cat "$TMP/state/column")" = done ] || { echo 'FAIL: verified card not done' >&2; exit 1; }
    grep -q -- '--match-head-commit' "$TMP/state/calls" || { echo 'FAIL: merge omitted reviewed SHA precondition' >&2; exit 1; }
    echo 'PASS: merge-verification'
    exit 0
  fi
  if [ "${1:-start}" = human-qa ] || [ "${1:-start}" = human-qa-resume-label ]; then
    touch "$TMP/state/qa-flag"
    if [ "$1" = human-qa-resume-label ]; then
      touch "$TMP/state/fail-qa-move"
      if bash "$ROOT/bin/fleet-board" tick > "$TMP/qa-first" 2>&1; then echo 'FAIL: simulated QA move interruption succeeded' >&2; exit 1; fi
      [ "$(cat "$TMP/state/column")" = none ] || { echo 'FAIL: QA label was not removed' >&2; exit 1; }
    fi
    if ! bash "$ROOT/bin/fleet-board" tick > "$TMP/qa-out"; then echo 'FAIL: Human QA tick failed' >&2; exit 1; fi
    jq -e '.outcome == "progress" and .cards[0].action == "to_human_qa"' "$TMP/qa-out" >/dev/null || { echo 'FAIL: Human QA outcome' >&2; exit 1; }
    [ "$(cat "$TMP/state/column")" = human_qa ] || { echo 'FAIL: card not in Human QA' >&2; exit 1; }
    jq -e 'any(.[]; .body | contains("What to check in Human QA"))' "$TMP/state/comments" >/dev/null || { echo 'FAIL: Human QA handoff missing' >&2; exit 1; }
    if grep -q '^pr merge ' "$TMP/state/calls"; then echo 'FAIL: Human QA card merged' >&2; exit 1; fi
    bash "$ROOT/bin/fleet-board" tick > "$TMP/qa-next" || exit 1
    [ "$(cat "$TMP/state/column")" = human_qa ] || { echo 'FAIL: Human QA gate released automatically' >&2; exit 1; }
    echo 'PASS: human-qa'
    exit 0
  fi
fi
if [ "${1:-start}" = resume ] || [ "${1:-start}" = resume-note ] || [ "${1:-start}" = resume-ref ]; then
  jq -e '[.[] | select(.body | contains("fleet-board:standalone-start:"))] | length == 1' "$TMP/state/comments" >/dev/null || { echo 'FAIL: report duplicated' >&2; exit 1; }
  [ "$(grep -c '^pr create ' "$TMP/state/calls")" = 1 ] || { echo 'FAIL: draft PR duplicated' >&2; exit 1; }
fi
echo "PASS: ${1:-start}"
