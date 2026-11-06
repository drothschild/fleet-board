#!/usr/bin/env bash
# Targeted standalone CLI cases. Run one named case at a time.
set -uo pipefail
unset CDPATH
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
case "${1:-}" in
  maintenance-block-resume|maintenance-file-pending) exec bash "$TEST_DIR/test-standalone-maintenance-cli.sh" "$1" ;;
  run-limits|run-cancel-real) exec bash "$TEST_DIR/test-standalone-run.sh" "$1" ;;
  legacy-entry) exec bash "$TEST_DIR/test-standalone-legacy.sh" "$1" ;;
esac
if [ "${1:-}" = multi-card ] || [ "${1:-}" = multi-card-skip ] || [ "${1:-}" = multi-card-provider ] || [ "${1:-}" = multi-card-lock ] || [ "${1:-}" = multi-card-parallel ] || [ "${1:-}" = multi-card-limit ] || [ "${1:-}" = multi-card-wait ] || [ "${1:-}" = multi-card-lint ] || [ "${1:-}" = git-lock-cancel ]; then
  exec bash "$TEST_DIR/test-standalone-multi-card.sh" "$1"
fi
if [ "${1:-}" = card-lifecycle ]; then
  bash "$TEST_DIR/test-standalone-start.sh" fix-re-review || exit 1
  bash "$TEST_DIR/test-standalone-start.sh" advisory-stage || exit 1
  echo 'PASS: card-lifecycle'
  exit 0
fi
if [ "${1:-}" = start ] || [ "${1:-}" = resume ] || [ "${1:-}" = push-destination ] || [ "${1:-}" = resume-note ] || [ "${1:-}" = tick-interrupt ] || [ "${1:-}" = symlink-checkout ] || [ "${1:-}" = resume-ref ] || [ "${1:-}" = interrupt-pr ] || [ "${1:-}" = clean-review ] || [ "${1:-}" = review-stale ] || [ "${1:-}" = review-human-race ] || [ "${1:-}" = review-followups ] || [ "${1:-}" = findings-review ] || [ "${1:-}" = review-move-race ] || [ "${1:-}" = fix-re-review ] || [ "${1:-}" = fix-resume-note ] || [ "${1:-}" = fix-two-rounds ] || [ "${1:-}" = review-resume-verdict ] || [ "${1:-}" = human-qa ] || [ "${1:-}" = review-resume-label ] || [ "${1:-}" = human-qa-resume-label ] || [ "${1:-}" = merge-verification ] || [ "${1:-}" = stale-head ] || [ "${1:-}" = merge-qa-race ] || [ "${1:-}" = merge-state-race ] || [ "${1:-}" = merge-done-resume ] || [ "${1:-}" = advisory-stage ] || [ "${1:-}" = stage-fix ] || [ "${1:-}" = stage-standard ] || [ "${1:-}" = projects-review ] || [ "${1:-}" = projects-qa-race ] || [ "${1:-}" = real-run ] || [ "${1:-}" = continue-implementor ] || [ "${1:-}" = continue-resume ] || [ "${1:-}" = implementor-blocked ] || [ "${1:-}" = continue-blocked ] || [ "${1:-}" = continue-blocked-resume ] || [ "${1:-}" = blocked-changed-blocker ] || [ "${1:-}" = blocked-spoof ] || [ "${1:-}" = blocked-report-changed ]; then
  exec bash "$TEST_DIR/test-standalone-start.sh" "$1"
fi
if [ "${1:-}" = worker-boundary ]; then
  TMP="$(mktemp -d)"
  SERVER_PID=""
  trap '[ -z "$SERVER_PID" ] || { kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; }; rm -rf "$TMP"' EXIT
  mkdir -p "$TMP/source" "$TMP/scratch" "$TMP/home"
  cat > "$TMP/server.py" <<'PY_SERVER'
import http.server, pathlib, sys
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        pathlib.Path(sys.argv[2]).write_text("mutation")
        self.send_response(200)
        self.end_headers()
    def log_message(self, *args): pass
