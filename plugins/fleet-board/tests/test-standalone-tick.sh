#!/usr/bin/env bash
# Targeted standalone CLI cases. Run one named case at a time.
set -uo pipefail
unset CDPATH
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
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
printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\nhuman_qa_paths: ["src/components/**"]\n' > "$TMP/repo/.fleet-board.yml"
git -C "$TMP/repo" add .fleet-board.yml
git -C "$TMP/repo" commit -q -m initial
ln -s "$TEST_DIR/fake-gh.sh" "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" FAKE_GH_DIR="$TMP/gh" FAKE_GH_ROUTES="$ROOT/plugins/fleet-board/fixtures/gh/tick/ready-start/routes"
cd "$TMP/repo"
bash "$ROOT/plugins/fleet-board/scripts/tick-plan.sh" > "$TMP/expected" || exit 1
if ! bash "$ROOT/bin/fleet-board" tick --plan-only > "$TMP/actual"; then
  echo 'FAIL: standalone plan-only should succeed' >&2; exit 1
fi
if ! cmp -s "$TMP/expected" "$TMP/actual"; then
  echo 'FAIL: standalone plan differs from planner' >&2; exit 1
fi
cat > "$TMP/unknown-plan" <<'PLAN'
#!/usr/bin/env bash
printf '%s\n' '{"dispatchable":true,"warnings":[],"cards":[{"number":12,"action":"surprise"}]}'
PLAN
chmod +x "$TMP/unknown-plan"
if FLEET_BOARD_TICK_PLAN="$TMP/unknown-plan" bash "$ROOT/bin/fleet-board" tick --plan-only > "$TMP/unknown-out" 2> "$TMP/unknown-err"; then
  echo 'FAIL: unknown action accepted' >&2; exit 1
fi
if [ -s "$TMP/unknown-out" ]; then echo 'FAIL: invalid plan emitted' >&2; exit 1; fi
for call in "$FAKE_GH_DIR"/argv/*; do
  [ -f "$call" ] || continue
  if grep -Eq '^(create|edit|comment|close|merge)$' "$call"; then
    echo 'FAIL: board or GitHub write during plan-only' >&2; exit 1
  fi
done
echo 'PASS: plan-only'
