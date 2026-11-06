#!/usr/bin/env bash
# Focused local-board standalone integration regressions.
set -uo pipefail
[ "${1:-}" = local-qa ] || { echo 'usage: test-standalone-local.sh local-qa' >&2; exit 2; }
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
if FLEET_BOARD_ENFORCE_QA=1 bash "$SCRIPTS/board-move.sh" 1 in_review >"$TMP/out" 2>"$TMP/err"; then
  echo 'FAIL: standalone moved a Human QA card' >&2; exit 1
fi
[ "$(jq -r .state .fleet-board/cards/1.json)" = human_qa ] || { echo 'FAIL: Human QA state changed' >&2; exit 1; }
bash "$SCRIPTS/board-move.sh" 1 in_review || exit 1
[ "$(jq -r .state .fleet-board/cards/1.json)" = in_review ] || exit 1
echo 'PASS: local-qa'
