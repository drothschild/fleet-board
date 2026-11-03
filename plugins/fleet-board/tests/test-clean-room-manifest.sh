#!/usr/bin/env bash
#
# Tests the hash-manifest check in test-clean-room.sh by running the guard
# against throwaway copies of the plugin and its specs directory.
# Usage: bash plugins/fleet-board/tests/test-clean-room-manifest.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$PLUGIN_DIR/../.." && pwd)"
SPECS_REL="docs/implementation-plans/2026-09-28-fleet-board/specs"
MANIFEST_NAME="clean-room-manifest.txt"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# fresh_copy NAME: mirror plugin and specs under $TMP/NAME; prints the root.
fresh_copy() {
  local root="$TMP/$1"
  mkdir -p "$root/plugins" "$root/$SPECS_REL"
  cp -R "$PLUGIN_DIR" "$root/plugins/fleet-board"
  cp -R "$REPO_DIR/$SPECS_REL/." "$root/$SPECS_REL/"
  printf '%s' "$root"
}

# run_guard ROOT: run the copied guard under macOS bash; sets OUT and RC.
run_guard() {
  OUT="$(/bin/bash "$1/plugins/fleet-board/tests/test-clean-room.sh" 2>&1)"
  RC=$?
}

echo "clean-room manifest check"

# 1. passes on an unmodified tree and reports the manifest check
R="$(fresh_copy ok)"
run_guard "$R"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qi 'manifest'; then
  pass "guard passes on the current tree and runs the manifest check"
else
  fail "guard passes on the current tree and runs the manifest check" "rc=$RC"
fi

# 2. one changed byte in an agent file fails
R="$(fresh_copy byte)"
printf 'x' >>"$R/plugins/fleet-board/agents/fixer.md"
run_guard "$R"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep 'FAIL' | grep -q 'agents/fixer.md'; then
  pass "guard fails when one byte of a clean-room agent file changes"
else
  fail "guard fails when one byte of a clean-room agent file changes" "rc=$RC"
fi
printf '%s\n' "$OUT" | grep -E 'FAIL|manifest|hash' | sed 's/^/       output: /'

# 3. a clean-room file missing from the manifest fails
R="$(fresh_copy missing)"
M="$R/$SPECS_REL/$MANIFEST_NAME"
if [ -f "$M" ]; then
  grep -v 'agents/reviewer.md' "$M" >"$M.new" && mv "$M.new" "$M"
fi
run_guard "$R"
if [ -f "$M" ] && [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep 'FAIL' | grep -q 'agents/reviewer.md'; then
  pass "guard fails when a clean-room file is missing from the manifest"
else
  fail "guard fails when a clean-room file is missing from the manifest" "rc=$RC manifest-exists=$([ -f "$M" ] && echo yes || echo no)"
fi

# 4. skips with a message when the specs directory is absent
R="$(fresh_copy nospecs)"
rm -rf "$R/$SPECS_REL"
run_guard "$R"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -i 'manifest' | grep -qi 'skip'; then
  pass "manifest check skips with a message when the specs directory is absent"
else
  fail "manifest check skips with a message when the specs directory is absent" "rc=$RC"
fi

# 5. specs/README.md tells the author to update the manifest
if grep -q "$MANIFEST_NAME" "$REPO_DIR/$SPECS_REL/README.md" \
   && grep -qi 'update the manifest' "$REPO_DIR/$SPECS_REL/README.md"; then
  pass "specs/README.md says to update the manifest when recording a revision"
else
  fail "specs/README.md says to update the manifest when recording a revision"
fi

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