server = http.server.HTTPServer(("0.0.0.0", 0), Handler)
pathlib.Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
PY_SERVER
  python3 "$TMP/server.py" "$TMP/scratch/port" "$TMP/mutated" & SERVER_PID=$!
  for unused in 1 2 3 4 5; do [ -s "$TMP/scratch/port" ] && break; sleep 1; done
  [ -s "$TMP/scratch/port" ] || { echo 'FAIL: endpoint did not start' >&2; exit 1; }
  curl --noproxy '*' -fsS -X POST "http://127.0.0.1:$(cat "$TMP/scratch/port")/mutation" >/dev/null || exit 1
  [ -e "$TMP/mutated" ] || { echo 'FAIL: endpoint positive control failed' >&2; exit 1; }
  rm "$TMP/mutated"
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
  git -C "$TMP/source" worktree add -q -b worker-fixture "$TMP/linked" "$REF"
  printf 'controller metadata secret\n' > "$TMP/source/.git/controller-secret"
  [ -f "$TMP/linked/.git" ] || { echo 'FAIL: fixture is not a linked worktree' >&2; exit 1; }
  cat > "$TMP/scratch/worker.sh" <<'WORKER'
#!/bin/sh
set -eu
[ ! -e /controller-secret ]
[ ! -r escape ]
[ ! -e /var/run/docker.sock ]
[ -z "${GH_TOKEN:-}" ]
if [ ! -f /scratch/request.json ] || ! grep -q '"role": "implementor"' /scratch/request.json; then exit 1; fi
if printf changed > /scratch/request.json 2>/dev/null; then exit 1; fi
[ -d .git ] && [ ! -L .git ]
[ ! -e .git/controller-secret ]
[ ! -e .git/objects/info/alternates ]
! curl --noproxy '*' -fsS --max-time 2 -X POST "http://host.docker.internal:$(cat /scratch/port)/mutation" >/dev/null 2>&1
! grep -q '^eth' /proc/net/route
printf 'edited\n' > file.txt
[ "$(cat file.txt)" = edited ]
printf '%s\n' '{"version":1,"outcome":"done","report":"## Status\ndone\n## Findings\n- none\n## For the card\nImplemented\n## PR\n#34\nVERIFIED: `true` -> 0 failures"}' > /scratch/result.json
WORKER
  jq -n --arg source "$TMP/linked" --arg scratch "$TMP/scratch" --arg ref "$REF" \
    '{version:1,card:12,action:"start",role:"implementor",worktree:$source,expected_ref:$ref,prompt:"fixture",limits:{seconds:8,memory_mb:256,pids:64},permissions:{network:false},image:"ghcr.io/home-assistant/home-assistant:stable"}' > "$TMP/request.json"
  export GH_TOKEN=controller-secret
  cat > "$TMP/observe-kill" <<OBSERVER
kill() {
  if [ "\${1:-}" = -KILL ]; then printf '%s\n' "\$*" >> "$TMP/kill-log"; fi
  builtin kill "\$@"
}
OBSERVER
  START_TIME="$(date +%s)"
  if ! OUTPUT="$(BASH_ENV="$TMP/observe-kill" bash "$ROOT/bin/fleet-board" worker --request "$TMP/request.json" --scratch "$TMP/scratch")"; then
    echo 'FAIL: isolated worker should succeed' >&2; exit 1
  fi
  END_TIME="$(date +%s)"
  if [ -e "$TMP/kill-log" ]; then echo 'FAIL: cleanup killed an already-reaped client' >&2; exit 1; fi
  if [ "$((END_TIME - START_TIME))" -ge 7 ]; then echo 'FAIL: worker left a timer holding output open' >&2; exit 1; fi
  printf '%s\n' "$OUTPUT" > "$TMP/out"
  if ! jq -e '.version == 1 and .outcome == "done" and (.report | contains("## Status"))' "$TMP/out" >/dev/null; then
    echo 'FAIL: worker result was not validated' >&2; exit 1
  fi
  [ ! -e "$TMP/mutated" ] || { echo 'FAIL: worker reached mutation endpoint' >&2; exit 1; }
  [ "$(cat "$TMP/linked/file.txt")" = original ] || { echo 'FAIL: linked worktree changed' >&2; exit 1; }
  [ "$(cat "$TMP/source/file.txt")" = original ] || { echo 'FAIL: controller checkout changed' >&2; exit 1; }
  [ "$(cat "$TMP/scratch/checkout/file.txt")" = edited ] || { echo 'FAIL: worker checkout not edited' >&2; exit 1; }
  mkdir "$TMP/invalid"
  cat > "$TMP/invalid/worker.sh" <<'WORKER'
#!/bin/sh
printf '%s\n' '{"version":1,"outcome":"done","report":"not a valid report"}' > /scratch/result.json
WORKER
  if bash "$ROOT/bin/fleet-board" worker --request "$TMP/request.json" --scratch "$TMP/invalid" >/dev/null 2>&1; then
    echo 'FAIL: malformed worker report accepted' >&2; exit 1
  fi
  # Interrupt while the Docker client has not yet started the container.
  mkdir "$TMP/delayed" "$TMP/wrapper"
  cp "$TMP/scratch/worker.sh" "$TMP/delayed/worker.sh"
  REAL_DOCKER="$(command -v docker)"
  cat > "$TMP/wrapper/docker" <<WRAPPER
