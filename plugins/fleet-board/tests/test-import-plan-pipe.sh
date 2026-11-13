#!/usr/bin/env bash
#
# Plain-bash tests for pipe escaping in the import-plan dry-run table.
# Offline: no gh call is reached with --dry-run.
#
# Usage: bash plugins/fleet-board/tests/test-import-plan-pipe.sh

set -uo pipefail
unset CDPATH FLEET_BOARD_CONFIG || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../scripts/import-plan.sh"

PASS=0
FAIL=0
CLEANUP_DIRS=()
cleanup() { for d in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do rm -rf "$d" 2>/dev/null || true; done; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s: %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi; }

SB="$(mktemp -d)"; CLEANUP_DIRS+=("$SB")
ROOT="$SB/root"; mkdir -p "$ROOT/.wt"
git -C "$ROOT" init -q
cat > "$ROOT/.fleet-board.yml" <<'EOF'
board:
  repo: acme/api
worktrees:
  dir: ".wt"
EOF
cat > "$SB/cards.json" <<'EOF'
{"cards":[
 {"key":"A","title":"Parse a|b input","repo":"acme/api","labels":["backend"],"acceptance":["The table prints"]},
 {"key":"B","title":"Plain title","repo":"acme/api","labels":["docs"],"depends_on":["A"],"acceptance":["The table prints"]}
]}
EOF
OUT="$(cd "$ROOT" && bash "$SCRIPT" "$SB/cards.json" --dry-run 2>"$SB/err")"

# count unescaped pipes in a line
cols() { printf '%s\n' "$1" | sed 's/\\|//g' | tr -cd '|' | wc -c | tr -d ' '; }
header="$(printf '%s\n' "$OUT" | grep '^| Title')"
pipe_row="$(printf '%s\n' "$OUT" | grep 'Parse a' | head -1)"
plain_row="$(printf '%s\n' "$OUT" | grep '^| Plain title ')"

echo "# pipe in a title"
case "$pipe_row" in *'Parse a\|b input'*) pass "pipe in a title is printed escaped as \\|" ;; *) fail "pipe in a title is printed escaped as \\|" "$pipe_row" ;; esac
check "pipe-title row has the same number of columns as the header" "$(cols "$pipe_row")" "$(cols "$header")"
dep_row_cols="$(cols "$plain_row")"
check "row that depends on a pipe-titled card keeps the header's column count" "$dep_row_cols" "$(cols "$header")"

echo "# title without a pipe"
check "a title without a pipe prints unchanged" "$plain_row" "| Plain title | acme/api | Parse a\\|b input | docs |"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
