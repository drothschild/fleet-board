#!/usr/bin/env bash
#
# Plain-bash tests for review-drift.sh, on a real git repository. gh is a stub
# whose `api repos/<repo>/compare/<base>...<head>` answer is built from the local
# history, so only the drift rule itself is under test.
#
# Usage: bash plugins/fleet-board/tests/test-review-drift.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../scripts/review-drift.sh"
unset FLEET_BOARD_CONFIG FLEET_CFG FLEET_ROOT FLEET_REPO FLEET_SCRIPTS FLEET_BOARD_DOMAIN || true

PASS=0
FAIL=0
CLEANUP_DIRS=()
cleanup() { for d in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do rm -rf "$d" 2>/dev/null || true; done; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi; }

VF='supervisor:
  version_files: [".claude-plugin/marketplace.json", "plugins/*/.claude-plugin/plugin.json"]
'

# A gh stub: `gh api repos/<r>/compare/<a>...<b>` prints the compare JSON for the
# local history (commits reachable from b and not from a, oldest first).
make_gh() {
  BIN="$(mktemp -d)"; CLEANUP_DIRS+=("$BIN")
  cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = api ] || exit 1
spec="${2##*/compare/}"; a="${spec%%...*}"; b="${spec##*...}"
git rev-list --reverse --parents "$a..$b" | while read -r sha parents; do
  jq -cn --arg s "$sha" --arg p "$parents" --arg m "$(git log -1 --format=%B "$sha")" \
    '{sha: $s, parents: ($p | split(" ") | map(select(. != "") | {sha: .})), commit: {message: $m}}'
done | jq -s '{commits: .}'
EOF
  chmod +x "$BIN/gh"
}

# setup [yaml]: a repo on main with two manifests and a source file, and a
# feature branch "feat" with one reviewed commit (R). cwd is the repo.
setup() {
  REPO="$(mktemp -d)"; CLEANUP_DIRS+=("$REPO")
  git init -q -b main "$REPO"
  cd "$REPO" || exit 1
  git config user.email test@example.com; git config user.name Test
  printf 'board:\n  repo: acme/toy\n%s' "${1:-}" > .fleet-board.yml
  mkdir -p plugins/a/.claude-plugin .claude-plugin
  printf '{\n  "name": "a",\n  "description": "plugin a",\n  "version": "0.1.0"\n}\n' > plugins/a/.claude-plugin/plugin.json
  printf '{\n  "name": "mk",\n  "plugins": [\n    {\n      "name": "a",\n      "version": "0.1.0",\n      "source": "./plugins/a"\n    }\n  ]\n}\n' > .claude-plugin/marketplace.json
  printf '{\n  "name": "toy",\n  "version": "1.0.0"\n}\n' > package.json
  printf 'one\ntwo\nthree\n' > src.txt
  git add -A; git commit -q -m initial
  git checkout -q -b feat
  printf 'one\ntwo\nthree\nfour\n' > src.txt
  git commit -q -am "feature work"
  R="$(git rev-parse HEAD)"
}

# setv <file> <version>: sets every whole-line "version" value in the file
setv() { sed -i.bak -E 's/^([[:blank:]]*"version"[[:blank:]]*:[[:blank:]]*)"[^"]*"/\1"'"$2"'"/' "$1"; rm -f "$1.bak"; }
drift() { PATH="$BIN:$PATH" bash "$SCRIPT" "$R" "$(git rev-parse HEAD)" 2>/dev/null; }

make_gh

echo "== a commit that only raises version lines in version_files"
setup "$VF"
setv plugins/a/.claude-plugin/plugin.json 0.1.1; setv .claude-plugin/marketplace.json 0.1.1
git commit -q -am "Raise versions above origin/main"
assert_eq "version-only raise counts as reviewed" "$(drift)" reviewed

echo "== the same commit without supervisor.version_files"
setup ""
setv plugins/a/.claude-plugin/plugin.json 0.1.1; setv .claude-plugin/marketplace.json 0.1.1
git commit -q -am "Raise versions above origin/main"
assert_eq "no version_files: a raise is unreviewed" "$(drift)" unreviewed

echo "== a raise that also changes another line of the manifest"
setup "$VF"
setv plugins/a/.claude-plugin/plugin.json 0.1.1
sed -i.bak 's/plugin a/plugin A/' plugins/a/.claude-plugin/plugin.json; rm -f plugins/a/.claude-plugin/plugin.json.bak
git commit -q -am "Raise versions above origin/main"
assert_eq "raise plus a description change is unreviewed" "$(drift)" unreviewed

echo "== a raise that also touches a file outside version_files"
setup "$VF"
setv plugins/a/.claude-plugin/plugin.json 0.1.1
printf 'five\n' >> src.txt
git commit -q -am "Raise versions above origin/main"
assert_eq "raise plus a source change is unreviewed" "$(drift)" unreviewed

echo "== a version-only change to a file not in version_files"
setup "$VF"
setv package.json 1.0.1
git commit -q -am "Raise versions"
assert_eq "version change outside version_files is unreviewed" "$(drift)" unreviewed

