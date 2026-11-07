#!/usr/bin/env bash
# Focused local-board standalone integration regressions.
set -uo pipefail
case "${1:-}" in local-qa|local-comments|run-lock) ;; *) echo 'usage: test-standalone-local.sh local-qa|local-comments' >&2; exit 2 ;; esac
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo/.fleet-board/cards"
git -C "$TMP/repo" init -q
cat > "$TMP/repo/.fleet-board.yml" <<'YML'
board: { backend: local, repo: acme/toy }
worktrees: { dir: .worktrees }
YML
printf '2\n' > "$TMP/repo/.fleet-board/next"
printf '%s\n' '{"number":1,"state":"human_qa","body":"## Acceptance\n- yes"}' > "$TMP/repo/.fleet-board/cards/1.json"
cd "$TMP/repo" || exit 1
if [ "$1" = run-lock ]; then
  cat > "$TMP/tick" <<TICK
#!/bin/bash
touch "$TMP/tick-started"
sleep 15
printf '%s\n' '{"outcome":"idle","dispatchable":false,"cost_usd":0}'
TICK
  export FLEET_BOARD_STANDALONE_TICK="$TMP/tick" FLEET_BOARD_LOG_DIR="$TMP/logs"
  bash "$SCRIPTS/standalone/run.sh" --repo "$PWD" > "$TMP/first" 2>&1 & run_pid=$!
  for i in {1..100}; do [ -e "$TMP/tick-started" ] && break; sleep 0.1; done
  [ -e "$TMP/tick-started" ] || { kill "$run_pid" 2>/dev/null || true; wait "$run_pid" 2>/dev/null || true; echo 'FAIL: first run did not start' >&2; exit 1; }
  if bash "$SCRIPTS/standalone/run.sh" --repo "$PWD" > "$TMP/second" 2>&1; then
    kill "$run_pid" 2>/dev/null || true; wait "$run_pid" 2>/dev/null || true
    echo 'FAIL: duplicate standalone run accepted' >&2; exit 1
  fi
  kill "$run_pid" 2>/dev/null || true; wait "$run_pid" 2>/dev/null || true
  grep -q 'another run holds' "$TMP/second" || { echo 'FAIL: lock refusal not identified' >&2; exit 1; }
  echo 'PASS: run-lock'; exit 0
fi
if [ "$1" = local-comments ]; then
  jq '.comments = [{id:4, author:"fleet-bot", body:"<!-- fleet-board:standalone-review:abc -->\nclean", created_at:"2026-01-01T00:00:00Z"}]' .fleet-board/cards/1.json > "$TMP/card"
  mv "$TMP/card" .fleet-board/cards/1.json
  export FLEET_BOARD_USER=fleet-bot
  comments="$(bash "$SCRIPTS/standalone/comments.sh" 1)" || exit 1
  jq -e 'length == 1 and .[0].author == "fleet-bot" and (. [0].body | startswith("<!-- fleet-board:standalone-review:abc -->"))' <<<"$comments" >/dev/null || exit 1
  echo 'PASS: local-comments'; exit 0
fi
if FLEET_BOARD_ENFORCE_QA=1 bash "$SCRIPTS/board-move.sh" 1 in_review >"$TMP/out" 2>"$TMP/err"; then
  echo 'FAIL: standalone moved a Human QA card' >&2; exit 1
fi
[ "$(jq -r .state .fleet-board/cards/1.json)" = human_qa ] || { echo 'FAIL: Human QA state changed' >&2; exit 1; }
bash "$SCRIPTS/board-move.sh" 1 in_review || exit 1
[ "$(jq -r .state .fleet-board/cards/1.json)" = in_review ] || exit 1
echo 'PASS: local-qa'
