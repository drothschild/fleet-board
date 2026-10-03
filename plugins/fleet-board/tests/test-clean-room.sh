#!/usr/bin/env bash
#
# Plain-bash clean-room guard for the fleet-board plugin.
# No framework, no dependencies beyond POSIX tools.
#
# Checks:
#   1. No file under the plugin contains the forbidden plugin name (any case),
#      binary files included (the same scope as a plain grep -ri), and no file
#      or directory name contains it. The name is built at run time so this
#      file never contains it. A grep error (exit 2, e.g. an unreadable file)
#      is a failure, never a pass.
#   2. No clean-room file cites an external source: no URL, no "adapted from",
#      "based on", "derived from", "inspired by" or "copied from" (any case),
#      no "CC BY".
#   3. Every clean-room file has a behavior spec: agents/<name>.md at
#      $SPECS_DIR/<name>.md, skills/<name>/SKILL.md at $SPECS_DIR/<name>.md.
#      SPECS_DIR defaults to the implementation-plan specs directory of a
#      source checkout; when it does not exist (an installed plugin), this
#      check is skipped and says so.
#
#   Clean-room files are every agents/*.md, plus skills/<name>/SKILL.md for
#   each <name> in CLEAN_ROOM_SKILLS. The set lists the skills authored from a
#   spec by an isolated author process: reporting (Phase 5); Phase 6 adds tick,
#   run and status. skills/init is not in it: it was written directly in
#   Phase 3, has no behavior spec, and is covered by checks 1 and 4 only. A
#   listed skill that does not exist yet is reported as info, not a failure.
#   4. Every SKILL.md and agent file opens with frontmatter that has a
#      non-empty name: and description:.
#   5. Every *.sh under scripts/ and hooks/ is executable in git's index
#      (mode 100755 in git ls-files -s), so a fresh clone and an installed
#      copy get the same bits. Skipped, and says so, outside a git checkout.
#
# Usage: bash plugins/fleet-board/tests/test-clean-room.sh
#        SPECS_DIR=<dir> bash plugins/fleet-board/tests/test-clean-room.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SPECS_DIR="${SPECS_DIR:-$PLUGIN_DIR/../../docs/implementation-plans/2026-09-28-fleet-board/specs}"

# The forbidden plugin name, assembled so it never appears literally here.
W="$(printf 'ed%s' 3d)"

# Skills authored clean-room from a spec (see the header).
CLEAN_ROOM_SKILLS="reporting tick run status"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

# grep_absent NAME GREP_ARGS...: passes only when grep exits 1 (no match).
# A match (exit 0) fails with the matches; a grep error (exit >= 2) fails too.
grep_absent() {
  local name="$1" out rc
  shift
  out="$(grep "$@" 2>&1)"
  rc=$?
  case "$rc" in
    1) pass "$name" ;;
    0) fail "$name" "$(printf '%s' "$out" | tr '\n' ' ')" ;;
    *) fail "$name" "grep error (exit $rc): $(printf '%s' "$out" | tr '\n' ' ')" ;;
  esac
}

# has_frontmatter_keys <file>: the file opens with a --- block holding a
# non-empty name: and description:.
has_frontmatter_keys() {
  awk '
    NR == 1 { if ($0 != "---") exit 1; infm = 1; next }
    infm && $0 == "---" { closed = 1; exit }
    infm && /^name:[ \t]*[^ \t]/ { name = 1 }
    infm && /^description:[ \t]*[^ \t]/ { desc = 1 }
    END { exit !(closed && name && desc) }
  ' "$1"
}

echo "clean-room guard"

# --- 1. forbidden plugin name ---------------------------------------------
echo "forbidden plugin name"
grep_absent "no file content contains the forbidden plugin name" -ril -- "$W" "$PLUGIN_DIR"

name_hits="$(find "$PLUGIN_DIR" -iname "*$W*")"
if [ -z "$name_hits" ]; then
  pass "no file or directory name contains the forbidden plugin name"
