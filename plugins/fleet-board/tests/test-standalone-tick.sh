#!/usr/bin/env bash
# Targeted standalone CLI cases. Run one named case at a time.
set -uo pipefail
unset CDPATH
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
if [ "${1:-}" = worker-boundary ]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  mkdir -p "$TMP/source" "$TMP/scratch" "$TMP/home"
  git -C "$TMP/source" init -q
  git -C "$TMP/source" config user.email test@example.com
  git -C "$TMP/source" config user.name 'Test User'
  printf 'original\n' > "$TMP/source/file.txt"
  git -C "$TMP/source" add file.txt
  git -C "$TMP/source" commit -q -m initial
  REF="$(git -C "$TMP/source" rev-parse HEAD)"
  printf 'secret\n' > "$TMP/home/credential"
  ln -s "$TMP/home/credential" "$TMP/source/escape"
  git -C "$TMP/source" add escape
  git -C "$TMP/source" commit -q -m 'add symlink'
  REF="$(git -C "$TMP/source" rev-parse HEAD)"
  cat > "$TMP/scratch/worker.sh" <<'WORKER'
#!/bin/sh
set -eu
[ ! -e /controller-secret ]
[ ! -r escape ]
[ ! -e /var/run/docker.sock ]
[ -z "${GH_TOKEN:-}" ]
[ ! -e .git/objects/info/alternates ]
! git ls-remote https://github.com/example/nonexistent.git >/dev/null 2>&1
printf 'edited\n' > file.txt
[ "$(cat file.txt)" = edited ]
printf '%s\n' '{"version":1,"outcome":"done","report":"worker report"}' > /scratch/result.json
WORKER
  jq -n --arg source "$TMP/source" --arg scratch "$TMP/scratch" --arg ref "$REF" \
    '{version:1,card:12,action:"start",role:"implementor",worktree:$source,expected_ref:$ref,prompt:"fixture",limits:{seconds:30,memory_mb:256,pids:64},permissions:{network:false},image:"ghcr.io/home-assistant/home-assistant:stable"}' > "$TMP/request.json"
  export GH_TOKEN=controller-secret
  if ! bash "$ROOT/bin/fleet-board" worker --request "$TMP/request.json" --scratch "$TMP/scratch" > "$TMP/out"; then
    echo 'FAIL: isolated worker should succeed' >&2; exit 1
  fi
  if ! jq -e '.version == 1 and .outcome == "done" and .report == "worker report"' "$TMP/out" >/dev/null; then
    echo 'FAIL: worker result was not validated' >&2; exit 1
  fi
  [ "$(cat "$TMP/source/file.txt")" = original ] || { echo 'FAIL: controller checkout changed' >&2; exit 1; }
  [ "$(cat "$TMP/scratch/checkout/file.txt")" = edited ] || { echo 'FAIL: worker checkout not edited' >&2; exit 1; }
  if PATH=/nonexistent /bin/bash "$ROOT/bin/fleet-board" worker --request "$TMP/request.json" --scratch "$TMP/scratch" >/dev/null 2>&1; then
    echo 'FAIL: unavailable isolation accepted' >&2; exit 1
  fi
  echo 'PASS: worker-boundary'
  exit 0
fi
case "${1:-}" in
  plan-only) ;;
  *) echo "usage: $0 plan-only" >&2; exit 2 ;;
esac
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo" "$TMP/bin" "$TMP/gh"
git -C "$TMP/repo" init -q
git -C "$TMP/repo" config user.email test@example.com
git -C "$TMP/repo" config user.name 'Test User'
printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\nhuman_qa_paths: ["src/components/**"]\ncommands:\n  preflight: touch preflight-ran\n' > "$TMP/repo/.fleet-board.yml"
git -C "$TMP/repo" add .fleet-board.yml
git -C "$TMP/repo" commit -q -m initial
ln -s "$TEST_DIR/fake-gh.sh" "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" FAKE_GH_DIR="$TMP/gh" FAKE_GH_ROUTES="$ROOT/plugins/fleet-board/fixtures/gh/tick/ready-start/routes"
cd "$TMP/repo"
bash "$ROOT/plugins/fleet-board/scripts/tick-plan.sh" > "$TMP/expected" || exit 1
rm -rf "$TMP/repo/.fw" "$TMP/repo/preflight-ran"
if ! bash "$ROOT/bin/fleet-board" tick --plan-only > "$TMP/actual"; then
  echo 'FAIL: standalone plan-only should succeed' >&2; exit 1
fi
if [ -e "$TMP/repo/preflight-ran" ] || [ -e "$TMP/repo/.fw" ]; then
  echo 'FAIL: plan-only ran preflight or created worktree directory' >&2; exit 1
fi
if ! cmp -s "$TMP/expected" "$TMP/actual"; then
  echo 'FAIL: standalone plan differs from planner' >&2; exit 1
fi
jq '.cards[0].action = "surprise"' "$TMP/expected" > "$TMP/unknown.json"
cat > "$TMP/unknown-plan" <<PLAN
#!/usr/bin/env bash
cat "$TMP/unknown.json"
PLAN
chmod +x "$TMP/unknown-plan"
if FLEET_BOARD_TICK_PLAN="$TMP/unknown-plan" bash "$ROOT/bin/fleet-board" tick --plan-only > "$TMP/unknown-out" 2> "$TMP/unknown-err"; then
  echo 'FAIL: unknown action accepted' >&2; exit 1
