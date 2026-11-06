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
cat > "$TMP/unknown-plan" <<'PLAN'
#!/usr/bin/env bash
printf '%s\n' '{"dispatchable":true,"warnings":[],"cards":[{"number":12,"action":"surprise"}]}'
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
echo 'PASS: plan-only'