else
  fail "no file or directory name contains the forbidden plugin name" "found: $(printf '%s' "$name_hits" | tr '\n' ' ')"
fi

# --- collect agent and skill files ----------------------------------------
AGENTS=()
for f in "$PLUGIN_DIR"/agents/*.md; do
  [ -f "$f" ] && AGENTS+=("$f")
done
SKILLS=()
for f in "$PLUGIN_DIR"/skills/*/SKILL.md; do
  [ -f "$f" ] && SKILLS+=("$f")
done
printf '  info %d agent file(s), %d skill file(s)\n' "${#AGENTS[@]}" "${#SKILLS[@]}"

# Clean-room files: every agent, plus the SKILL.md of each CLEAN_ROOM_SKILLS
# entry that exists. CR_SPECS holds the spec name for each, in the same order.
CR_FILES=()
CR_SPECS=()
for f in ${AGENTS[@]+"${AGENTS[@]}"}; do
  CR_FILES+=("$f")
  CR_SPECS+=("$(basename "$f")")
done
for n in $CLEAN_ROOM_SKILLS; do
  if [ -f "$PLUGIN_DIR/skills/$n/SKILL.md" ]; then
    CR_FILES+=("$PLUGIN_DIR/skills/$n/SKILL.md")
    CR_SPECS+=("$n.md")
  else
    printf '  info clean-room skill %s not present yet\n' "$n"
  fi
done

# --- 2. no cited sources in clean-room files ------------------------------
echo "clean-room files cite no source"
for f in ${CR_FILES[@]+"${CR_FILES[@]}"}; do
  rel="${f#"$PLUGIN_DIR"/}"
  grep_absent "$rel: no URL" -Ein 'https?://' "$f"
  grep_absent "$rel: no attribution phrase" -Ein 'adapted from|based on|derived from|inspired by|copied from' "$f"
  grep_absent "$rel: no CC BY" -Fn 'CC BY' "$f"
done

# --- 3. every clean-room file has a behavior spec -------------------------
echo "clean-room specs"
if [ ! -d "$SPECS_DIR" ]; then
  echo "  skip: specs dir not found (not a source checkout)"
else
  i=0
  for f in ${CR_FILES[@]+"${CR_FILES[@]}"}; do
    rel="${f#"$PLUGIN_DIR"/}"
    spec="${CR_SPECS[$i]}"
    i=$((i + 1))
    if [ -f "$SPECS_DIR/$spec" ]; then
      pass "$rel: spec exists ($spec)"
    else
      fail "$rel: spec exists" "no spec at $SPECS_DIR/$spec"
    fi
  done
fi

# --- 4. frontmatter -------------------------------------------------------
echo "frontmatter"
for f in ${SKILLS[@]+"${SKILLS[@]}"} ${AGENTS[@]+"${AGENTS[@]}"}; do
  rel="${f#"$PLUGIN_DIR"/}"
  if has_frontmatter_keys "$f"; then
    pass "$rel: frontmatter has name: and description:"
  else
    fail "$rel: frontmatter has name: and description:" "missing --- block, name: or description:"
  fi
done

# 5. shipped shell scripts are executable in git's index
if git -C "$PLUGIN_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  MODES="$(git -C "$PLUGIN_DIR" ls-files -s -- scripts hooks | awk '$4 ~ /\.sh$/ {print $1, $4}')"
  if [ -z "$MODES" ]; then
    fail "shipped *.sh are tracked" "git ls-files found no *.sh under scripts/ or hooks/"
  fi
  while read -r mode path; do
    [ -n "$path" ] || continue
    if [ "$mode" = 100755 ]; then
      pass "$path: mode 100755 in the index"
    else
      fail "$path: mode 100755 in the index" "mode is $mode; run git update-index --chmod=+x $path"
    fi
  done <<<"$MODES"
else
  printf '  info not a git checkout: executable-bit check skipped\n'
fi

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
