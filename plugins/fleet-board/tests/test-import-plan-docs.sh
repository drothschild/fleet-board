#!/usr/bin/env bash
#
# Plain-bash tests for import-plan.sh handling of docs that are missing from the
# default branch. Offline: gh is a stub that logs its calls; git is a wrapper whose
# `cat-file -e <ref>:<path>` succeeds only for paths listed in $FAKE_EXISTING.
#
# Usage: bash plugins/fleet-board/tests/test-import-plan-docs.sh

set -uo pipefail
unset CDPATH || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../scripts/import-plan.sh"
REALGIT="$(command -v git)"

PASS=0
FAIL=0
CLEANUP_DIRS=()
cleanup() { for d in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do rm -rf "$d" 2>/dev/null || true; done; }
trap cleanup EXIT
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s: %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi; }

SB="$(mktemp -d)"; CLEANUP_DIRS+=("$SB")
ROOT="$SB/root"; STUBS="$SB/stubs"; D="$SB/gh"
mkdir -p "$ROOT/docs" "$STUBS" "$D/bodies"
"$REALGIT" -C "$ROOT" init -q
printf '%s\n' 'board:' '  repo: acme/api' 'worktrees:' '  dir: ".wt"' > "$ROOT/.fleet-board.yml"

# Local (unmerged) docs: present in the working tree, absent from the default branch.
printf '%s\n' '# Coach design' '' '## Overview' 'Intro text.' '' '## Scoring rules' \
  'The coach scores each set from 0 to 10.' 'Ties go to the earlier set.' '' '## Other' 'Unrelated text.' > "$ROOT/docs/x.md"
printf '# Whole\nWhole file text.\n' > "$ROOT/docs/y.md"

# gh stub: logs calls; issue create prints a URL with a global counter
printf '%s\n' '#!/usr/bin/env bash' 'D="${FAKE_D:?}"' 'echo "$*" >> "$D/calls.log"' \
  'case "$1 $2" in' \
  '  "issue create")' \
  '    n=$(( $(cat "$D/counter" 2>/dev/null || echo 100) + 1 )); echo "$n" > "$D/counter"' \
  '    repo=""; bf=""; prev=""' \
  '    for a in "$@"; do' \
  '      [ "$prev" = "--repo" ] && repo="$a"' \
  '      [ "$prev" = "--body-file" ] && bf="$a"' \
  '      prev="$a"' \
  '    done' \
  '    cp "$bf" "$D/bodies/$n.md"' \
  '    echo "https://github.com/$repo/issues/$n" ;;' \
  '  "project item-add") echo "{\"id\":\"ITEM_$(cat "$D/counter")\"}" ;;' \
  '  *) : ;;' \
  'esac' > "$STUBS/gh"
# git stub: cat-file succeeds only for paths listed in $FAKE_EXISTING; all else is real git
printf '%s\n' '#!/usr/bin/env bash' \
  'for a in "$@"; do' \
  '  if [ "$a" = "cat-file" ]; then' \
  '    last="${!#}"; p="${last#*:}"' \
  '    grep -qxF -- "$p" "${FAKE_EXISTING:-/dev/null}" 2>/dev/null' \
  '    exit $?' \
  '  fi' \
  'done' \
  "exec \"$REALGIT\" \"\$@\"" > "$STUBS/git"
chmod +x "$STUBS/gh" "$STUBS/git"

echo 'docs/present.md' > "$SB/existing"

cat > "$SB/cards.json" <<'EOF'
{"cards":[
 {"key":"M","title":"Mixed refs","repo":"acme/api","labels":[],
  "why":"Follow docs/x.md#scoring-rules and docs/present.md for context.",
  "scope":["src/a.js"],
  "acceptance":["Scores match docs/y.md","Layout matches docs/present.md"]},
 {"key":"P","title":"Present only","repo":"acme/api","labels":[],
  "why":"See docs/present.md.","scope":["src/b.js"],"acceptance":["Works per docs/present.md"]}
]}
EOF

# reset_gh: a fresh gh log and an empty local store
reset_gh() {
  rm -rf "$D"; mkdir -p "$D/bodies"
  rm -rf "$ROOT/.fleet-board"; mkdir -p "$ROOT/.fleet-board/cards"; echo 1 > "$ROOT/.fleet-board/next"
}
run_import() { # <stdin> args...
  local ans="$1"; shift
  OUT="$(cd "$ROOT" && printf '%b' "$ans" | FAKE_D="$D" FAKE_EXISTING="$SB/existing" PATH="$STUBS:$PATH" bash "$SCRIPT" "$@" 2>"$SB/err")"
  RC=$?
  # each local card's body as board-read.sh returns it, followed by its acceptance
  # items as "- " lines (the path checks cover the field too), at bodies/<100 + n>.md
  # (where the GitHub stub saved issue n's body)
  local f n
  for f in "$ROOT/.fleet-board/cards/"*.json; do
    [ -e "$f" ] || continue
    n="$(jq -r .number "$f")"
    (cd "$ROOT" && bash "$SCRIPT_DIR/../scripts/board-read.sh" "$n" 2>/dev/null) | jq -j '(.body // "") + ((.acceptance // []) | map("\n- " + .) | join(""))' > "$D/bodies/$((100 + n)).md"
  done
}
issues() { ls "$ROOT/.fleet-board/cards/" 2>/dev/null | grep -c '\.json$'; true; }