fi
if [ -s "$TMP/unknown-out" ]; then echo 'FAIL: invalid plan emitted' >&2; exit 1; fi
cat > "$TMP/malformed-plan" <<'PLAN'
#!/usr/bin/env bash
printf '%s\n' '{"dispatchable":true,"warnings":[],"cards":[{"number":12,"action":"start"}]}'
PLAN
chmod +x "$TMP/malformed-plan"
if FLEET_BOARD_TICK_PLAN="$TMP/malformed-plan" bash "$ROOT/bin/fleet-board" tick --plan-only > "$TMP/malformed-out" 2> "$TMP/malformed-err"; then
  echo 'FAIL: malformed card accepted' >&2; exit 1
fi
if [ -s "$TMP/malformed-out" ]; then echo 'FAIL: malformed plan emitted' >&2; exit 1; fi
# A known action with invalid typed data must also fail closed.
cat > "$TMP/typed-plan" <<PLAN
#!/usr/bin/env bash
cat "$TMP/typed.json"
PLAN
chmod +x "$TMP/typed-plan"
for mutation in '.cards[0].pr = "12"' '.cards[0].round = "1"' '.cards[0].stage = 7' '.cards[0].needs_human_qa = "yes"' '.cards[0].models.implementor = 42'; do
  jq "$mutation" "$TMP/expected" > "$TMP/typed.json"
  if FLEET_BOARD_TICK_PLAN="$TMP/typed-plan" bash "$ROOT/bin/fleet-board" tick --plan-only > "$TMP/typed-out" 2>/dev/null; then
    echo "FAIL: invalid field accepted: $mutation" >&2; exit 1
  fi
  if [ -s "$TMP/typed-out" ]; then echo 'FAIL: invalid typed plan emitted' >&2; exit 1; fi
done
for call in "$FAKE_GH_DIR"/argv/*; do
  [ -f "$call" ] || continue
  if grep -Eq '^(create|edit|comment|close|merge)$' "$call"; then
    echo 'FAIL: board or GitHub write during plan-only' >&2; exit 1
  fi
done
# A changed reviewed head must not fetch or create merge-tree objects.
mkdir -p "$TMP/drift"
sed 's/\\"important\\":1/\\"important\\":0/' "$ROOT/plugins/fleet-board/fixtures/gh/tick/drift-merge/comments-12.json" > "$TMP/drift/comments.json"
while IFS="$(printf '\t')" read -r key status file; do
  case "$key" in ''|\#*) continue ;; esac
  case "$file" in comments-12.json) file="$TMP/drift/comments.json" ;; *) file="$ROOT/plugins/fleet-board/fixtures/gh/tick/drift-merge/$file" ;; esac
  printf '%s\t%s\t%s\n' "$key" "$status" "$file"
done < "$ROOT/plugins/fleet-board/fixtures/gh/tick/drift-merge/routes" > "$TMP/drift/routes"
REAL_GIT="$(command -v git)"
cat > "$TMP/bin/git" <<GIT
#!/usr/bin/env bash
case "\$1" in fetch|merge-tree) printf '%s\n' "\$1" >> "$TMP/git-writes" ;; esac
exec "$REAL_GIT" "\$@"
GIT
chmod +x "$TMP/bin/git"
export FAKE_GH_ROUTES="$TMP/drift/routes"
if ! bash "$ROOT/bin/fleet-board" tick --plan-only > "$TMP/drift-out"; then
  echo 'FAIL: drift plan failed' >&2; exit 1
fi
if [ -e "$TMP/git-writes" ]; then echo 'FAIL: drift check wrote to Git' >&2; exit 1; fi
if ! jq -e '.cards[0].action == "review"' "$TMP/drift-out" >/dev/null; then
  echo 'FAIL: moved head was not held for review' >&2; exit 1
fi
# Projects cache must stay outside the checkout even on a cold cache.
cat > "$TMP/repo/.fleet-board.yml" <<'YML'
board:
  backend: github-projects
  repo: drothschild/HMBWorkout
  project_number: 1
worktrees:
  dir: .fw
YML
printf '{"items":[]}\n' > "$TMP/items.json"
cat > "$TMP/routes" <<ROUTES
auth status	0	$ROOT/plugins/fleet-board/fixtures/gh/projects/auth-status-ok.txt
project view 1 --owner drothschild --format json	0	$ROOT/plugins/fleet-board/fixtures/gh/projects/project-view.json
project field-list 1 --owner drothschild --format json*	0	$ROOT/plugins/fleet-board/fixtures/gh/projects/field-list.json
project item-list 1 --owner drothschild --format json --limit *	0	$TMP/items.json
ROUTES
export FAKE_GH_ROUTES="$TMP/routes"
if ! bash "$ROOT/bin/fleet-board" tick --plan-only > "$TMP/projects-out"; then
  echo 'FAIL: projects plan failed' >&2; exit 1
fi
if [ -e "$TMP/repo/.fw" ]; then echo 'FAIL: projects cache wrote to checkout' >&2; exit 1; fi
echo 'PASS: plan-only'