echo "== a raise that drops the version line's trailing comma"
setup "$VF"
sed -i.bak -E 's/("version": )"0.1.0",/\1"0.1.1"/' .claude-plugin/marketplace.json; rm -f .claude-plugin/marketplace.json.bak
git commit -q -am "Raise versions above origin/main"
assert_eq "a raise that breaks the JSON is unreviewed" "$(drift)" unreviewed

echo "== a raise to a value that is not valid JSON text"
setup "$VF"
setv plugins/a/.claude-plugin/plugin.json '0.1.1\\q'
assert_eq "setup: the manifest no longer parses" "$(jq -e . plugins/a/.claude-plugin/plugin.json >/dev/null 2>&1; echo $?)" 5
git commit -q -am "Raise versions above origin/main"
assert_eq "a version value with a bad escape is unreviewed" "$(drift)" unreviewed

echo "== a raise that adds a version line"
setup "$VF"
awk '{print} /"name": "a",/ && !d {print "  \"version\": \"9.9.9\","; d=1}' plugins/a/.claude-plugin/plugin.json > p.tmp && mv p.tmp plugins/a/.claude-plugin/plugin.json
git commit -q -am "Raise versions above origin/main"
assert_eq "an added version line is unreviewed" "$(drift)" unreviewed

echo "== a clean merge of main, then a raise (the supervisor's update)"
setup "$VF"
git checkout -q main
printf 'zero\n' > other.txt; setv plugins/a/.claude-plugin/plugin.json 0.2.0; setv .claude-plugin/marketplace.json 0.2.0
git add -A; git commit -q -m "main moves"
git checkout -q feat
git merge -q --no-edit -m "Merge branch 'main' into feat" main
setv plugins/a/.claude-plugin/plugin.json 0.2.1; setv .claude-plugin/marketplace.json 0.2.1
git commit -q -am "Raise versions above origin/main"
assert_eq "clean merge plus raise counts as reviewed" "$(drift)" reviewed

echo "== a merge of main whose only conflicts are version lines"
setup "$VF"
setv plugins/a/.claude-plugin/plugin.json 0.1.1; setv .claude-plugin/marketplace.json 0.1.1
git commit -q -am "bump"
R="$(git rev-parse HEAD)"
git checkout -q main
printf 'zero\n' > other.txt; setv plugins/a/.claude-plugin/plugin.json 0.2.0; setv .claude-plugin/marketplace.json 0.2.0
git add -A; git commit -q -m "main moves"
git checkout -q feat
git merge -q --no-edit main >/dev/null 2>&1
assert_eq "setup: the merge conflicts in both manifests" "$(git diff --name-only --diff-filter=U | sort | tr '\n' ' ')" ".claude-plugin/marketplace.json plugins/a/.claude-plugin/plugin.json "
git checkout -q --theirs -- plugins/a/.claude-plugin/plugin.json .claude-plugin/marketplace.json
setv plugins/a/.claude-plugin/plugin.json 0.2.1; setv .claude-plugin/marketplace.json 0.2.1
git add -A; git commit -q -m "Merge branch 'main' into feat: resolve version-only conflicts"
assert_eq "version-only conflict resolution counts as reviewed" "$(drift)" reviewed

echo "== a version-only conflict resolution that also changes another manifest line"
setup "$VF"
setv plugins/a/.claude-plugin/plugin.json 0.1.1
git commit -q -am "bump"
R="$(git rev-parse HEAD)"
git checkout -q main
setv plugins/a/.claude-plugin/plugin.json 0.2.0
git commit -q -am "main moves"
git checkout -q feat
git merge -q --no-edit main >/dev/null 2>&1
git checkout -q --theirs -- plugins/a/.claude-plugin/plugin.json
setv plugins/a/.claude-plugin/plugin.json 0.2.1
sed -i.bak 's/plugin a/plugin A/' plugins/a/.claude-plugin/plugin.json; rm -f plugins/a/.claude-plugin/plugin.json.bak
git add -A; git commit -q -m "Merge branch 'main' into feat"
assert_eq "resolution with an extra manifest change is unreviewed" "$(drift)" unreviewed

echo "== a merge of main that resolved a conflict in a source file"
setup "$VF"
git checkout -q main
printf 'one\ntwo\nthree\nMAIN\n' > src.txt
git commit -q -am "main moves"
git checkout -q feat
git merge -q --no-edit main >/dev/null 2>&1
printf 'one\ntwo\nthree\nfour\nMAIN\n' > src.txt
git add -A; git commit -q -m "Merge branch 'main' into feat"
assert_eq "a source conflict resolution is still unreviewed" "$(drift)" unreviewed

echo "== a merge of main that left a version conflict unresolved"
setup "$VF"
setv plugins/a/.claude-plugin/plugin.json 0.1.1
git commit -q -am "bump"
R="$(git rev-parse HEAD)"
git checkout -q main
setv plugins/a/.claude-plugin/plugin.json 0.2.0
git commit -q -am "main moves"
git checkout -q feat
git merge -q --no-edit main >/dev/null 2>&1
git add -A; git commit -q -m "Merge branch 'main' into feat"
assert_eq "conflict markers left in a manifest are unreviewed" "$(drift)" unreviewed

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
