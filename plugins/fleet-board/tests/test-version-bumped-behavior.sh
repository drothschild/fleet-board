#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)" || exit 1
trap 'rm -rf "$tmp"' EXIT
cd "$tmp" || exit 1
git init -q
git symbolic-ref HEAD refs/heads/main
git config user.name Test
git config user.email test@example.invalid
mkdir -p plugins/fleet-board/tests plugins/fleet-board/.claude-plugin .claude-plugin
cp "$here/test-version-bumped.sh" plugins/fleet-board/tests/
printf '{"name":"fleet-board","version":"0.16.0"}\n' > plugins/fleet-board/.claude-plugin/plugin.json
printf '{"plugins":[{"source":"./plugins/fleet-board","version":"0.16.0"}]}\n' > .claude-plugin/marketplace.json
# Match the production manifest formatting used by the test.
printf '{\n  "version": "0.16.0"\n}\n' > plugins/fleet-board/.claude-plugin/plugin.json
printf '{\n  "plugins": [{\n    "source": "./plugins/fleet-board",\n    "version": "0.16.0"\n  }]\n}\n' > .claude-plugin/marketplace.json
git add . && git commit -qm initial
sed 's/0.16.0/0.16.1/' plugins/fleet-board/.claude-plugin/plugin.json > "$tmp/p" && cp "$tmp/p" plugins/fleet-board/.claude-plugin/plugin.json
sed 's/0.16.0/0.16.1/' .claude-plugin/marketplace.json > "$tmp/m" && cp "$tmp/m" .claude-plugin/marketplace.json
git add . && git commit -qm main-bump
git update-ref refs/remotes/origin/main HEAD
git checkout -qb feature
git commit --allow-empty -qm feature-without-bump
if bash plugins/fleet-board/tests/test-version-bumped.sh > "$tmp/output" 2>&1; then
  echo 'not ok - unbumped feature branch was accepted'; exit 1
fi
echo 'ok - unbumped feature branch rejected'
sed 's/0.16.1/0.16.2/' plugins/fleet-board/.claude-plugin/plugin.json > "$tmp/p" && cp "$tmp/p" plugins/fleet-board/.claude-plugin/plugin.json
git add . && git commit -qm plugin-bump
sed 's/0.16.1/0.16.2/' .claude-plugin/marketplace.json > "$tmp/m" && cp "$tmp/m" .claude-plugin/marketplace.json
git add . && git commit -qm marketplace-bump
if ! bash plugins/fleet-board/tests/test-version-bumped.sh > "$tmp/output" 2>&1; then
  echo 'not ok - split version bump was rejected'; cat "$tmp/output"; exit 1
fi
echo 'ok - split version bump accepted'
