#!/usr/bin/env bash
# behavioral-blast-radius.sh - paid behavioural check of agents/blast-radius-reviewer.md (not run in CI).
#
# (No --bare: on this Claude Code version --bare does not load plugin agents; the fresh empty
# CLAUDE_CONFIG_DIR is what keeps user plugins out.)
# Builds a fixture repo whose PR renames a function (compute_total -> calculate_total in lib.sh) while a
# file outside the diff (report.sh) still calls the old name, then runs the agent in a headless
# `claude -p --agent fleet-board:blast-radius-reviewer` session with a fresh empty CLAUDE_CONFIG_DIR
# (no user plugins, hooks, settings or user CLAUDE.md). The session's system/init event must show no plugin
# but fleet-board (and builtins). The posted report must be accepted by
# parse-report.sh --role stage-reviewer, must carry a finding that names report.sh, and the review
# worktree must stay clean. The board is a stub: board-comment.sh copies the posted report into the run
# directory, so nothing touches a real board or GitHub.
#
# Spends real tokens (one sonnet session). Refuses to run unless FLEET_BOARD_BEHAVIORAL=1.
#
# Environment:
#   FLEET_BOARD_BEHAVIORAL=1   required
#   FLEET_BOARD_CLAUDE         claude binary (default: claude)
#   BL_MAX_TURNS               --max-turns (default 40)
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
 behavioral-blast-radius.sh SPENDS REAL TOKENS: one headless
 model session (blast-radius reviewer, renamed-function fixture).
 Set FLEET_BOARD_BEHAVIORAL=1 to confirm you mean it.
================================================================
BANNER
if [ "${FLEET_BOARD_BEHAVIORAL:-}" != "1" ]; then
  echo "behavioral-blast-radius: refusing to run: FLEET_BOARD_BEHAVIORAL=1 is not set" >&2
  exit 2
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$HERE/.." && pwd)"
CLAUDE="${FLEET_BOARD_CLAUDE:-claude}"
RUN="$(mktemp -d "${TMPDIR:-/tmp}/fb-blast-behavioral.XXXXXX")"
printf 'evidence: %s\n' "$RUN"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

# Scripts directory the agent is handed: the real parse-report.sh, a board-comment.sh that records the post.
SCRIPTS="$RUN/scripts"
mkdir -p "$SCRIPTS"
cp "$PLUGIN_DIR/scripts/parse-report.sh" "$SCRIPTS/parse-report.sh"
cat > "$SCRIPTS/board-comment.sh" <<'STUB'
#!/usr/bin/env bash
# usage: board-comment.sh <card> <file>; records the post for the test
cp "$2" "$FB_BLAST_OUT/posted-$1.md"
echo "posted to card $1"
STUB
chmod +x "$SCRIPTS/board-comment.sh"
mkdir -p "$RUN/out"

# Fixture: main holds lib.sh, a caller in the diff-to-be (app.sh) and a caller outside it (report.sh);
# the PR branch renames the function in lib.sh and app.sh only.
REPO="$RUN/repo"
mkdir -p "$REPO"
(
  cd "$REPO" && git init -q -b main && git config user.name Fixture && git config user.email fixture@example.com
  printf '#!/usr/bin/env bash\ncompute_total() { echo $(( $1 + $2 )); }\n' > lib.sh
  printf '#!/usr/bin/env bash\n. "$(dirname "$0")/lib.sh"\ncompute_total 1 2\n' > app.sh
  printf '#!/usr/bin/env bash\n# nightly totals\n. "$(dirname "$0")/lib.sh"\ncompute_total 40 2\n' > report.sh
  git add . && git commit -qm "fixture: base"
  git checkout -q -b pr-branch
  sed -i.bak 's/compute_total/calculate_total/g' lib.sh app.sh && rm -f lib.sh.bak app.sh.bak
  git commit -qam "rename compute_total to calculate_total"
  git diff main..pr-branch > "$RUN/pr.diff"
) || { echo "behavioral-blast-radius: cannot build the fixture" >&2; exit 1; }

cat > "$RUN/prompt.txt" <<PROMPT
Review the pull request below for the blast_radius stage.

Card number: 99
Card body: Rename compute_total to calculate_total.
Acceptance items: ["lib.sh defines calculate_total"]
PR number: 5
PR diff: the file $RUN/pr.diff
Latest implementor report: Renamed the function in lib.sh and app.sh. Status done.
Review worktree: $REPO
Config JSON: {"commands":{},"test_paths":[]}
Stage name: blast_radius
Stage brief: Find what outside the diff the change affects.
Round: 1
Scripts directory: $SCRIPTS
PROMPT

SETTINGS="${FB_ISOLATE_SETTINGS:-$HOME/.config/fleet-board/bare-settings.json}"
CFG="$RUN/claude-config"
mkdir -p "$CFG"
argv=("$CLAUDE" -p "$(cat "$RUN/prompt.txt")" --agent fleet-board:blast-radius-reviewer --plugin-dir "$PLUGIN_DIR")
[ ! -r "$SETTINGS" ] || argv+=(--settings "$SETTINGS")
[ -z "${BL_MODEL:-}" ] || argv+=(--model "$BL_MODEL")
argv+=(--permission-mode auto --output-format stream-json --verbose --max-turns "${BL_MAX_TURNS:-40}")
(cd "$REPO" && CLAUDE_CONFIG_DIR="$CFG" FB_BLAST_OUT="$RUN/out" "${argv[@]}" \
  < /dev/null > "$RUN/stream.jsonl" 2> "$RUN/stderr")
printf 'run: exit %s\n' "$?"

if jq -se 'any(.[]; .type == "system" and .subtype == "init"
             and any(.plugins[]?; .name == "fleet-board")
             and all(.plugins[]?; .name == "fleet-board" or .path == "builtin"))' "$RUN/stream.jsonl" > /dev/null 2>&1; then
  pass "system/init shows no user plugin (fleet-board only)"
else
  fail "system/init shows no user plugin" "see the init event in $RUN/stream.jsonl"
fi

F="$RUN/out/posted-99.md"
if [ ! -f "$F" ]; then
  fail "a report was posted" "no $F (see $RUN/stream.jsonl)"
else
  pass "a report was posted"
  if bash "$PLUGIN_DIR/scripts/parse-report.sh" --role stage-reviewer "$F" > "$RUN/parsed.json" 2> "$RUN/parse.err"; then
    pass "parse-report.sh --role stage-reviewer accepts it"
  else
    fail "parse-report.sh --role stage-reviewer accepts it" "$(cat "$RUN/parse.err")"
  fi
  if sed -n '/^## Findings/,/^## For the card/p' "$F" | grep -E '^- \[(Critical|Important|Minor)\]' | grep -q 'report\.sh'; then
    pass "a finding names the caller outside the diff (report.sh)"
  else
    fail "a finding names the caller outside the diff (report.sh)" "no such finding in $F"
  fi
fi
if [ -z "$(git -C "$REPO" status --porcelain)" ]; then pass "the review worktree is clean"; else fail "the review worktree is clean" "$(git -C "$REPO" status --porcelain | tr '\n' ' ')"; fi

echo "-----------------------------------"
printf 'passed: %d   failed: %d   evidence: %s\n' "$PASS" "$FAIL" "$RUN"
[ "$FAIL" -eq 0 ] || exit 1
