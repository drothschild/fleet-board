#!/usr/bin/env bash
# behavioral-reviewer-open-cards.sh - paid behavioural check of agents/reviewer.md (not run in CI).
#
# Fixture: a PR adds a small, correct function with a passing test. Outside its diff the repository holds
# chained-merge-tests.sh, which fails; the config's lint command runs it, so the reviewer meets the failure
# and must report it as a bug outside the diff. The prompt's `## Open cards` section lists
# `#378 Chained merge tests fail on origin/main`. The posted report must be accepted by
# parse-report.sh --role reviewer, and its `Bugs found:` list must hold an entry whose title is exactly
# `Chained merge tests fail on origin/main` (the open card's title, word for word, without `#378`).
#
# The session runs headless with a fresh empty CLAUDE_CONFIG_DIR (no user plugins, hooks or settings) and
# the plugin loaded by --plugin-dir. The board is a stub: board-comment.sh copies the posted report into
# the run directory, so nothing touches a real board or GitHub.
#
# Spends real tokens (one opus session). Refuses to run unless FLEET_BOARD_BEHAVIORAL=1.
#
# Environment:
#   FLEET_BOARD_BEHAVIORAL=1   required
#   FLEET_BOARD_CLAUDE         claude binary (default: claude)
#   BL_MAX_TURNS               --max-turns (default 60)
#   BL_MODEL                   --model (default: the agent's own model)
#   FB_ISOLATE_SETTINGS        settings file holding the auth (an apiKeyHelper) for the session
#                              (default ~/.config/fleet-board/bare-settings.json; skipped when unreadable,
#                              then the session needs ANTHROPIC_API_KEY)
#
# Portable: bash 3.2, jq, git.
set -uo pipefail
unset CDPATH

cat >&2 <<'BANNER'
================================================================
 behavioral-reviewer-open-cards.sh SPENDS REAL TOKENS: one
 headless model session (reviewer, open-cards fixture).
 Set FLEET_BOARD_BEHAVIORAL=1 to confirm you mean it.
================================================================
BANNER
if [ "${FLEET_BOARD_BEHAVIORAL:-}" != "1" ]; then
  echo "behavioral-reviewer-open-cards: refusing to run: FLEET_BOARD_BEHAVIORAL=1 is not set" >&2
  exit 2
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$HERE/.." && pwd)"
CLAUDE="${FLEET_BOARD_CLAUDE:-claude}"
RUN="$(mktemp -d "${TMPDIR:-/tmp}/fb-reviewer-open-cards.XXXXXX")"
printf 'evidence: %s\n' "$RUN"
TITLE='Chained merge tests fail on origin/main'

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

SCRIPTS="$RUN/scripts"
mkdir -p "$SCRIPTS" "$RUN/out"
cp "$PLUGIN_DIR/scripts/parse-report.sh" "$SCRIPTS/parse-report.sh"
cat > "$SCRIPTS/board-comment.sh" <<'STUB'
#!/usr/bin/env bash
# usage: board-comment.sh <card> <file>; records the post for the test
cp "$2" "$FB_REVIEW_OUT/posted-$1.md"
echo "posted to card $1"
STUB
chmod +x "$SCRIPTS/board-comment.sh"

REPO="$RUN/repo"
mkdir -p "$REPO/test"
(
  cd "$REPO" && git init -q -b main && git config user.name Fixture && git config user.email fixture@example.com
  printf '#!/usr/bin/env bash\nsubtract() { echo $(( $1 - $2 )); }\n' > calc.sh
  printf '#!/usr/bin/env bash\necho "FAIL chained merge: expected 3 merges, got 2"\nexit 1\n' > chained-merge-tests.sh
  git add . && git commit -qm "fixture: base"
  BASE="$(git rev-parse HEAD)"
  git checkout -q -b pr-branch
  printf 'add() { echo $(( $1 + $2 )); }\n' >> calc.sh
  printf '#!/usr/bin/env bash\n. "$(dirname "$0")/../calc.sh"\n[ "$(add 2 3)" = 5 ] || { echo "FAIL add"; exit 1; }\necho "1 test passed"\n' > test/test-calc.sh
  git add . && git commit -qm "add: add()"
  git rev-parse HEAD > "$RUN/head.sha"
  echo "$BASE" > "$RUN/base.sha"
  git diff "$BASE"..HEAD > "$RUN/pr.diff"
) || { echo "behavioral-reviewer-open-cards: cannot build the fixture" >&2; exit 1; }

