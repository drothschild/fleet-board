#!/usr/bin/env bash
# Focused local-board standalone integration regressions.
set -uo pipefail
case "${1:-}" in local-qa|local-comments) ;; *) echo 'usage: test-standalone-local.sh local-qa|local-comments' >&2; exit 2 ;; esac
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
