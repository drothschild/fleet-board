#!/usr/bin/env bash
# Card 368: with supervisor.version_bump: merge, a feature branch leaves both manifests alone.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)" || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

# setver <from> <to> <plugin|market|both>
setver() {
  if [ "$3" != market ]; then sed "s/$1/$2/" plugins/fleet-board/.claude-plugin/plugin.json > "$tmp/x" && cp "$tmp/x" plugins/fleet-board/.claude-plugin/plugin.json; fi
  if [ "$3" != plugin ]; then sed "s/$1/$2/" .claude-plugin/marketplace.json > "$tmp/x" && cp "$tmp/x" .claude-plugin/marketplace.json; fi
}
# mkrepo <dir>: main at 0.16.1 (after a 0.16.0 initial commit), origin/main = main.
mkrepo() {
  local r="$1"
  mkdir -p "$r" && cd "$r" || exit 1
  git init -q
  git symbolic-ref HEAD refs/heads/main
  git config user.name Test
  git config user.email test@example.invalid
  mkdir -p plugins/fleet-board/tests plugins/fleet-board/.claude-plugin .claude-plugin
  cp "$here/test-version-bumped.sh" plugins/fleet-board/tests/
  printf '{\n  "version": "0.16.0"\n}\n' > plugins/fleet-board/.claude-plugin/plugin.json
  printf '{\n  "plugins": [{\n    "source": "./plugins/fleet-board",\n    "version": "0.16.0"\n  }]\n}\n' > .claude-plugin/marketplace.json
  git add . && git commit -qm initial
  setver 0.16.0 0.16.1 both
  git add . && git commit -qm main-bump
  git update-ref refs/remotes/origin/main HEAD
}
# expect <label> <pass|fail> <repo>
expect() {
  local out n
  out=$(cd "$3" && bash plugins/fleet-board/tests/test-version-bumped.sh 2>&1)
  n=$(printf '%s\n' "$out" | grep -c '^not ok')
  if [ "$2" = pass ]; then
    if [ "$n" = 0 ]; then ok "$1"; else bad "$1: $out"; fi
  else
    if [ "$n" -ge 1 ]; then ok "$1"; else bad "$1 (no not ok line): $out"; fi
  fi
}

mkrepo "$tmp/a"
git checkout -qb feature
echo x > plugins/fleet-board/change.txt; git add . && git commit -qm change
expect 'branch changing plugins/ and leaving both manifests untouched passes' pass "$tmp/a"

mkrepo "$tmp/b"
git checkout -qb feature
echo x > plugins/fleet-board/change.txt; setver 0.16.1 0.16.2 plugin; git add . && git commit -qm one
expect 'branch raising only plugin.json fails' fail "$tmp/b"

mkrepo "$tmp/c"
git checkout -qb feature
echo x > plugins/fleet-board/change.txt; setver 0.16.1 0.16.2 market; git add . && git commit -qm one
expect 'branch raising only marketplace.json fails' fail "$tmp/c"

mkrepo "$tmp/d"
git checkout -qb feature
echo x > plugins/fleet-board/change.txt; setver 0.16.1 0.16.0 both; git add . && git commit -qm lower
expect 'branch lowering both versions fails' fail "$tmp/d"

mkrepo "$tmp/e"
git checkout -qb feature
echo x > plugins/fleet-board/change.txt; setver 0.16.1 0.16.0 plugin; git add . && git commit -qm lower
expect 'branch lowering one version fails' fail "$tmp/e"

mkrepo "$tmp/f"
echo x > plugins/fleet-board/change.txt; git add . && git commit -qm change-no-raise
git update-ref refs/remotes/origin/main HEAD
expect 'main whose latest plugins/ change did not raise versions fails' fail "$tmp/f"

mkrepo "$tmp/g"
expect 'main whose latest plugins/ change raised both versions passes' pass "$tmp/g"

mkrepo "$tmp/h"
setver 0.16.1 0.16.2 plugin; git add . && git commit -qm plugin-only
git update-ref refs/remotes/origin/main HEAD
expect 'main whose manifests disagree fails' fail "$tmp/h"

mkrepo "$tmp/i"
git checkout -qb feature
git commit --allow-empty -qm feature-without-bump
sed 's/0.16.1/0.16.2/' plugins/fleet-board/.claude-plugin/plugin.json > "$tmp/p" && cp "$tmp/p" plugins/fleet-board/.claude-plugin/plugin.json
git add . && git commit -qm plugin-bump
sed 's/0.16.1/0.16.2/' .claude-plugin/marketplace.json > "$tmp/m" && cp "$tmp/m" .claude-plugin/marketplace.json
git add . && git commit -qm marketplace-bump
if ! bash plugins/fleet-board/tests/test-version-bumped.sh > "$tmp/output" 2>&1; then
  echo 'not ok - split version bump was rejected'; cat "$tmp/output"; fail=1
else
  echo 'ok - split version bump accepted'
fi
exit $fail
