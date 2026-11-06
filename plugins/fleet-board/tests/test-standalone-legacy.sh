#!/usr/bin/env bash
# Replay the existing idle fixture through the legacy runner without standalone services.
set -uo pipefail
unset CDPATH
[ "${1:-}" = legacy-entry ] || { echo 'usage: test-standalone-legacy.sh legacy-entry' >&2; exit 2; }
TESTS="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$TESTS/../scripts"
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo" "$TMP/fake" "$TMP/home" "$TMP/bin" "$TMP/log"
git -C "$TMP/repo" init -q || exit 1
printf 'board: { repo: acme/toy }\nlimits: { tick_interval: 0 }\n' > "$TMP/repo/.fleet-board.yml"
cp "$TESTS/../fixtures/claude/tick-idle.jsonl" "$TMP/fake/1.jsonl" || exit 1
cat > "$TMP/helper" <<'HELPER'
#!/bin/sh
printf '%s\n' "$(basename "$0")" >> "$CALLS"
exit 0
HELPER
cp "$TMP/helper" "$TMP/settle"; cp "$TMP/helper" "$TMP/merge"; cp "$TMP/helper" "$TMP/cleanup"
cat > "$TMP/bin/docker" <<'DOCKER'
#!/bin/sh
printf 'unexpected docker invocation\n' >> "$CALLS"
exit 1
DOCKER
cat > "$TMP/standalone" <<'STANDALONE'
#!/bin/sh
printf 'unexpected standalone invocation\n' >> "$CALLS"
exit 1
STANDALONE
chmod +x "$TMP/bin/docker" "$TMP/standalone"
(
  unset FLEET_BOARD_CONFIG FLEET_BOARD_ISOLATE FLEET_BOARD_PLUGIN_DIR FLEET_BOARD_TICK_PROMPT FLEET_BOARD_RUN_ID
  export HOME="$TMP/home" PATH="$TMP/bin:$PATH" CALLS="$TMP/calls"
  export FLEET_BOARD_CLAUDE="$TESTS/fake-claude.sh" FAKE_CLAUDE_DIR="$TMP/fake" FLEET_BOARD_LOG_DIR="$TMP/log"
  export FLEET_BOARD_SETTLE="$TMP/settle" FLEET_BOARD_MERGE_REVIEWED="$TMP/merge" FLEET_BOARD_CLEANUP="$TMP/cleanup"
  export FLEET_BOARD_STANDALONE_TICK="$TMP/standalone" FLEET_BOARD_TICK_PLAN="$TMP/standalone"
  cd "$TMP/repo" || exit 1
  bash "$SCRIPTS/fleet-board-run.sh"
) > "$TMP/out" 2> "$TMP/err"; rc=$?
# These are the legacy fixture's established result and status (test-run.sh).
[ "$rc" = 0 ] && grep -Fq 'stopped: nothing-dispatchable after 1 ticks' "$TMP/out" && [ "$(cat "$TMP/fake/count")" = 1 ] || { cat "$TMP/out" "$TMP/err" >&2; echo "FAIL: legacy result or exit status (rc=$rc)" >&2; exit 1; }
printf 'settle\nmerge\ncleanup\n' > "$TMP/expected"
cmp -s "$TMP/expected" "$TMP/calls" || { cat "$TMP/calls" >&2; echo 'FAIL: legacy helper order or standalone dependency' >&2; exit 1; }
echo 'PASS: legacy-entry'