#!/bin/bash
case "\$1" in
  run|start) touch "$TMP/start-pending"; sleep 4 ;;
esac
exec "$REAL_DOCKER" "\$@"
WRAPPER
  chmod +x "$TMP/wrapper/docker"
  PATH="$TMP/wrapper:$PATH" bash "$ROOT/bin/fleet-board" worker --request "$TMP/request.json" --scratch "$TMP/delayed" > "$TMP/delayed.out" 2>&1 & WORKER_PID=$!
  for unused in 1 2 3 4 5; do [ -e "$TMP/start-pending" ] && break; sleep 1; done
  [ -e "$TMP/start-pending" ] || { kill "$WORKER_PID" 2>/dev/null || true; echo 'FAIL: delayed start was not reached' >&2; exit 1; }
  kill -TERM "$WORKER_PID"
  wait "$WORKER_PID" 2>/dev/null || true
  sleep 5
  if docker ps -a --filter "name=fleet-worker-$(basename "$TMP/delayed")-" --format '{{.Names}}' | grep -q .; then
    echo 'FAIL: container survived interrupted startup' >&2; exit 1
  fi
  if [ -e "$TMP/delayed/result.json" ]; then echo 'FAIL: worker ran after interrupted startup' >&2; exit 1; fi
  # TERM must stop even a worker that ignores TERM.
  mkdir "$TMP/stubborn"
  cat > "$TMP/stubborn/worker.sh" <<'WORKER'
#!/bin/sh
trap '' TERM
: > /scratch/running
while :; do sleep 1; done
WORKER
  mkdir "$TMP/stubborn-wrapper"
  cat > "$TMP/stubborn-wrapper/docker" <<WRAPPER
#!/bin/bash
if [ "\$1" = start ]; then
  trap '' TERM
  "$REAL_DOCKER" "\$@" & child=\$!
  wait "\$child"
else
  exec "$REAL_DOCKER" "\$@"
fi
WRAPPER
  chmod +x "$TMP/stubborn-wrapper/docker"
  PATH="$TMP/stubborn-wrapper:$PATH" bash "$ROOT/bin/fleet-board" worker --request "$TMP/request.json" --scratch "$TMP/stubborn" > "$TMP/stubborn.out" 2>&1 & WORKER_PID=$!
  for unused in 1 2 3 4 5; do [ -e "$TMP/stubborn/running" ] && break; sleep 1; done
  [ -e "$TMP/stubborn/running" ] || { kill "$WORKER_PID" 2>/dev/null || true; echo 'FAIL: stubborn worker did not start' >&2; exit 1; }
  kill -TERM "$WORKER_PID"
  for unused in 1 2 3 4 5; do kill -0 "$WORKER_PID" 2>/dev/null || break; sleep 1; done
  if kill -0 "$WORKER_PID" 2>/dev/null; then
    docker ps -aq --filter "name=fleet-worker-$(basename "$TMP/stubborn")-" | xargs docker rm -f >/dev/null 2>&1 || true
    kill -KILL "$WORKER_PID" 2>/dev/null || true
    wait "$WORKER_PID" 2>/dev/null || true
    echo 'FAIL: interrupted stubborn worker did not stop' >&2; exit 1
  fi
  wait "$WORKER_PID" 2>/dev/null || true
  if docker ps -a --filter "name=fleet-worker-$(basename "$TMP/stubborn")-" --format '{{.Names}}' | grep -q .; then
    echo 'FAIL: stubborn worker container survived' >&2; exit 1
  fi
  # A second TERM during container removal must not abort cleanup.
  mkdir "$TMP/duplicate" "$TMP/duplicate-wrapper"
  cat > "$TMP/duplicate/worker.sh" <<'WORKER'
#!/bin/sh
: > /scratch/running
while :; do sleep 1; done
WORKER
  cat > "$TMP/duplicate-wrapper/docker" <<WRAPPER