cat > "$RUN/prompt.txt" <<PROMPT
## Card number
99

## Card body
Add an add() function to calc.sh.

## Acceptance
- add(2, 3) returns 5

## Open cards
#378 $TITLE
#380 Unrelated docs typo in the README

## PR number
5

## PR diff
$(cat "$RUN/pr.diff")

## Latest implementor or fixer report
## Status
done

## Findings
- none

## For the card
Test is test/test-calc.sh. Test-first commit and implementation are one commit in this fixture.

## PR
Draft PR #5 on branch pr-branch.

VERIFIED: \`bash test/test-calc.sh\` -> 1 test passed

## Worktree
$REPO

## Config
{"commands":{"lint":"bash chained-merge-tests.sh","test_one":"bash {file}"},"test_paths":["test/test-*.sh"],"review":{"mutation":false,"verify_claim":false}}

## Round
1

## Previous review sha (prev_sha)
$(cat "$RUN/base.sha")

## Findings


## Scripts dir
$SCRIPTS
PROMPT

SETTINGS="${FB_ISOLATE_SETTINGS:-$HOME/.config/fleet-board/bare-settings.json}"
CFG="$RUN/claude-config"
mkdir -p "$CFG"
argv=("$CLAUDE" -p "$(cat "$RUN/prompt.txt")" --agent fleet-board:reviewer --plugin-dir "$PLUGIN_DIR")
[ ! -r "$SETTINGS" ] || argv+=(--settings "$SETTINGS")
[ -z "${BL_MODEL:-}" ] || argv+=(--model "$BL_MODEL")
argv+=(--permission-mode auto --output-format stream-json --verbose --max-turns "${BL_MAX_TURNS:-60}")
(cd "$REPO" && CLAUDE_CONFIG_DIR="$CFG" FB_REVIEW_OUT="$RUN/out" "${argv[@]}" \
  < /dev/null > "$RUN/stream.jsonl" 2> "$RUN/stderr")
printf 'run: exit %s\n' "$?"

if jq -se 'any(.[]; .type == "system" and .subtype == "init"
             and any(.plugins[]?; .name == "fleet-board")
             and all(.plugins[]?; .name == "fleet-board" or .path == "builtin"
                     or (.name | startswith("cc-plugin-"))))' "$RUN/stream.jsonl" > /dev/null 2>&1; then
  pass "system/init shows no user plugin (fleet-board only)"
else
  fail "system/init shows no user plugin" "see the init event in $RUN/stream.jsonl"
fi

F="$RUN/out/posted-99.md"
if [ ! -f "$F" ]; then
  fail "a report was posted" "no $F (see $RUN/stream.jsonl)"
else
  pass "a report was posted"
  if bash "$PLUGIN_DIR/scripts/parse-report.sh" --role reviewer "$F" > "$RUN/parsed.json" 2> "$RUN/parse.err"; then
    pass "parse-report.sh --role reviewer accepts it"
  else
    fail "parse-report.sh --role reviewer accepts it" "$(cat "$RUN/parse.err")"
  fi
  # the Bugs found entries: unindented `- ` lines right after the `Bugs found:` header
  BUGS="$(awk '/^Bugs found:/{on=1; next} on && /^- /{print; next} on{exit}' "$F")"
  if printf '%s\n' "$BUGS" | grep -qF -- "- $TITLE :: repro:"; then
    pass "a Bugs found entry uses the open card's title word for word"
  else
    fail "a Bugs found entry uses the open card's title word for word" "Bugs found was: ${BUGS:-<none>}"
  fi
fi
if [ -z "$(git -C "$REPO" status --porcelain)" ]; then pass "the review worktree is clean"; else fail "the review worktree is clean" "$(git -C "$REPO" status --porcelain | tr '\n' ' ')"; fi

echo "-----------------------------------"
printf 'passed: %d   failed: %d   evidence: %s\n' "$PASS" "$FAIL" "$RUN"
[ "$FAIL" -eq 0 ] || exit 1
