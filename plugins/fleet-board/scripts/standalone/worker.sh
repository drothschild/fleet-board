#!/usr/bin/env bash
# Launch a fixture worker in a disposable, networkless Docker container.
set -uo pipefail
unset CDPATH
[ "$#" -eq 4 ] && [ "$1" = --request ] && [ "$3" = --scratch ] || { echo 'usage: fleet-board worker --request FILE --scratch DIR' >&2; exit 2; }
REQUEST="$2" SCRATCH="$4"
command -v docker >/dev/null 2>&1 || { echo 'Docker isolation unavailable' >&2; exit 1; }
[ -f "$REQUEST" ] && [ -d "$SCRATCH" ] && [ -f "$SCRATCH/worker.sh" ] && [ ! -L "$SCRATCH/worker.sh" ] || { echo 'invalid worker inputs' >&2; exit 1; }
if ! jq -e '
  .version == 1 and (.card | type == "number" and . > 0 and floor == .) and
  (.action | IN("start", "continue_implementor", "review", "review_stage", "fix")) and
  (.role | IN("implementor", "reviewer", "stage-reviewer", "fixer")) and
  (.worktree | type == "string" and startswith("/")) and
  (.expected_ref | type == "string" and test("^[0-9a-f]{40}$")) and
  (.prompt | type == "string") and (.permissions.network == false) and
  (.image | type == "string" and length > 0 and test("^[A-Za-z0-9._/:@-]+$")) and
  (.limits.seconds | type == "number" and floor == . and . >= 1 and . <= 3600) and
  (.limits.memory_mb | type == "number" and floor == . and . >= 64 and . <= 8192) and
  (.limits.pids | type == "number" and floor == . and . >= 8 and . <= 512)
' "$REQUEST" >/dev/null 2>&1; then echo 'invalid worker request' >&2; exit 1; fi
SOURCE="$(jq -r .worktree "$REQUEST")"; REF="$(jq -r .expected_ref "$REQUEST")"
IMAGE="$(jq -r .image "$REQUEST")"; SECONDS_LIMIT="$(jq -r .limits.seconds "$REQUEST")"
MEMORY="$(jq -r .limits.memory_mb "$REQUEST")"; PIDS="$(jq -r .limits.pids "$REQUEST")"
SCRATCH="$(cd "$SCRATCH" && pwd -P)" || exit 1
case "$SCRATCH" in *,*|*$'\n'*) echo 'invalid scratch path' >&2; exit 1 ;; esac
[ ! -e "$SCRATCH/checkout" ] && [ ! -e "$SCRATCH/result.json" ] || { echo 'scratch is not fresh' >&2; exit 1; }
# Do not share linked worktree metadata, hard links, object alternates or remotes.
git clone -q --no-local --no-hardlinks -- "$SOURCE" "$SCRATCH/checkout" || exit 1
git -C "$SCRATCH/checkout" remote remove origin || exit 1
git -C "$SCRATCH/checkout" checkout -q --detach "$REF" || exit 1
[ "$(git -C "$SCRATCH/checkout" rev-parse HEAD)" = "$REF" ] && [ -d "$SCRATCH/checkout/.git" ] && [ ! -L "$SCRATCH/checkout/.git" ] && [ ! -e "$SCRATCH/checkout/.git/objects/info/alternates" ] || { echo 'unsafe worker checkout' >&2; exit 1; }
NAME="fleet-worker-$(basename "$SCRATCH")-$$"
# Create first so cancellation can always remove a known container before start.
PID="" WATCHDOG=""
cleanup() {
  [ -z "$WATCHDOG" ] || kill "$WATCHDOG" 2>/dev/null || true
  [ -z "$PID" ] || kill -KILL "$PID" 2>/dev/null || true
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  [ -z "$PID" ] || wait "$PID" 2>/dev/null || true
  [ -z "$WATCHDOG" ] || wait "$WATCHDOG" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Reviewers receive a read-only checkout even though their scratch is writable.
REVIEW_MOUNT=()
case "$(jq -r .role "$REQUEST")" in
  reviewer|stage-reviewer) REVIEW_MOUNT=(--mount "type=bind,src=$SCRATCH/checkout,dst=/scratch/checkout,readonly") ;;
esac
# No host credentials or controller checkout are mounted into the container.
docker create --pull never --name "$NAME" --network none --read-only --cap-drop ALL --security-opt no-new-privileges --pids-limit "$PIDS" --memory "${MEMORY}m" --cpus 1 --tmpfs /tmp:rw,noexec,nosuid,size=64m --mount "type=bind,src=$SCRATCH,dst=/scratch" ${REVIEW_MOUNT[@]+"${REVIEW_MOUNT[@]}"} --workdir /scratch/checkout --entrypoint /usr/bin/env "$IMAGE" -i PATH=/usr/bin:/bin HOME=/tmp /bin/sh /scratch/worker.sh >/dev/null || { echo 'cannot create isolated worker' >&2; exit 1; }
docker start -a "$NAME" > "$SCRATCH/worker.stdout" 2> "$SCRATCH/worker.stderr" &
PID=$!
(
  sleep "$SECONDS_LIMIT" & TIMER=$!
  trap 'kill "$TIMER" 2>/dev/null || true; wait "$TIMER" 2>/dev/null || true; exit 0' TERM INT
  wait "$TIMER" && docker rm -f "$NAME" >/dev/null 2>&1 || true
) </dev/null >/dev/null 2>&1 &
WATCHDOG=$!
wait "$PID"; RC=$?
PID=""
kill "$WATCHDOG" 2>/dev/null || true
wait "$WATCHDOG" 2>/dev/null || true
WATCHDOG=""
[ "$RC" -eq 0 ] || { echo 'isolated worker failed' >&2; exit 1; }
[ -f "$SCRATCH/result.json" ] && [ ! -L "$SCRATCH/result.json" ] && jq -e -s 'length == 1 and (.[0] | .version == 1 and (.outcome | IN("done", "blocked", "clean", "findings")) and (.report | type == "string" and length > 0))' "$SCRATCH/result.json" >/dev/null 2>&1 || { echo 'invalid worker result' >&2; exit 1; }
REPORT="$(mktemp)" || exit 1
jq -r .report "$SCRATCH/result.json" > "$REPORT" || { rm -f "$REPORT"; exit 1; }
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROLE="$(jq -r .role "$REQUEST")"
PARSED="$(bash "$SCRIPTS/parse-report.sh" --role "$ROLE" "$REPORT")" || { rm -f "$REPORT"; echo 'invalid worker report' >&2; exit 1; }
rm -f "$REPORT"
[ "$(jq -r .status <<<"$PARSED")" = "$(jq -r .outcome "$SCRATCH/result.json")" ] || { echo 'worker outcome does not match report' >&2; exit 1; }
cat "$SCRATCH/result.json"
