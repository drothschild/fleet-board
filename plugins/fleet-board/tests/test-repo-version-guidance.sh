#!/usr/bin/env bash
# Card 227, updated by card 368: repo-local (fleet-board repo only) guidance and pre-CI check for the
# version bump. The merge lane raises the version; branches leave both manifests alone.
set -u
unset CDPATH
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

# Acceptance 1: CLAUDE.md says the merge lane raises the version and how to ask for minor or major.
sect=$(awk '/^## Fleet agents: version bump/{f=1;next} /^## /{f=0} f' "$ROOT/CLAUDE.md")
if [ -n "$sect" ] \
  && printf '%s' "$sect" | grep -q 'merge lane' \
  && printf '%s' "$sect" | grep -q 'fleet:bump:minor' \
  && printf '%s' "$sect" | grep -q 'fleet:bump:major' \
  && printf '%s' "$sect" | grep -q 'plugin.json' \
  && printf '%s' "$sect" | grep -q 'marketplace.json' \
  && printf '%s' "$sect" | grep -q 'plugins/' \
  && ! printf '%s' "$sect" | grep -q 'Bump `plugins/fleet-board/.claude-plugin/plugin.json`'; then
  ok "CLAUDE.md says the merge lane bumps and names the minor/major labels"
else
  bad "CLAUDE.md '## Fleet agents: version bump' section lacks merge lane, bump labels, or still tells agents to bump"
fi

EXAMPLE="$ROOT/.fleet-board.example.yml"

# Card 494: the board's own .fleet-board.yml is local: untracked and ignored; the committed example stands in.
if [ -z "$(git -C "$ROOT" ls-files -- .fleet-board.yml)" ] && grep -qxF '.fleet-board.yml' "$ROOT/.gitignore"; then
  ok ".fleet-board.yml is untracked and listed in .gitignore"
else
  bad ".fleet-board.yml is still tracked or missing from .gitignore"
fi
if [ -f "$EXAMPLE" ]; then ok ".fleet-board.example.yml is committed"; else bad ".fleet-board.example.yml is missing"; fi
RD="$ROOT/plugins/fleet-board/README.md"
if grep -q '\.fleet-board\.example\.yml' "$RD" && grep -q 'skip-worktree' "$RD"; then
  ok "README says how to create the local file and keep a copy on pull"
else
  bad "README lacks .fleet-board.example.yml and skip-worktree guidance"
fi

# Acceptance 2: the repository turns the merge-lane mode on.
if [ "$(FLEET_BOARD_CONFIG="$EXAMPLE" bash "$ROOT/plugins/fleet-board/scripts/config.sh" supervisor.version_bump 2>/dev/null)" = merge ]; then
  ok "supervisor.version_bump is merge"
else
  bad "supervisor.version_bump is not merge"
fi
if grep -q 'version_bump_paths' "$EXAMPLE" && grep -q 'plugins/\*\*' "$EXAMPLE"; then
  ok ".fleet-board.example.yml sets version_bump_paths to plugins/**"
else
  bad ".fleet-board.example.yml lacks version_bump_paths plugins/**"
fi

# Acceptance 3: the check runs before CI through this repo's configured commands.
if grep -Eq '^[[:space:]]*lint:.*test-version-bumped\.sh' "$EXAMPLE"; then
  ok ".fleet-board.example.yml commands.lint runs test-version-bumped.sh"
else
  bad ".fleet-board.example.yml commands.lint does not run test-version-bumped.sh"
fi

# Acceptance 4: the check can fail. Fixture repo: a branch leaving both manifests alone passes;
# raising only one is flagged.
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
R="$T/repo"
mkdir -p "$R/plugins/fleet-board/tests" "$R/plugins/fleet-board/.claude-plugin" "$R/.claude-plugin"
cp "$HERE/test-version-bumped.sh" "$R/plugins/fleet-board/tests/"
printf '{\n  "name": "fleet-board",\n  "version": "1.2.3"\n}\n' > "$R/plugins/fleet-board/.claude-plugin/plugin.json"
printf '{\n  "plugins": [\n    {\n      "source": "./plugins/fleet-board",\n      "version": "1.2.3"\n    }\n  ]\n}\n' > "$R/.claude-plugin/marketplace.json"
g() { git -C "$R" -c user.email=t@t -c user.name=t "$@"; }
g init -q -b main
g add -A; g commit -qm base
g update-ref refs/remotes/origin/main HEAD
g checkout -q -b card
echo x > "$R/plugins/fleet-board/change.txt"; g add -A; g commit -qm "change without bump"
if bash "$R/plugins/fleet-board/tests/test-version-bumped.sh" >"$T/out" 2>&1; then ok "card branch leaving both manifests alone passes"; else bad "untouched manifests rejected: $(cat "$T/out")"; fi
sed -i.bak 's/1\.2\.3/1.2.4/' "$R/plugins/fleet-board/.claude-plugin/plugin.json"
rm -f "$R"/plugins/fleet-board/.claude-plugin/*.bak
g add -A; g commit -qm "bump one"
if bash "$R/plugins/fleet-board/tests/test-version-bumped.sh" >"$T/out2" 2>&1; then
  bad "branch raising only plugin.json was not flagged"
else
  grep -q '^not ok' "$T/out2" && ok "branch raising only one manifest is flagged" || bad "flag output missing"
fi
sed -i.bak 's/1\.2\.3/1.2.4/' "$R/plugins/fleet-board/.claude-plugin/plugin.json" "$R/.claude-plugin/marketplace.json"
rm -f "$R"/plugins/fleet-board/.claude-plugin/*.bak "$R"/.claude-plugin/*.bak
g add -A; g commit -qm bump
if bash "$R/plugins/fleet-board/tests/test-version-bumped.sh" >"$T/out3" 2>&1; then ok "bumped card branch passes"; else bad "bumped branch rejected: $(cat "$T/out3")"; fi
exit $fail