#!/bin/bash
if [ "\$1" = rm ]; then touch "$TMP/removing"; sleep 3; fi
exec "$REAL_DOCKER" "\$@"
WRAPPER
  chmod +x "$TMP/duplicate-wrapper/docker"
  PATH="$TMP/duplicate-wrapper:$PATH" bash "$ROOT/bin/fleet-board" worker --request "$TMP/request.json" --scratch "$TMP/duplicate" > "$TMP/duplicate.out" 2>&1 & WORKER_PID=$!
  NAME="fleet-worker-$(basename "$TMP/duplicate")-$WORKER_PID"
  for unused in 1 2 3 4 5; do [ -e "$TMP/duplicate/running" ] && break; sleep 1; done
  [ -e "$TMP/duplicate/running" ] || { docker rm -f "$NAME" >/dev/null 2>&1 || true; kill -KILL "$WORKER_PID" 2>/dev/null || true; echo 'FAIL: duplicate-signal worker did not start' >&2; exit 1; }
  kill -TERM "$WORKER_PID"
  for unused in 1 2 3 4 5; do [ -e "$TMP/removing" ] && break; sleep 1; done
  [ -e "$TMP/removing" ] || { docker rm -f "$NAME" >/dev/null 2>&1 || true; kill -KILL "$WORKER_PID" 2>/dev/null || true; echo 'FAIL: cleanup was not reached' >&2; exit 1; }
  kill -TERM "$WORKER_PID" 2>/dev/null || true
  wait "$WORKER_PID" 2>/dev/null || true
  if docker inspect "$NAME" >/dev/null 2>&1; then
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    echo 'FAIL: duplicate signal interrupted cleanup' >&2; exit 1
  fi
  if PATH=/nonexistent /bin/bash "$ROOT/bin/fleet-board" worker --request "$TMP/request.json" --scratch "$TMP/scratch" >/dev/null 2>&1; then
    echo 'FAIL: unavailable isolation accepted' >&2; exit 1
  fi
  echo 'PASS: worker-boundary'
  exit 0
fi
case "${1:-}" in
  plan-only|tick-holds|tick-cost|interrupt-planner|hard-kill-lock|lock-reentry) ;;
  *) echo "usage: $0 plan-only|tick-holds|worker-boundary" >&2; exit 2 ;;
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
if [ "$1" = lock-reentry ]; then
  jq '.cards[0].action = "skip" | .dispatchable = false' "$TMP/expected" > "$TMP/idle-plan"
  cat > "$TMP/inner-planner" <<PLANNER
#!/bin/bash
cat "$TMP/idle-plan"
PLANNER
  cat > "$TMP/outer-planner" <<PLANNER
#!/bin/bash
if FLEET_BOARD_TICK_PLAN="$TMP/inner-planner" bash "$ROOT/bin/fleet-board" tick > "$TMP/inner-out" 2> "$TMP/inner-err"; then
  printf allowed > "$TMP/reentry"
else
  printf blocked > "$TMP/reentry"
fi
cat "$TMP/idle-plan"
PLANNER
  FLEET_BOARD_TICK_PLAN="$TMP/outer-planner" bash "$ROOT/bin/fleet-board" tick > "$TMP/outer-out" || exit 1
  [ "$(cat "$TMP/reentry")" = blocked ] || { echo 'FAIL: inherited lock allowed nested tick' >&2; exit 1; }
  grep -q 'another standalone tick holds the repository lock' "$TMP/inner-err" || { echo 'FAIL: nested tick was not rejected by lock' >&2; exit 1; }
  echo 'PASS: lock-reentry'
  exit 0
fi
if [ "$1" = hard-kill-lock ]; then
  cat > "$TMP/blocked-planner" <<PLANNER
#!/bin/bash
sleep 30 & child=\$!
printf '%s %s\n' \$$ \$child > "$TMP/lock-pids"
wait \$child
PLANNER
  FLEET_BOARD_TICK_PLAN="$TMP/blocked-planner" bash "$ROOT/bin/fleet-board" tick > "$TMP/killed-out" 2>&1 & TICK_PID=$!
  for unused in 1 2 3 4 5; do [ -s "$TMP/lock-pids" ] && break; sleep 1; done
  [ -s "$TMP/lock-pids" ] || { kill -KILL "$TICK_PID" 2>/dev/null || true; echo 'FAIL: lock fixture did not start' >&2; exit 1; }
  read -r PLANNER_PID PLANNER_CHILD < "$TMP/lock-pids"
  kill -KILL "$PLANNER_CHILD" "$PLANNER_PID" "$TICK_PID" 2>/dev/null || true
  wait "$TICK_PID" 2>/dev/null || true
  jq '.cards[0].action = "skip" | .dispatchable = false' "$TMP/expected" > "$TMP/idle-plan"
  cat > "$TMP/idle-planner" <<PLANNER
