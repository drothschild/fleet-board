#!/usr/bin/env bash
# Card 227: repo-local (fleet-board repo only) guidance and pre-CI check for the version bump.
set -u
unset CDPATH
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

# Acceptance 1: CLAUDE.md tells fleet agents to fetch origin/main, merge it, and bump both manifests.
sect=$(awk '/^## Fleet agents: version bump/{f=1;next} /^## /{f=0} f' "$ROOT/CLAUDE.md")
if [ -n "$sect" ] \
  && printf '%s' "$sect" | grep -q 'git fetch origin' \
  && printf '%s' "$sect" | grep -q 'origin/main' \
  && printf '%s' "$sect" | grep -qi 'merge' \
  && printf '%s' "$sect" | grep -q 'plugin.json' \
  && printf '%s' "$sect" | grep -q 'marketplace.json' \
  && printf '%s' "$sect" | grep -q 'plugins/'; then
  ok "CLAUDE.md guides fleet agents to fetch, merge origin/main and bump both manifests"
else
  bad "CLAUDE.md lacks a '## Fleet agents: version bump' section covering fetch, merge, both manifests, plugins/"
fi

# Acceptance 2: the check runs before CI through this repo's configured commands.
if grep -Eq '^[[:space:]]*lint:.*test-version-bumped\.sh' "$ROOT/.fleet-board.yml"; then
  ok ".fleet-board.yml commands.lint runs test-version-bumped.sh"
else
  bad ".fleet-board.yml commands.lint does not run test-version-bumped.sh"
fi

# Acceptance 3: the shipped plugin is untouched by this card.
# It holds on card 227's own branch only: other branches, such as a card that edits an agent,
# legitimately change shipped files. GITHUB_HEAD_REF names the branch in pull-request CI.
branch=${GITHUB_HEAD_REF:-$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)}
# A stale local origin/main ref makes the diff include other PRs' changes, so refresh it first
# (best effort: offline runs keep the existing ref).
case "$branch" in fleet/227-*) git -C "$ROOT" fetch -q origin main >/dev/null 2>&1 || true ;; esac
case "$branch" in
  fleet/227-*) ;;
  *) branch="" ;;
esac
if [ -z "$branch" ]; then
  ok "shipped-dir check skipped: not card 227's branch"
elif git -C "$ROOT" rev-parse -q --verify origin/main >/dev/null; then
  n=$(git -C "$ROOT" diff --name-only origin/main...HEAD -- plugins/fleet-board/agents plugins/fleet-board/skills plugins/fleet-board/scripts | wc -l | tr -d ' ')
  if [ "$n" = 0 ]; then ok "no change under agents, skills, scripts"; else bad "$n shipped files changed"; fi
else
  bad "origin/main is not available, so the shipped-directory check cannot run"
fi

# Acceptance 4: the check can fail. Fixture repo: branch without a bump is flagged.
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
if bash "$R/plugins/fleet-board/tests/test-version-bumped.sh" >"$T/out" 2>&1; then
  bad "unbumped card branch was not flagged"
else
  grep -q 'not ok - plugin.json was not bumped from 1.2.3' "$T/out" && ok "unbumped card branch is flagged" || bad "flag output missing"
fi
sed -i.bak 's/1\.2\.3/1.2.4/' "$R/plugins/fleet-board/.claude-plugin/plugin.json" "$R/.claude-plugin/marketplace.json"
rm -f "$R"/plugins/fleet-board/.claude-plugin/*.bak "$R"/.claude-plugin/*.bak
g add -A; g commit -qm bump
if bash "$R/plugins/fleet-board/tests/test-version-bumped.sh" >"$T/out2" 2>&1; then ok "bumped card branch passes"; else bad "bumped branch rejected: $(cat "$T/out2")"; fi
exit $fail