echo "# missing doc, user picks merge"
reset_gh
run_import "y\nm\n" "$SB/cards.json"
check "Given a card referencing docs/x.md missing on the default branch, the importer does not emit the card as it is" "$(issues)" "0"
case "$OUT" in *"commit and merge the docs first"*"embed the section"*) pass "the importer offers the two choices: commit and merge the docs first, and embed the section" ;; *) fail "the importer offers the two choices: commit and merge the docs first, and embed the section" "$OUT" ;; esac
case "$OUT$(cat "$SB/err")" in *docs/x.md*) pass "merge choice names the missing doc" ;; *) fail "merge choice names the missing doc" "$OUT" ;; esac
check "choosing merge exits 1 with nothing created" "$RC" "1"

echo "# missing doc, user picks embed"
reset_gh
run_import "y\ne\n" "$SB/cards.json"
check "choosing embed exits 0" "$RC" "0"
check "choosing embed creates both cards" "$(issues)" "2"
f="$D/bodies/101.md"
grep -q 'The coach scores each set from 0 to 10' "$f" && pass "with embed, the card body contains the referenced section text" || fail "with embed, the card body contains the referenced section text" "$(cat "$f")"
grep -q 'Unrelated text' "$f" && fail "embed only includes the referenced section" "other section leaked" || pass "embed only includes the referenced section"
grep -q 'Whole file text' "$f" && pass "a reference without an anchor embeds the whole file" || fail "a reference without an anchor embeds the whole file" "$(cat "$f")"
check "with embed, the card body has no remaining reference to the missing path" "$(grep -c 'docs/x.md\|docs/y.md' "$f")" "0"

echo "# existing doc untouched"
check "A reference to a file that exists on the default branch is left unchanged" "$(grep -c 'docs/present.md' "$f")" "2"
check "a card with only existing references is emitted unchanged" "$(grep -c 'Works per docs/present.md' "$D/bodies/102.md")" "1"

echo "# invariant over mixed run"
bad=0
for b in "$D"/bodies/*.md; do
  for p in docs/x.md docs/y.md; do grep -q "$p" "$b" && bad=$((bad + 1)); done
done
check "No emitted card body contains a path that is absent from the default branch" "$bad" "0"

echo "# dry run"
reset_gh
run_import "y\n" "$SB/cards.json" --dry-run
check "dry run is unaffected by missing docs" "$RC" "0"

echo "# embed failure on the last card creates nothing"
cat > "$SB/cards-badlast.json" <<'EOF'
{"cards":[
 {"key":"A","title":"First ok","repo":"acme/api","labels":[],
  "why":"See docs/y.md.","scope":["src/a.js"],"acceptance":["Works per docs/y.md"]},
 {"key":"B","title":"Last bad","repo":"acme/api","labels":[],"depends_on":["A"],
  "why":"See docs/x.md#no-such-section.","scope":["src/b.js"],"acceptance":["Works per docs/x.md#no-such-section"]}
]}
EOF
reset_gh
run_import "y\ne\n" "$SB/cards-badlast.json"
check "an embed failure on the last card exits 1" "$RC" "1"
check "an embed failure on the last card creates zero cards" "$(issues)" "0"
case "$(cat "$SB/err")" in *"cannot embed docs/x.md#no-such-section"*) pass "the embed failure names the reference" ;; *) fail "the embed failure names the reference" "$(cat "$SB/err")" ;; esac

echo "# a doc that exists nowhere is warned about, not fatal"
cat > "$SB/cards-ghost.json" <<'EOF'
{"cards":[
 {"key":"A","title":"First ok","repo":"acme/api","labels":[],
  "why":"See docs/y.md.","scope":["src/a.js"],"acceptance":["Works per docs/y.md"]},
 {"key":"B","title":"Ghost ref","repo":"acme/api","labels":[],"depends_on":["A"],
  "why":"Follow docs/ghost.md.","scope":["src/b.js"],"acceptance":["Matches docs/ghost.md"]}
]}
EOF
reset_gh
run_import "y\ne\n" "$SB/cards-ghost.json"
check "a reference to a file that exists nowhere does not fail the embed run" "$RC" "0"
check "a reference to a file that exists nowhere still creates every card" "$(issues)" "2"
case "$(cat "$SB/err")" in *docs/ghost.md*) pass "the nonexistent reference is named in a warning" ;; *) fail "the nonexistent reference is named in a warning" "$(cat "$SB/err")" ;; esac
case "$OUT" in *"docs/ghost.md"*"Choose:"*|*"  docs/ghost.md"*) fail "the nonexistent reference is not listed as missing on the default branch" "$OUT" ;; *) pass "the nonexistent reference is not listed as missing on the default branch" ;; esac

echo "# a doc the card itself creates is not flagged"
mkdir -p "$ROOT/plugins/fb/specs" "$ROOT/specs"
printf '# Merger spec\n' > "$ROOT/plugins/fb/specs/merger.md"
printf '# Root spec\n' > "$ROOT/specs/own.md"
cat > "$SB/cards-own.json" <<'EOF'
{"cards":[
 {"key":"S","title":"Creates its spec","repo":"acme/api","labels":[],
  "why":"Write the merger spec.","scope":["plugins/fb/specs/merger.md","specs/own.md"],
  "acceptance":["specs/merger.md defines the merger role","specs/own.md lists the inputs"]}
]}
EOF
reset_gh
run_import "y\n" "$SB/cards-own.json"
check "a card whose acceptance names a file in its own scope is created without a doc prompt" "$RC" "0"
check "the self-scoped card is created" "$(issues)" "1"
case "$OUT" in *"missing on the default branch"*) fail "a path in the card's own scope (exact or suffix) is not flagged as missing" "$OUT" ;; *) pass "a path in the card's own scope (exact or suffix) is not flagged as missing" ;; esac
check "the self-scoped acceptance is kept verbatim" "$(grep -c 'specs/merger.md defines the merger role' "$D/bodies/101.md" 2>/dev/null)" "1"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