#!/bin/bash
cat "$TMP/idle-plan"
PLANNER
  if ! FLEET_BOARD_TICK_PLAN="$TMP/idle-planner" bash "$ROOT/bin/fleet-board" tick > "$TMP/resumed" 2> "$TMP/resumed-err"; then
    cat "$TMP/resumed-err" >&2; echo 'FAIL: hard-killed tick left repository locked' >&2; exit 1
  fi
  jq -e '.outcome == "idle"' "$TMP/resumed" >/dev/null || exit 1
  echo 'PASS: hard-kill-lock'
  exit 0
fi
if [ "$1" = interrupt-planner ]; then
  cat > "$TMP/slow-planner" <<PLANNER
#!/bin/bash
trap '' TERM
sleep 30 & child=\$!
printf '%s %s\n' \$$ \$child > "$TMP/planner-pids"
wait \$child
PLANNER
  FLEET_BOARD_TICK_PLAN="$TMP/slow-planner" bash "$ROOT/bin/fleet-board" tick > "$TMP/interrupted" 2>&1 & TICK_PID=$!
  for unused in 1 2 3 4 5; do [ -s "$TMP/planner-pids" ] && break; sleep 1; done
  [ -s "$TMP/planner-pids" ] || { kill -KILL "$TICK_PID" 2>/dev/null || true; echo 'FAIL: planner did not start' >&2; exit 1; }
  read -r PLANNER_PID PLANNER_CHILD < "$TMP/planner-pids"
  kill -TERM "$TICK_PID"
  for unused in 1 2 3 4 5 6 7 8; do kill -0 "$TICK_PID" 2>/dev/null || break; sleep 1; done
  if kill -0 "$TICK_PID" 2>/dev/null; then
    kill -KILL "$PLANNER_CHILD" "$PLANNER_PID" "$TICK_PID" 2>/dev/null || true
    wait "$TICK_PID" 2>/dev/null || true
    echo 'FAIL: interrupted planner did not stop' >&2; exit 1
  fi
  wait "$TICK_PID" 2>/dev/null || true
  if kill -0 "$PLANNER_PID" 2>/dev/null || kill -0 "$PLANNER_CHILD" 2>/dev/null; then
    kill -KILL "$PLANNER_CHILD" "$PLANNER_PID" 2>/dev/null || true
    echo 'FAIL: interrupted planner left children' >&2; exit 1
  fi
  echo 'PASS: interrupt-planner'
  exit 0
fi
if [ "$1" = tick-holds ] || [ "$1" = tick-cost ]; then
  if [ "$1" = tick-cost ]; then export FLEET_BOARD_STANDALONE_FIXTURE=1 FLEET_BOARD_FIXTURE_ROOT="$TMP"; fi
  jq '.cards[0].action = "skip" | .dispatchable = false' "$TMP/expected" > "$TMP/idle.json"
  cat > "$TMP/planner" <<PLAN
#!/usr/bin/env bash
cat "$TMP/idle.json"
PLAN
  chmod +x "$TMP/planner"
  if ! FLEET_BOARD_TICK_PLAN="$TMP/planner" bash "$ROOT/bin/fleet-board" tick > "$TMP/idle-out"; then
    echo 'FAIL: idle tick failed' >&2; exit 1
  fi
  if ! jq -e '.outcome == "idle" and .dispatchable == false and .cards[0].action == "skip"' "$TMP/idle-out" >/dev/null; then
    echo 'FAIL: idle tick outcome malformed' >&2; exit 1
  fi
  if [ "$1" = tick-cost ]; then
    jq -e '.cost_usd == 0' "$TMP/idle-out" >/dev/null || { echo 'FAIL: idle tick cost missing' >&2; exit 1; }
  fi
  cp "$TMP/expected" "$TMP/idle.json"
  if FLEET_BOARD_TICK_PLAN="$TMP/planner" bash "$ROOT/bin/fleet-board" tick > "$TMP/held-out" 2>/dev/null; then
    echo 'FAIL: unsupported start action accepted' >&2; exit 1
  fi
  if [ "$1" = tick-cost ]; then
    jq -e '.outcome == "failed" and .cost_usd == 0' "$TMP/held-out" >/dev/null || { echo 'FAIL: failed fixture tick cost missing' >&2; exit 1; }
  elif [ -s "$TMP/held-out" ]; then echo 'FAIL: held action reported success' >&2; exit 1; fi
  for call in "$FAKE_GH_DIR"/argv/*; do
    [ -f "$call" ] || continue
    if grep -Eq '^(create|edit|comment|close|merge)$' "$call"; then echo 'FAIL: held tick wrote to board' >&2; exit 1; fi
  done
  echo "PASS: $1"
  exit 0
fi
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
