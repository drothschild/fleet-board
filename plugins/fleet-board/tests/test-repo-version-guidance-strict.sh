#!/usr/bin/env bash
# Card 227 (review round 1), updated by card 368: stricter checks that kill surviving mutations of the guidance test.
set -u
unset CDPATH
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

# Acceptance 1: the guidance says agents no longer bump and a person outside the fleet bumps by hand.
sect=$(awk '/^## Fleet agents: version bump/{f=1;next} /^## /{f=0} f' "$ROOT/CLAUDE.md")
flat=$(printf '%s' "$sect" | tr '\n' ' ')
if printf '%s' "$flat" | grep -Eq 'no longer bump' && printf '%s' "$flat" | grep -Eq 'by hand'; then
  ok "CLAUDE.md says agents no longer bump and outside merges bump by hand"
else
  bad "CLAUDE.md lacks 'no longer bump' and 'by hand'"
fi

# Acceptance 2: the configured lint command, run for real, passes a branch leaving manifests alone and flags a one-manifest bump.
lint=$(sed -n 's/^[[:space:]]*lint:[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$ROOT/.fleet-board.example.yml" | head -1)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
R="$T/repo"
mkdir -p "$R/plugins/fleet-board/tests" "$R/plugins/fleet-board/.claude-plugin" "$R/.claude-plugin"
cp "$HERE/test-version-bumped.sh" "$R/plugins/fleet-board/tests/"
printf '{\n  "name": "fleet-board",\n  "version": "1.2.3"\n}\n' > "$R/plugins/fleet-board/.claude-plugin/plugin.json"
printf '{\n  "plugins": [\n    {\n      "source": "./plugins/fleet-board",\n      "version": "1.2.3"\n    }\n  ]\n}\n' > "$R/.claude-plugin/marketplace.json"
g() { git -C "$R" -c user.email=t@t -c user.name=t "$@"; }
g init -q -b main; g add -A; g commit -qm base
g update-ref refs/remotes/origin/main HEAD
g checkout -q -b card
echo x > "$R/plugins/fleet-board/change.txt"; g add -A; g commit -qm "change without bump"
if [ -z "$lint" ]; then
  bad "no commands.lint in .fleet-board.example.yml"
elif (cd "$R" && bash -c "$lint") >"$T/out" 2>&1; then
  ok "configured lint passes a branch leaving manifests alone"
else
  bad "configured lint rejected a branch leaving manifests alone"
fi
sed -i.bak 's/1\.2\.3/1.2.4/' "$R/plugins/fleet-board/.claude-plugin/plugin.json"
rm -f "$R"/plugins/fleet-board/.claude-plugin/*.bak
g add -A; g commit -qm "bump one"
if [ -n "$lint" ] && (cd "$R" && bash -c "$lint") >"$T/out2" 2>&1; then bad "configured lint passed a one-manifest bump"; else ok "configured lint flags a one-manifest bump"; fi
sed -i.bak 's/1\.2\.3/1.2.4/' "$R/plugins/fleet-board/.claude-plugin/plugin.json" "$R/.claude-plugin/marketplace.json"
rm -f "$R"/plugins/fleet-board/.claude-plugin/*.bak "$R"/.claude-plugin/*.bak
g add -A; g commit -qm bump
if [ -n "$lint" ] && (cd "$R" && bash -c "$lint") >"$T/out3" 2>&1; then ok "configured lint passes a bumped branch"; else bad "configured lint rejected a bumped branch"; fi
exit $fail
